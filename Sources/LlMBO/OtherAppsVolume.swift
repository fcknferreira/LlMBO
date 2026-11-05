import CoreAudio
import Foundation

/// "Não mudar o volume de outros apps" (macOS 14.2+): enquanto o LlMBO sobe a saída para o som do aviso,
/// uma process tap do CoreAudio silencia o áudio dos outros apps e o toca de novo com o ganho que devolve o
/// volume de antes. Só existe enquanto o som toca; a tap e a saída agregada são privadas e somem com o processo.
/// Precisa da permissão "Gravação de áudio do sistema"; sem ela a tap só entregaria silêncio e os outros apps
/// ficariam mudos, então sem permissão não roda.
final class OtherAppsVolume {
    enum Permission { case allowed, denied, unknown }

    static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // MARK: Permissão (TCC, kTCCServiceAudioCapture)
    // Não há API pública para ler essa permissão; o TCC.framework a expõe por funções C (as mesmas que apps
    // de gravação usam). Se sumirem numa versão futura, a opção só fica sem efeito.

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    /// Resposta crua do TCCAccessPreflight (0 permitido, 1 negado, 2 não perguntado; -1 = função não encontrada).
    static func preflightRaw() -> Int {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let sym = dlsym(tcc, "TCCAccessPreflight") else { return -1 }
        return unsafeBitCast(sym, to: Preflight.self)(service, nil)
    }

    static func permission() -> Permission {
        switch preflightRaw() {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Mostra a pergunta do macOS (só da primeira vez; depois, só nos Ajustes do Sistema).
    static func request(_ done: @escaping (Bool) -> Void) {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let sym = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        unsafeBitCast(sym, to: Request.self)(service, nil) { ok in DispatchQueue.main.async { done(ok) } }
    }

    // MARK: Tap

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    /// Lido pela thread de áudio a cada bloco; escrita de Float32 alinhado é atômica no arm64 e no x86.
    private let gainPtr = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
    /// Diagnóstico para o sound.log: pico de entrada e de saída e o formato dos buffers, gravados pela thread de áudio.
    private let peaks = UnsafeMutablePointer<Float32>.allocate(capacity: 2)
    private let layout = UnsafeMutablePointer<UInt32>.allocate(capacity: 4)
    var diagnostics: String {
        String(format: "tap: entrada %ux%u ch, saída %ux%u ch, pico entrada %.3f saída %.3f ganho %.4f",
               layout[0], layout[1], layout[2], layout[3], peaks[0], peaks[1], gain)
    }

    /// Ganho aplicado ao áudio dos outros apps (1 = como estava antes de silenciar).
    var gain: Float32 {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(newValue, 0) }
    }

    /// Começa a silenciar e repassar os outros apps para a saída `device`; nil se não der (sem permissão,
    /// sem outros apps com áudio, macOS antigo, erro do CoreAudio) — aí o som segue o modo normal.
    static func start(device: AudioDeviceID) -> OtherAppsVolume? {
        guard #available(macOS 14.2, *), permission() == .allowed else { return nil }
        let v = OtherAppsVolume()
        v.gain = 1
        v.peaks.initialize(repeating: 0, count: 2)
        v.layout.initialize(repeating: 0, count: 4)
        guard v.begin(device: device) else { v.stop(); return nil }
        return v
    }

    @available(macOS 14.2, *)
    private func begin(device: AudioDeviceID) -> Bool {
        // Só os apps que já estão no CoreAudio: o afplay do aviso começa depois e fica de fora, e o próprio
        // LlMBO também (a saída agregada é dele; incluí-lo faria o áudio repassado voltar para a tap).
        let others = Self.processObjects().filter { Self.pid(of: $0) != getpid() }
        guard !others.isEmpty, let outputUID = Self.uid(of: device) else { return false }

        let desc = CATapDescription(stereoMixdownOfProcesses: others)
        desc.name = "LlMBO"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != kAudioObjectUnknown else { return false }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LlMBO",
            kAudioAggregateDeviceUIDKey: "com.llmbo.app.others." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate) == noErr,
              aggregate != kAudioObjectUnknown else { return false }

        let gainPtr = self.gainPtr, peaks = self.peaks, layout = self.layout
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            let i = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let o = UnsafeMutableAudioBufferListPointer(output)
            layout[0] = UInt32(i.count); layout[1] = i.first?.mNumberChannels ?? 0
            layout[2] = UInt32(o.count); layout[3] = o.first?.mNumberChannels ?? 0
            Self.copy(i, into: o, gain: gainPtr.pointee)
            peaks[0] = max(peaks[0], Self.peak(i)); peaks[1] = max(peaks[1], Self.peak(o))
        }
        guard status == noErr, let proc else { return false }
        return AudioDeviceStart(aggregate, proc) == noErr
    }

    /// Entrada da tap (estéreo, Float32 intercalado) → cada buffer de saída, canal a canal, com o ganho.
    private static func copy(_ input: UnsafeMutableAudioBufferListPointer, into output: UnsafeMutableAudioBufferListPointer,
                             gain: Float32) {
        guard let src = input.first, let inData = src.mData?.assumingMemoryBound(to: Float32.self),
              src.mNumberChannels > 0 else {
            for b in output { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let ci = Int(src.mNumberChannels)
        let inFrames = Int(src.mDataByteSize) / (4 * ci)
        for b in output {
            guard let d = b.mData?.assumingMemoryBound(to: Float32.self), b.mNumberChannels > 0 else { continue }
            let co = Int(b.mNumberChannels)
            let frames = Int(b.mDataByteSize) / (4 * co)
            for f in 0..<frames {
                for c in 0..<co {
                    d[f * co + c] = f < inFrames ? inData[f * ci + min(c, ci - 1)] * gain : 0
                }
            }
        }
    }

    private static func peak(_ list: UnsafeMutableAudioBufferListPointer) -> Float32 {
        var p: Float32 = 0
        for b in list {
            guard let d = b.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            for k in 0..<(Int(b.mDataByteSize) / 4) { p = max(p, abs(d[k])) }
        }
        return p
    }

    /// Para de repassar: os outros apps voltam a tocar direto na saída.
    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        stop()
        gainPtr.deallocate()
        peaks.deallocate()
        layout.deallocate()
    }

    // MARK: CoreAudio

    private static func processObjects() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var p = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &a, 0, nil, &size, &p)
        return p
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
