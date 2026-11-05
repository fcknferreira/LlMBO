import CoreAudio
import Foundation

/// Volume e mudo da saída de áudio padrão do Mac (CoreAudio, sem senha). Usado para o som da tampa fechada
/// sair no volume escolhido, independente do volume geral: guarda o estado, ajusta, toca e devolve.
/// Saída sem controle de volume (alguns monitores HDMI) devolve nil e o som segue relativo ao sistema.
enum SystemVolume {
    struct State: Equatable {
        let device: AudioDeviceID
        /// Volume por canal (0 = principal); nem toda saída tem o principal.
        let volumes: [UInt32: Float32]
        let muted: Bool?
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ element: UInt32 = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    static var defaultOutput: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func settable(_ device: AudioDeviceID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &ok) == noErr && ok.boolValue
    }

    /// Canais com volume ajustável: o principal, ou o esquerdo e o direito.
    private static func channels(_ device: AudioDeviceID) -> [UInt32] {
        if settable(device, address(kAudioDevicePropertyVolumeScalar)) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { settable(device, address(kAudioDevicePropertyVolumeScalar, $0)) }
    }

    /// Estado atual da saída padrão; nil se ela não tem volume ajustável.
    static func current() -> State? {
        guard let device = defaultOutput else { return nil }
        var volumes: [UInt32: Float32] = [:]
        for ch in channels(device) {
            var a = address(kAudioDevicePropertyVolumeScalar, ch)
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr { volumes[ch] = v }
        }
        guard !volumes.isEmpty else { return nil }
        var muted: Bool?
        var m = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &m) {
            var v = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &m, 0, nil, &size, &v) == noErr { muted = v != 0 }
        }
        return State(device: device, volumes: volumes, muted: muted)
    }

    /// Volume de referência: o principal, ou o maior dos canais.
    static func level(_ state: State) -> Float32 {
        state.volumes[kAudioObjectPropertyElementMain] ?? state.volumes.values.max() ?? 0
    }

    /// Decibéis que a saída daria no volume `scalar` (curva da própria saída); nil se ela não informa.
    static func decibels(_ state: State, _ scalar: Float32) -> Float32? {
        let ch = state.volumes[kAudioObjectPropertyElementMain] != nil
            ? kAudioObjectPropertyElementMain : (state.volumes.max { $0.value < $1.value }?.key ?? 1)
        var a = address(kAudioDevicePropertyVolumeScalarToDecibels, ch)
        guard AudioObjectHasProperty(state.device, &a) else { return nil }
        var v = scalar
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(state.device, &a, 0, nil, &size, &v) == noErr, v.isFinite else { return nil }
        return v
    }

    /// Ganho linear que faz um som tocado com a saída no volume `from` soar como se ela estivesse em `to`
    /// (1 = igual; < 1 abaixa). Pela curva em dB da saída; sem ela, a razão simples dos volumes.
    static func gain(_ state: State, from: Float32, to: Float32) -> Float32 {
        guard from > 0 else { return 1 }
        if let a = decibels(state, from), let b = decibels(state, to) { return powf(10, (b - a) / 20) }
        return to / from
    }

    /// Põe a saída de `state` no volume `level` (0…1, todos os canais) e tira do mudo.
    static func set(_ state: State, level: Float32) {
        for ch in state.volumes.keys { write(state.device, ch, min(max(level, 0), 1)) }
        if state.muted == true { writeMute(state.device, false) }
    }

    /// Devolve volume e mudo como estavam.
    static func restore(_ state: State) {
        for (ch, v) in state.volumes { write(state.device, ch, v) }
        if let m = state.muted { writeMute(state.device, m) }
    }

    private static func write(_ device: AudioDeviceID, _ ch: UInt32, _ v: Float32) {
        var a = address(kAudioDevicePropertyVolumeScalar, ch)
        var v = v
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static func writeMute(_ device: AudioDeviceID, _ on: Bool) {
        var a = address(kAudioDevicePropertyMute)
        guard settable(device, a) else { return }
        var v = UInt32(on ? 1 : 0)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}
