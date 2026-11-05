import AppKit
import UserNotifications

/// Notificações na Central de Notificações do macOS, só para o que importa fora do app:
/// por que o LlMBO religou o repouso (e se o Mac vai dormir) e o aviso de Mac quente.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// `notAsked`: o macOS ainda não perguntou. `unknown`: antes da primeira leitura.
    enum Status { case unknown, notAsked, allowed, denied }
    @Published private(set) var status: Status = .unknown
    /// Já pedimos nesta abertura. Sem a assinatura paga, o 1º pedido pode falhar sem mostrar nada
    /// (o status fica "não perguntado"); aí o assistente oferece os Ajustes em vez de "Permitir" de novo.
    @Published private(set) var asked = false

    /// Chave geral da aba Notificações ("Receber notificações"): desligada, o LlMBO não manda aviso nenhum
    /// (nem som). Só o teste (`sendTest`) passa por cima.
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "notifyOnSleep") } }
    /// Com a tampa fechada, a notificação sai muda e o LlMBO toca o próprio som (com volume escolhido)
    /// — ou nenhum. Com a tampa aberta vale o som normal das notificações do macOS.
    /// "Tocar som" (cartão Sons): desligado, o LlMBO fica mudo — nada de som, com a tampa aberta ou fechada.
    @Published var soundEnabled: Bool { didSet { UserDefaults.standard.set(soundEnabled, forKey: "notifySoundEnabled") } }
    /// "Quando tocar": com a tampa aberta, fechada ou nas duas (padrão). Substitui o antigo "Som com a tampa
    /// fechada" (`notifyLidSound`; desligado = só com a tampa aberta).
    @Published var soundWhen: SoundWhen { didSet { UserDefaults.standard.set(soundWhen.rawValue, forKey: "notifySoundWhen") } }

    /// Se o som do aviso toca agora, conforme a tampa.
    func soundPlays(lidClosed: Bool) -> Bool {
        guard soundEnabled else { return false }
        switch soundWhen {
        case .both: return true
        case .lidClosed: return lidClosed
        case .lidOpen: return !lidClosed
        }
    }
    /// 0…1. Com `lidVolumeIndependent`, é o volume de saída enquanto o som toca; sem, uma fração do volume do Mac
    /// (NSSound não passa do volume do sistema).
    @Published var lidVolume: Double { didSet { UserDefaults.standard.set(lidVolume, forKey: "notifyLidVolume") } }
    /// "Volume independente do Mac": ajusta a saída para `lidVolume` (tirando do mudo) só durante o som e devolve depois.
    @Published var lidVolumeIndependent: Bool {
        didSet { UserDefaults.standard.set(lidVolumeIndependent, forKey: "notifyLidVolumeIndependent") }
    }
    /// "Não mudar o volume de outros apps" (macOS 14.2+, desligado por padrão): quando o LlMBO precisa subir a saída,
    /// os outros apps tocam no volume de antes (`OtherAppsVolume`). Pede a permissão de gravação de áudio do sistema.
    @Published var keepOthersVolume: Bool {
        didSet {
            UserDefaults.standard.set(keepOthersVolume, forKey: "notifyKeepOthersVolume")
            if keepOthersVolume && OtherAppsVolume.permission() != .allowed {
                OtherAppsVolume.request { _ in Notifier.shared.refreshOthersPermission() }
            }
            refreshOthersPermission()
        }
    }
    @Published private(set) var othersPermission: OtherAppsVolume.Permission = .unknown
    /// Lista "Volume do aviso" (aba Notificações): junta `lidVolumeIndependent` e `keepOthersVolume`, que continuam
    /// gravados como antes. A terceira escolha só existe no macOS 14.2+.
    var volumeMode: VolumeMode {
        get { !lidVolumeIndependent ? .followMac : (keepOthersVolume ? .keepOthers : .independent) }
        set {
            lidVolumeIndependent = newValue != .followMac
            let keep = newValue == .keepOthers && OtherAppsVolume.supported
            if keepOthersVolume != keep { keepOthersVolume = keep }
        }
    }
    /// Repasse dos outros apps enquanto a saída está acima do volume de antes.
    private var others: OtherAppsVolume?
    /// Como foi o último toque, para o sound.log: relativo, sistema, sistema+outros.
    private var lastMode = ""
    /// Som do aviso, com a tampa fechada (tocado pelo LlMBO) e aberta (som da notificação).
    @Published var soundChoice: NotifySound { didSet { UserDefaults.standard.set(soundChoice.rawValue, forKey: "notifySound") } }
    /// Volume e mudo de antes do som, até serem devolvidos.
    private var savedVolume: SystemVolume.State?
    static let lidVolumeRange: ClosedRange<Double> = 0.2...1
    private var restoreWork: DispatchWorkItem?
    /// afplay do som da tampa fechada, enquanto toca.
    private var player: Process?

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        enabled = UserDefaults.standard.object(forKey: "notifyOnSleep") as? Bool ?? true
        soundEnabled = UserDefaults.standard.object(forKey: "notifySoundEnabled") as? Bool ?? true
        soundWhen = SoundWhen(rawValue: UserDefaults.standard.string(forKey: "notifySoundWhen") ?? "")
            ?? ((UserDefaults.standard.object(forKey: "notifyLidSound") as? Bool ?? true) ? .both : .lidOpen)
        // 20…100 % de 10 em 10: abaixo de 20 % o som quase não se ouve atrás da tampa (valores antigos se ajustam).
        let v = UserDefaults.standard.object(forKey: "notifyLidVolume") as? Double ?? 0.5
        lidVolume = min(max((v * 10).rounded() / 10, Notifier.lidVolumeRange.lowerBound), Notifier.lidVolumeRange.upperBound)
        // "Sonda" e "Nave" viraram Voyage e Espaçonave (04/11/2026): a escolha antiga passa para o nome novo.
        let savedSound = ["Sonda": "Voyage", "Nave": "Espaconave"][UserDefaults.standard.string(forKey: "notifySound") ?? ""]
            ?? UserDefaults.standard.string(forKey: "notifySound") ?? ""
        let sound = NotifySound(rawValue: savedSound) ?? .supernova
        UserDefaults.standard.set(sound.rawValue, forKey: "notifySound")   // o didSet não roda no init
        soundChoice = sound
        lidVolumeIndependent = UserDefaults.standard.object(forKey: "notifyLidVolumeIndependent") as? Bool ?? true
        keepOthersVolume = OtherAppsVolume.supported && UserDefaults.standard.bool(forKey: "notifyKeepOthersVolume")
        super.init()
        center.delegate = self
        // Na primeira abertura quem pede é o passo Preferências do assistente, com a explicação na tela;
        // pedir aqui faria o macOS perguntar por cima das boas-vindas.
        if OnboardingModel.needed { refresh() } else { requestPermission() }
        // Volta dos Ajustes do Sistema: relê a permissão.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in Notifier.shared.refresh(); Notifier.shared.refreshOthersPermission() }
        }
        refreshOthersPermission()
    }

    func refreshOthersPermission() {
        othersPermission = OtherAppsVolume.supported ? OtherAppsVolume.permission() : .unknown
    }

    /// Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.
    func openAudioCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        center.getNotificationSettings { settings in
            let s: Status
            switch settings.authorizationStatus {
            case .authorized, .provisional: s = .allowed
            case .denied: s = .denied
            case .notDetermined: s = .notAsked
            default: s = .unknown
            }
            Task { @MainActor in self.status = s }
        }
    }

    /// Pede a permissão (o macOS só pergunta uma vez; depois, só nos Ajustes do Sistema).
    func requestPermission() {
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Envia uma notificação; `done` roda quando o macOS já a registrou (ou falhou), para o chamador só
    /// pôr o Mac para dormir depois.
    func post(_ body: String, force: Bool = false, done: (() -> Void)? = nil) {
        guard enabled || force else { done?(); return }
        // O LlMBO toca o som ele mesmo, no volume escolhido, e a notificação sai muda: o macOS não acha o .aiff
        // dentro do app (sem assinatura paga caía no som padrão) e o som padrão seguiria o volume do Mac.
        let lidClosed = Power.lidClosed
        if soundPlays(lidClosed: lidClosed) { playSound() }
        // Sem a assinatura paga da Apple, o macOS recusa notificações do próprio app
        // ("Notifications are not allowed for this application"). Aí a notificação sai pelo AppleScript
        // e aparece na Central com o nome/ícone do Editor de Scripts (sem som).
        guard status == .allowed else { postViaScript(body, done: done); return }
        let content = UNMutableNotificationContent()
        content.title = "LlMBO"
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { _ in
            Task { @MainActor in done?() }
        }
    }

    /// Versão nova no GitHub: aviso discreto, sem o som do aviso de dormir.
    func updateAvailable(_ version: String) {
        guard enabled, status == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "LlMBO"
        content.body = String(localized: "Versão \(version) disponível. Atualize na aba Sobre.")
        center.add(UNNotificationRequest(identifier: "llmbo-update", content: content, trigger: nil))
    }

    private func postViaScript(_ body: String, done: (() -> Void)?) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"LlMBO\""]
        p.terminationHandler = { _ in Task { @MainActor in done?() } }
        do { try p.run() } catch { done?() }
    }

    /// Som do aviso no volume escolhido; com a tampa fechada, 25 % acima (a tampa abafa; até 100 %).
    /// Independente: abaixo do volume do Mac, toca numa fração calculada pela curva em dB da saída, sem mexer no
    /// sistema; acima (ou no mudo), a saída vai para esse volume só enquanto ele toca e volta como estava logo depois
    /// — com `keepOthersVolume`, os outros apps continuam no volume de antes.
    /// Saída sem volume ajustável: fração do volume do Mac. Toca pelo afplay, o único jeito ouvido de verdade atrás
    /// da tampa (Design/lidtest/soundtest.sh); pelo NSSound do app o aviso saiu e o som não (03/11/2026).
    func playSound() {
        player?.terminate()
        let lidClosed = Power.lidClosed
        let level = lidClosed ? min(lidVolume * 1.25, 1) : lidVolume
        var gain = Float(level)
        lastMode = "relativo"
        if lidVolumeIndependent, let state = savedVolume ?? SystemVolume.current() {
            let before = SystemVolume.level(state)
            let target = Float32(level)
            if state.muted != true, before > 0, target <= before {
                // Cabe no volume do Mac: o sistema fica como está (desfaz um toque anterior que o tenha subido).
                if savedVolume != nil { restoreVolume() }
                gain = Float(SystemVolume.gain(state, from: before, to: target))
                lastMode = "fração"
            } else {
                // Toques seguidos (o controle de volume) guardam só o estado de antes do primeiro.
                savedVolume = state
                if keepOthersVolume, others == nil { others = OtherAppsVolume.start(device: state.device) }
                SystemVolume.set(state, level: target)
                // +4 dB de ouvido (`notifyOthersBoostDB` muda): a conta pela curva da saída está exata, mas a música
                // repassada soa um pouco mais baixa (o alto-falante ajusta a equalização ao volume; o aviso mascara).
                let boost = Float32(UserDefaults.standard.object(forKey: "notifyOthersBoostDB") as? Double ?? 4)
                others?.gain = state.muted == true ? 0
                    : min(SystemVolume.gain(state, from: target, to: before) * powf(10, boost / 20), 1)
                gain = 1
                lastMode = others == nil ? (keepOthersVolume ? "sistema (tcc=\(OtherAppsVolume.preflightRaw()))" : "sistema") : String(format: "sistema+outros antes=%.0f%% (%.1f dB) alvo %.1f dB",
                    before * 100, SystemVolume.decibels(state, before) ?? .nan, SystemVolume.decibels(state, target) ?? .nan)
            }
        }
        restoreWork?.cancel()
        restoreWork = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", String(format: "%.4f", gain), soundChoice.fileURL.path]
        p.terminationHandler = { proc in
            Task { @MainActor in
                // Só devolve o volume quando o último toque acabou (o seguinte já terá trocado o player).
                guard Notifier.shared.player === proc else { return }
                Notifier.shared.player = nil
                let work = DispatchWorkItem { Notifier.shared.restoreVolume() }
                Notifier.shared.restoreWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
        }
        var played = true
        do { try p.run(); player = p } catch { played = false; player = nil; restoreVolume() }
        logSound(lidClosed: lidClosed, played: played)
    }

    /// Uma linha por toque em sound.log (últimas 50): com a tampa fechada não dá para ouvir o que aconteceu.
    private func logSound(lidClosed: Bool, played: Bool) {
        let url = Paths.support.appendingPathComponent("sound.log")
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let vol = SystemVolume.current().map { st in
            String(format: "%.0f%%", (st.volumes[0] ?? st.volumes.values.max() ?? 0) * 100) + (st.muted == true ? " mudo" : "")
        } ?? "?"
        let line = "\(f.string(from: Date())) som=\(soundChoice.rawValue) tampa=\(lidClosed ? "fechada" : "aberta") "
            + "tocou=\(played) volume-saida=\(vol) escolhido=\(Int(lidVolume * 100))% independente=\(lidVolumeIndependent) modo=\(lastMode)"
        appendSoundLog(line)
    }

    private func appendSoundLog(_ line: String) {
        let url = Paths.support.appendingPathComponent("sound.log")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(line)
        try? lines.suffix(50).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Devolve o volume e o mudo de antes do som (também ao sair do app).
    func restoreVolume() {
        restoreWork?.cancel()
        restoreWork = nil
        if let state = savedVolume { SystemVolume.restore(state) }
        savedVolume = nil
        // Depois de devolver o volume: na ordem inversa, os outros apps soariam alto por um instante.
        if let o = others { appendSoundLog(o.diagnostics) }
        others?.stop()
        others = nil
    }

    /// Quanto o Mac deve esperar antes de dormir para o som não ser cortado (0 se não vai tocar).
    var lidSoundDuration: TimeInterval {
        enabled && soundPlays(lidClosed: true) ? (soundChoice.sound?.duration ?? 1.7) : 0
    }

    /// Botão "Testar": manda uma notificação de exemplo mesmo com a opção desligada.
    func sendTest() {
        post(String(localized: "Teste: é assim que o LlMBO avisa quando o Mac vai dormir."), force: true)
    }

    /// Com LLMBO_TEST_NOTIFY=1: pede a permissão, manda uma notificação de teste e grava o resultado em
    /// notify.log (para conferir se o macOS aceita notificações deste app, que não tem assinatura paga).
    func selfTest() {
        var lines: [String] = []
        let log = { (s: String) in
            lines.append(s)
            try? lines.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("notify.log"),
                                                     atomically: true, encoding: .utf8)
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                log("permissão: \(granted) erro: \(error.map { "\($0)" } ?? "nenhum")")
                let content = UNMutableNotificationContent()
                content.title = "LlMBO"
                content.body = String(localized: "Notificações")
                let req = UNNotificationRequest(identifier: "llmbo-teste", content: content, trigger: nil)
                self.center.add(req) { error in
                    Task { @MainActor in
                        log("envio: \(error.map { "\($0)" } ?? "ok")")
                        self.center.getNotificationSettings { s in
                            let st = s.authorizationStatus.rawValue, al = s.alertSetting.rawValue
                            Task { @MainActor in
                                log("status=\(st) alertas=\(al)")
                                self.refresh()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    let via = self.status == .allowed ? "LlMBO" : "Editor de Scripts"
                                    self.sendTest()
                                    log("teste do app enviado por: \(via)")
                                }
                            }
                        }
                        self.refresh()
                    }
                }
            }
        }
    }

    /// Mostra a notificação mesmo com o app em primeiro plano.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Sons do aviso. Horizonte e Supernova são do próprio LlMBO (Design/render_sounds.swift, em Contents/Resources);
