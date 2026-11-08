import SwiftUI
import CoreGraphics
import ObjectiveC

/// Luz da maçã na tampa do MacBook Pro com tela PROLED XDR (lançado em 06/11/2026). Recurso BETA, nunca testado
/// num Mac de verdade (o usuário não tem um): tudo aqui vem de fontes de fora, conferidas em 07/11/2026.
///
/// - Apagar e reacender: comandos da própria Apple (support.apple.com/en-us/149248),
///   `sudo defaults write|delete com.apple.CoreBrightness LEBacklightMode` (0 = apagada; normal lê 2).
/// - Brilho fixo, solto do brilho da tela: a maçã é um "Light Emitter" (LE) do `corebrightnessd`. Qualquer processo,
///   sem senha, troca a tabela "nits da tela → nits da maçã" pelo `BrightnessSystemClient` privado do CoreBrightness
///   (chave `LEPWMBrightnessNitsMapping`); tabela plana = brilho fixo. O macOS ainda limita pela luz do ambiente.
///   A troca fica gravada nas preferências do root e sobrevive ao reinício: voltar ao normal pede
///   `sudo defaults delete … LEPWMBrightnessNitsMapping` + `sudo killall corebrightnessd`. Fonte: notas do LogoGlow
///   (github.com/sanjitkverma/LogoGlow, docs/superpowers/specs/2026-11-06-logo-effects-design.md, Mac17,12).
/// - Detecção: `copyPropertyForKey:@"LEPWMState"` responde só onde existe a maçã acesa. O macOS 27.2 de um Mac sem
///   a maçã nem tem essas chaves. `LLMBO_LOGO_FAKE=1` mostra a opção em qualquer Mac sem mexer em nada (para retratos).
final class LogoLight: ObservableObject {
    static let shared = LogoLight()