/// Glass é o som do macOS que o LlMBO usava antes.
enum SoundWhen: String, CaseIterable, Identifiable {
    case both, lidClosed, lidOpen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return String(localized: "Tampa aberta e fechada")
        case .lidClosed: return String(localized: "Só com a tampa fechada")
        case .lidOpen: return String(localized: "Só com a tampa aberta")
        }
    }
}

enum VolumeMode: String, CaseIterable, Identifiable {
    case followMac, independent, keepOthers

    var id: String { rawValue }

    static var available: [VolumeMode] { OtherAppsVolume.supported ? allCases : [.followMac, .independent] }

    var title: String {
        switch self {
        case .followMac: return String(localized: "Junto com o Mac")
        case .independent: return String(localized: "Independente")
        case .keepOthers: return String(localized: "Independente, sem mexer nos outros apps")
        }
    }

    /// Rótulo da pílula: o título inteiro da terceira escolha não cabe ao lado de "Volume do aviso".
    var shortTitle: String {
        self == .keepOthers ? String(localized: "Sem mexer nos outros apps") : title
    }
}

enum NotifySound: String, CaseIterable, Identifiable {
    case horizon = "Horizonte", supernova = "Supernova", voyage = "Voyage", spaceship = "Espaconave", saturn = "Saturno", nebula = "Nebulosa", glass = "Glass"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizon: return String(localized: "Horizonte")
        case .supernova: return String(localized: "Supernova")
        case .voyage: return String(localized: "Voyage")
        case .spaceship: return String(localized: "Espaçonave")
        case .saturn: return String(localized: "Saturno")
        case .nebula: return String(localized: "Nebulosa")
        case .glass: return String(localized: "Vidro (do macOS)")
        }
    }

    var sound: NSSound? { NSSound(named: rawValue) }

    /// Arquivo do som: os do LlMBO ficam em Contents/Resources; o Glass é do macOS.
    var fileURL: URL {
        Bundle.main.url(forResource: rawValue, withExtension: "aiff")
            ?? URL(fileURLWithPath: "/System/Library/Sounds/\(rawValue).aiff")
    }
}