    enum Mode: String, CaseIterable, Identifiable {
        case auto, fixed, agents, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return String(localized: "Automática")
            case .fixed: return String(localized: "Brilho fixo")
            case .agents: return String(localized: "Agentes")
            case .off: return String(localized: "Apagada")
            }
        }
        /// Modos que trocam a tabela de brilho (soltos do brilho da tela).
        var usesMapping: Bool { self == .fixed || self == .agents }
    }

    /// Modo Agentes: o que a maçã mostra (prioridade: terminou > aprovação > trabalhando > parado).
    enum AgentLight: String { case idle, working, waiting }

    static let fake = ProcessInfo.processInfo.environment["LLMBO_LOGO_FAKE"] != nil
    static let levelRange: ClosedRange<Double> = 0.1...1
    /// Brilho máximo pedido (nits). O LogoGlow usa até 600; o macOS corta o que passar do que a luz do ambiente permite.
    static let maxNits = 600.0

    /// Comandos com sudo, os mesmos da regra em `/etc/sudoers.d/llmbo` (`Power.installHelper`).
    static let offArgs = ["/usr/bin/defaults", "write", "com.apple.CoreBrightness", "LEBacklightMode", "-int", "0"]
    static let onArgs = ["/usr/bin/defaults", "delete", "com.apple.CoreBrightness", "LEBacklightMode"]
    static let clearMappingArgs = ["/usr/bin/defaults", "delete", "com.apple.CoreBrightness", "LEPWMBrightnessNitsMapping"]
    static let restartArgs = ["/usr/bin/killall", "corebrightnessd"]
    static var sudoersCommands: [String] {
        [offArgs, onArgs, clearMappingArgs, restartArgs].map { $0.joined(separator: " ") }
    }

    let isSupported: Bool
    @Published private(set) var mode: Mode
    @Published var level: Double {
        didSet {
            UserDefaults.standard.set(level, forKey: "logoLevel")
            if mode == .fixed { applyLevel() } else if mode == .agents { step() }
        }
    }
    /// Apagar ou voltar ao automático falhou por falta da regra nova do sudo.
    @Published private(set) var needsPermission = false

    private let client: NSObject?
    private let d = UserDefaults.standard

    private init() {
        client = Self.fake ? nil : Self.makeClient()
        isSupported = Self.fake || (client.map { Self.copy($0, "LEPWMState") != nil } ?? false)
        let stored = d.double(forKey: "logoLevel")
        level = stored > 0 ? min(max(stored, Self.levelRange.lowerBound), 1) : 0.5
        if let raw = d.string(forKey: "logoMode"), let m = Mode(rawValue: raw) {
            mode = m
        } else if let c = client, (Self.copy(c, "LEBacklightMode") as? NSNumber)?.intValue == 0 {
            mode = .off   // já apagada pelo comando da Apple antes do LlMBO
        } else {
            mode = .auto
        }
        needsPermission = isSupported && !Power.ruleCoversLogo
        // A tabela fica gravada no sistema, mas reaplicar ao abrir não custa nada e cobre um corebrightnessd zerado.
        if isSupported, mode == .fixed { applyLevel() }
        if isSupported, mode == .agents { step() }
    }

    /// O LlMBO mexeu na maçã (o desinstalador devolve o padrão da Apple só nesse caso).
    var touched: Bool { d.bool(forKey: "logoTouched") }

    func setMode(_ new: Mode) {
        guard isSupported, new != mode else { return }
        let old = mode
        var ok = true
        switch new {
        case .off:
            ok = sudo(Self.offArgs)
        case .fixed, .agents:
            if old == .off { ok = sudo(Self.onArgs) }
            if ok, new == .fixed { applyLevel() }
        case .auto:
            if old == .off { ok = sudo(Self.onArgs) }
            if ok, d.bool(forKey: "logoMappingSet") {
                ok = sudo(Self.clearMappingArgs)
                if ok {
                    _ = sudo(Self.restartArgs)   // relê as preferências; o macOS abre o corebrightnessd de novo
                    d.set(false, forKey: "logoMappingSet")
                }
            }
        }
        AppLog.write("maçã: \(old.rawValue) → \(new.rawValue) \(ok ? "ok" : "falhou")")
        guard ok else { needsPermission = true; return }
        needsPermission = false
        mode = new
        d.set(new.rawValue, forKey: "logoMode")
        if new == .agents { lastWritten = nil; step() } else { stopTimer() }
        if new != .auto { d.set(true, forKey: "logoTouched") }
    }

    /// Depois de instalar, atualizar ou tirar a permissão.
    func refreshPermission() {
        needsPermission = isSupported && !Power.ruleCoversLogo
    }

    /// `Power.uninstallHelper` já devolveu o padrão da Apple (como root, no mesmo pedido de senha).
    func didRestoreDefaults() {
        stopTimer()
        mode = .auto
        for k in ["logoMode", "logoMappingSet", "logoTouched"] { d.removeObject(forKey: k) }
        refreshPermission()
    }

    /// Nível 10–100 % → nits numa curva quadrática (o olho percebe melhor a diferença nos níveis baixos).
    static func nits(for level: Double) -> Double { (maxNits * level * level).rounded() }

    private func applyLevel() {
        let n = Self.nits(for: level)
        if client == nil { AppLog.write("maçã (simulada): \(Int(n)) nits") }
        write(n)
    }

    /// Troca a tabela "nits da tela → nits da maçã" por uma plana. O LogoGlow mediu 0,1–0,3 s até a maçã seguir.
    private func write(_ n: Double) {
        guard let c = client else { return }
        let table: NSArray = [[0, n], [2000, n]].map { $0.map { NSNumber(value: $0) } as NSArray } as NSArray
        if Self.set(c, table, "LEPWMBrightnessNitsMapping") {
            d.set(true, forKey: "logoMappingSet")
            d.set(true, forKey: "logoTouched")
        } else {
            AppLog.write("maçã: setProperty LEPWMBrightnessNitsMapping falhou")
        }
    }

    // MARK: - Modo Agentes

    private var agentLight: AgentLight = .idle
    private var finishedAt: Date?
    private var timer: Timer?
    private var lastWritten: Double?
    /// Lidos a cada tick (não a 20 Hz: a tampa vem do IORegistry).
    private var lidClosed = false
    private var displayAsleep = false
    private let started = Date()
    static let flashSeconds = 2.5

    /// Chamado pelo `Engine` no fim de cada tick (5 s, ou 0,05 s depois de um sinal de hook).
    func agentsUpdate(_ statuses: [AgentStatus]) {
        let new: AgentLight = statuses.contains { $0.waitingApproval } ? .waiting
            : statuses.contains { $0.active } ? .working : .idle
        guard mode == .agents, isSupported else { agentLight = new; return }
        let lid = Power.lidClosed
        displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        if new != agentLight || lid != lidClosed {
            agentLight = new
            lidClosed = lid
            AppLog.write("maçã: agentes \(new.rawValue), tampa \(lid ? "fechada" : "aberta")")
            logApplied()
        }
        step()
    }

    /// Diagnóstico para quem tiver o Mac: o que o macOS aplicou de fato (`LEPWMState`, com AppliedNits),
    /// meio segundo depois da troca. Responde se a maçã acende com a tampa fechada.
    private func logApplied() {
        guard let c = client else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let state = Self.copy(c, "LEPWMState").map { "\($0)" } ?? "nil"
            AppLog.write("maçã: LEPWMState " + state.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").prefix(300))
        }
    }

    /// "Agentes terminaram": um clarão que volta devagar ao brilho de repouso.
    func agentsFinished() {
        finishedAt = Date()
        if mode == .agents, isSupported { AppLog.write("maçã: agentes terminaram"); step() }
    }

    /// Fração do brilho escolhido em cada instante (0…1). Pura, para testar sem o hardware.
    static func agentFactor(_ light: AgentLight, t: TimeInterval, sinceFinished: TimeInterval?) -> Double {
        let rest = 0.35
        if let f = sinceFinished, f >= 0, f < flashSeconds {
            if f < 0.15 { return rest + (1 - rest) * f / 0.15 }          // sobe rápido
            return rest + (1 - rest) * exp(-(f - 0.15) * 2.2)          // e apaga devagar
        }
        switch light {
        case .idle:
            return rest
        case .working:                                                  // respira, como a luz de repouso dos MacBook antigos
            return 0.25 + 0.75 * (0.5 - 0.5 * cos(2 * .pi * t / 3.5))
        case .waiting:                                                  // duas piscadas a cada 3 s
            let c = t.truncatingRemainder(dividingBy: 3)
            return (c < 0.15 || (c >= 0.3 && c < 0.45)) ? 1 : 0.2
        }
    }

    /// Sem animação no Modo de Pouca Energia e com a tampa fechada. Tampa fechada: o próprio macOS apaga a maçã.
    /// Conferido em 07/11/2026 no CoreBrightness do macOS 27.2 (26B8125) desses Macs: o `CBLEPWMControlModule` guarda
    /// `ClamshellClosed`, recebe `ClamshellUpdate` e multiplica o brilho por um "Factor" que vai a zero; a tabela
    /// `LEPWMBrightnessNitsMapping` só muda o brilho ANTES desse fator. Animar de tampa fechada só gastaria CPU.
    private var paused: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || lidClosed }

    private func step() {
        guard mode == .agents else { stopTimer(); return }
        let now = Date()
        let since = finishedAt.map { now.timeIntervalSince($0) }
        let flashing = since.map { $0 < Self.flashSeconds } ?? false
        // Ninguém trabalhando e ninguém olhando (tampa fechada ou tela dormindo): apaga. O LlMBO atrasa o sono,
        // não segura o Mac acordado esperando o dia seguinte, e a maçã acesa de tampa fechada diria o contrário.
        let dark = agentLight == .idle && !flashing && (lidClosed || displayAsleep)
        let animating = (agentLight != .idle || flashing) && !paused
        let factor = paused ? 0.35 : Self.agentFactor(agentLight, t: now.timeIntervalSince(started), sinceFinished: since)
        let n = dark ? 0 : Self.nits(for: level * factor).clamped(2, Self.maxNits)
        if lastWritten.map({ abs($0 - n) >= 0.5 }) ?? true {
            lastWritten = n
            write(n)
        }
        if animating, timer == nil {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !animating {
            stopTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Ao sair: a maçã fica parada no brilho de repouso, não no meio de uma piscada.
    func stop() {
        stopTimer()
        if mode == .agents, isSupported { write(Self.nits(for: level * 0.35)) }
    }

    private func sudo(_ args: [String]) -> Bool {
        if Self.fake { AppLog.write("maçã (simulada): sudo \(args.joined(separator: " "))"); return true }
        let r = run("/usr/bin/sudo", ["-n"] + args)
        // `defaults delete` de uma chave que não existe sai com 1, mas o estado é o pedido.
        return r.status == 0 || (args[1] == "delete" && !r.output.contains("sudo:"))
    }

    // MARK: - CoreBrightness privado (dlopen + objc_msgSend)

    private static func makeClient() -> NSObject? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else { return nil }
        return cls.init()
    }

    private static func copy(_ c: NSObject, _ key: String) -> AnyObject? {
        let sel = NSSelectorFromString("copyPropertyForKey:")
        guard c.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let f = unsafeBitCast(c.method(for: sel), to: Fn.self)
        return f(c, sel, key as NSString)?.takeRetainedValue()
    }

    private static func set(_ c: NSObject, _ value: AnyObject, _ key: String) -> Bool {
        let sel = NSSelectorFromString("setProperty:forKey:")
        guard c.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> ObjCBool
        let f = unsafeBitCast(c.method(for: sel), to: Fn.self)
        return f(c, sel, value, key as NSString).boolValue
    }
}

/// Linhas da Aparência (aba Geral): modo da luz da maçã e, no brilho fixo, o controle de brilho.
struct LogoLightRows: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var logo = LogoLight.shared

    var body: some View {
        VStack(spacing: 0) {
            Row(title: String(localized: "Luz da maçã"),
                subtitle: logo.mode == .agents ? String(localized: "Respira trabalhando · pisca pedindo aprovação · brilha ao terminar") : nil,
                info: String(localized: "A maçã acesa na tampa deste MacBook Pro. Automática é o padrão da Apple: acompanha o brilho da tela e a luz do ambiente. Brilho fixo solta a maçã do brilho da tela; o macOS ainda limita pela luz do ambiente. Apagada usa o comando da própria Apple. Recurso em teste, sem documentação da Apple para o brilho: pode parar de funcionar numa atualização do macOS.")
                    + " " + String(localized: "Agentes mostra o que os agentes fazem com a tampa aberta: a maçã respira enquanto trabalham, pisca duas vezes quando um pede aprovação e dá um clarão quando todos terminam. Com a tampa fechada, o próprio macOS apaga a maçã. O controle de brilho vira o brilho máximo. Para no Modo de Pouca Energia."),
                warning: true) {
                HStack(spacing: 8) {
                    BetaBadge()
                    Dropdown(groups: [DropdownGroup(items: LogoLight.Mode.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                             selection: logo.mode, width: 160,
                             onSelect: { logo.setMode($0) }) {
                        DropdownLabel(text: logo.mode.title)
                    }
                }
            }
            if logo.mode.usesMapping {
                CardDivider()
                Row(title: String(localized: "Brilho da maçã")) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        ThemedSlider(value: $logo.level, title: String(localized: "Brilho da maçã"),
                                     range: LogoLight.levelRange, step: 0.1)
                            .frame(width: 150)
                        Image(systemName: "sun.max.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        Text(verbatim: "\(Int((logo.level * 100).rounded())) %")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
            if logo.needsPermission {
                CardDivider()
                Row(title: String(localized: "Apagar e voltar ao automático precisam da permissão atualizada"), warning: true) {
                    Button(String(localized: "Atualizar permissão")) { engine.installHelper() }
                        .buttonStyle(.pill(.primary))
                }
            }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
