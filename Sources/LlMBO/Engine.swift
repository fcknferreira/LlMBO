import AppKit
import Foundation
import ServiceManagement

struct AgentStatus: Identifiable {
    let id: String
    let name: String
    let running: Bool
    let active: Bool
    let cpu: Double
    let viaHook: Bool
    /// Por que conta como trabalhando (ou o último sinal visto), para mostrar na interface.
    let reason: String?
    let hook: Hooks.State
    /// Hook completo instalado: só ele decide, e ainda não chegou nenhum aviso deste agente.
    var waitingHook = false
    /// Parado pedindo aprovação, e o Mac está sendo segurado para você responder ("Esperar acordado por aprovações").
    var waitingApproval = false
    /// "Só confiar em hooks" ligado e este agente não manda sinal: aparece, mas não segura o Mac.
    var ignoredNoHook = false
    /// Limite de uso: o agente parado esperando o reset (Claude Code, Antigravity), e quando ele volta.
    var waitingQuota = false
    var quotaReset: Date?
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    /// Modo automático ligado ("Liberar tampa fechada"). Ligado, o LlMBO segura o repouso só enquanto há agente
    /// trabalhando e o devolve quando todos terminam, sem se desligar. Bateria, tempo máximo e temperatura desligam.
    @Published private(set) var armed = false {
        // Estado em arquivo (Application Support/armed: "1"/"0") para diagnóstico e roteiros de teste
        // (Design/lidtest), que não enxergam o app de fora.
        didSet { if armed != oldValue { try? (armed ? "1" : "0").write(to: Paths.support.appendingPathComponent("armed"), atomically: true, encoding: .utf8) } }
    }
    /// Repouso desligado agora (pmset disablesleep 1) porque há agente trabalhando.
    @Published private(set) var holding = false
    /// Religar o modo automático quando a tampa é aberta, se estiver desligado (por você ou por uma trava).
    @Published var armOnLidOpen: Bool { didSet { UserDefaults.standard.set(armOnLidOpen, forKey: "armOnLidOpen") } }
    /// Inverte os cliques do ícone da barra (aba Geral): esquerdo abre o menu, direito liga/desliga.
    @Published var swapStatusClicks: Bool { didSet { UserDefaults.standard.set(swapStatusClicks, forKey: "swapStatusClicks") } }
    private var lidWasClosed = Power.lidClosed
    @Published private(set) var statuses: [AgentStatus] = []
    /// Tarefas longas seguradas por `llmbo-signal hold` ou pelo servidor MCP (Holds.swift).
    @Published private(set) var holds: [HoldTask] = []
    /// Servidor MCP do LlMBO ligado no Claude Code / no Codex (MCP.swift).
    /// Destinos (MCPInstall.targets) com o servidor MCP do LlMBO instalado.
    @Published private(set) var mcpInstalled = Set(MCPInstall.targets.filter(MCPInstall.isInstalled).map(\.id))
    @Published private(set) var helperInstalled = Power.helperInstalled
    /// Vigia contra travamento (Watchdog.swift); o usuário pode desligá-lo nos Itens de Início.
    @Published private(set) var watchdogStatus = Watchdog.Status.off
    @Published var message: String? { didSet { if let message { AppLog.write(message) } } }
    /// Retorno das ações de hooks e agentes, mostrado só na aba Agentes (o resto fica no Geral e no menu).
    @Published var agentMessage: String? { didSet { if let agentMessage { AppLog.write(agentMessage) } } }
    @Published private(set) var hookStates: [String: Hooks.State] = [:]

    @Published var graceMinutes: Int { didSet { UserDefaults.standard.set(graceMinutes, forKey: "graceMinutes") } }
    /// Minutos que o Mac fica acordado com um agente pedindo aprovação (0 = dorme como se tivesse terminado).
    @Published var approvalWaitMinutes: Int { didSet { UserDefaults.standard.set(approvalWaitMinutes, forKey: "approvalWaitMinutes") } }
    static let approvalWaitOptions = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
    /// Minutos que uma tarefa em segundo plano do Claude Code (Bash com run_in_background, Monitor) conta como
    /// trabalho depois que a resposta termina, contados desde que a tarefa começou (0 = não conta).
    @Published var backgroundTaskMinutes: Int { didSet { UserDefaults.standard.set(backgroundTaskMinutes, forKey: "backgroundTaskMinutes") } }
    static let backgroundTaskOptions = [0, 10, 15, 30, 45, 60, 90, 120]
    /// Segundos que o Mac fica acordado depois que os agentes terminam, antes de voltar ao repouso do macOS.
    @Published var sleepDelaySeconds: Int { didSet { UserDefaults.standard.set(sleepDelaySeconds, forKey: "sleepDelaySeconds") } }
    /// Valores do "Atrasar o repouso": segundos no começo, minutos depois.
    static let sleepDelayOptions = [0, 5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600, 900, 1200, 1800]
    @Published var minBattery: Int { didSet { UserDefaults.standard.set(minBattery, forKey: "minBattery") } }
    /// Tempo máximo acordado na bateria (a chave antiga "maxHours" virou o limite da bateria).
    @Published var maxHours: Int { didSet { UserDefaults.standard.set(maxHours, forKey: "maxHours") } }
    /// Nível térmico do macOS a partir do qual o Mac dorme de tampa fechada (e avisa de tampa aberta).
    @Published var thermalLimit: ThermalLimit {
        didSet { UserDefaults.standard.set(thermalLimit.rawValue, forKey: "thermalLimit") }
    }
    /// Tampa fechada, segurando o repouso e sem monitor externo: apaga a tela interna (bateria, calor, marca na tela).
    @Published var darkenLidClosed: Bool { didSet { UserDefaults.standard.set(darkenLidClosed, forKey: "darkenLidClosed") } }
    /// Última vez que o LlMBO apagou a tela; nil com a tampa aberta.
    private var darkenedAt: Date?
    /// Retomar sessões do Codex paradas no limite, em segundo plano (CodexResume.swift). Desligado por padrão.
    /// "Retomar sozinho" escolhido para o Codex (antes era um interruptor à parte, chave "codexAutoResume").
    var codexAutoResume: Bool { codexQuotaMode == .resume }
    /// Limites do Claude Code pelo `claude -p /usage` (ClaudeUsageCLI); desligado por padrão.
    @Published var claudeUsageCLI: Bool {
        didSet {
            UserDefaults.standard.set(claudeUsageCLI, forKey: ClaudeUsageCLI.defaultsKey)
            UsageStore.shared.readClaudeUsage = claudeUsageCLI && claudeListed
        }
    }
    var claudeListed: Bool { agents.contains { $0.id == "claude" && $0.isEnabled } }
    /// O Claude Code de terminal existe neste Mac (vem com o app Claude ou instalado à parte).
    var claudeCLIFound: Bool { MCPInstall.claudeCLI != nil }
    /// Cota do Antigravity pelo servidor local dele (AntigravityQuota); desligada por padrão.
    @Published var antigravityQuota: Bool {
        didSet {
            UserDefaults.standard.set(antigravityQuota, forKey: AntigravityQuota.defaultsKey)
            UsageStore.shared.readAntigravityQuota = antigravityQuota && antigravityListed
        }
    }
    var antigravityListed: Bool { agents.contains { $0.id.hasPrefix("antigravity") && $0.isEnabled } }
    let codexResume = CodexResume()
    /// Retomar conversas do Antigravity paradas no limite, guiado pela cota (AntigravityResume.swift). Desligado
    /// por padrão; ligar também liga a leitura da cota, que é quem diz quando ela volta.
    /// "Retomar sozinho" escolhido para o Antigravity (antes um interruptor à parte, chave "antigravityAutoResume").
    var antigravityAutoResume: Bool { antigravityQuotaMode == .resume }
    let antigravityResume = AntigravityResume()
    /// O que fazer quando o Claude Code bate no limite de uso (aba Uso). Chave antiga "quotaMode", de quando valia para todos.
    @Published var quotaMode: QuotaMode { didSet { UserDefaults.standard.set(quotaMode.rawValue, forKey: "quotaMode") } }
    /// O mesmo para o Antigravity (app, IDE e CLI). Padrão "Não esperar": ele não continua sozinho depois do limite.
    @Published var antigravityQuotaMode: QuotaMode {
        didSet {
            UserDefaults.standard.set(antigravityQuotaMode.rawValue, forKey: "antigravityQuotaMode")
            // A retomada depende da leitura da cota, que diz quando ela volta.
            if antigravityQuotaMode == .resume, !antigravityQuota { antigravityQuota = true }
        }
    }
    /// O mesmo para o Codex. Antes ele seguia, sem mostrar, a escolha do Claude Code. Padrão "Não esperar":
    /// ele não continua sozinho.
    @Published var codexQuotaMode: QuotaMode {
        didSet { UserDefaults.standard.set(codexQuotaMode.rawValue, forKey: "codexQuotaMode") }
    }
    /// Escolha de cada agente para o limite de uso.
    func quotaMode(for id: String) -> QuotaMode {
        if id.hasPrefix("antigravity") { return antigravityQuotaMode }
        if id == "codex" { return codexQuotaMode }
        return quotaMode
    }
    /// A regra do sudo já libera `pmset schedule wake` (instalada por esta versão).
    @Published private(set) var canScheduleWake = false
    /// Despertar agendado pelo LlMBO para o agente continuar depois do limite.
    @Published private(set) var scheduledWake: Date?
    /// Último limite estourado já registrado no quota-events.log, por agente (uma linha por parada).
    private var loggedQuota: [String: Date] = [:]
    /// Barra de status do Claude Code ligada ao LlMBO (lê os limites de uso).
    @Published private(set) var claudeStatusLine = Hooks.statusLineInstalled
    /// Tempo máximo acordado na tomada; 0 = sem limite.
    @Published var maxHoursAC: Int { didSet { UserDefaults.standard.set(maxHoursAC, forKey: "maxHoursAC") } }
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
    /// "Só confiar em hooks": agente sem hook não segura o Mac acordado (CPU e arquivos não contam).
    @Published var strictHooks: Bool { didSet { UserDefaults.standard.set(strictHooks, forKey: "strictHooks") } }
    @Published var language: AppLanguage { didSet { language.save() } }
    /// Idioma com que este processo abriu (a interface só troca ao reabrir).
    let launchLanguage = AppLanguage.saved
    @Published var iconStyle: IconStyle { didSet { UserDefaults.standard.set(iconStyle.rawValue, forKey: "iconStyle"); iconStyle.apply() } }

    @Published private(set) var agents: [AgentConfig] = []
    private var lastCPU: [String: Date] = [:]
    /// Leituras seguidas (a cada 5 s) com CPU acima do limite; pico isolado não conta como trabalho.
    private var cpuStreak: [String: Int] = [:]
    /// Como a CPU: GPU acima do limite em leituras seguidas (GPU.swift).
    private var lastGPU: [String: Date] = [:]
    private var gpuStreak: [String: Int] = [:]
    private let gpuSampler = GPUSampler()
    /// Aviso de Mac quente (tampa aberta) já mostrado; volta a avisar depois que esfriar.
    private var hotWarned = false
    /// Agentes cujo hook já mandou algum sinal: só então o hook passa a decidir sozinho
    /// (ex.: o Codex só roda hook novo depois que o usuário aprova em /hooks).
    /// Canário do hook mudo: vezes seguidas em que o agente trabalhou (arquivos de sessão mexendo) sem nenhum sinal
    /// do hook instalado, e quando foi a última. Um sinal do hook zera.
    private var muteEpisodes: [String: Int] = [:]
    private var muteEpisodeAt: [String: Date] = [:]
    private var sleepGuard = Power.SleepGuard()
    /// Quando a última leva de agentes terminou (o aviso "Agentes terminaram às X"), para os widgets.
    private(set) var lastFinishedAt: Date? = UserDefaults.standard.object(forKey: "lastAgentsFinished") as? Date {
        didSet { UserDefaults.standard.set(lastFinishedAt, forKey: "lastAgentsFinished") }
    }
    /// Hora em que o repouso normal volta, enquanto espera depois do fim (5 s + "Atrasar o repouso").
    var sleepReturnsAt: Date? { quietSince.map { $0.addingTimeInterval(confirmQuiet + TimeInterval(sleepDelaySeconds)) } }
    private var hookSeen: Set<String> = [] {
        didSet { if hookSeen != oldValue { UserDefaults.standard.set(Array(hookSeen), forKey: "hookSeen") } }
    }
    private let sustainedSamples = 3
    /// Desde quando o repouso está desligado (o tempo máximo conta daqui).
    private var holdingSince: Date?
    private var quietSince: Date?
    /// Já avisou que os agentes terminaram (o aviso sai na hora; o repouso volta depois do atraso, sem outro aviso).
    private var notifiedEarly = false
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    /// Vigia da pasta de sinais: um aviso de hook roda o tick na hora, sem esperar a próxima volta de 5 s.
    private var signalSource: DispatchSourceFileSystemObject?
    private var signalTick: DispatchWorkItem?
    /// Conferência marcada para o instante exato do fim da espera (aviso adiantado ou fim do atraso).
    private var quietCheck: DispatchWorkItem?
    private let watcher = ActivityWatcher()

    /// Quanto tempo tudo precisa ficar quieto antes de dormir (além da espera por CPU).
    private let confirmQuiet: TimeInterval = 5

    private init() {
        let d = UserDefaults.standard
        graceMinutes = d.object(forKey: "graceMinutes") as? Int ?? 5
        approvalWaitMinutes = d.object(forKey: "approvalWaitMinutes") as? Int ?? 15
        backgroundTaskMinutes = d.object(forKey: "backgroundTaskMinutes") as? Int ?? 60
        // Versões anteriores guardavam minutos ("sleepDelayMinutes").
        sleepDelaySeconds = d.object(forKey: "sleepDelaySeconds") as? Int
            ?? (d.object(forKey: "sleepDelayMinutes") as? Int).map { $0 * 60 } ?? 120
        minBattery = d.object(forKey: "minBattery") as? Int ?? 15
        maxHours = d.object(forKey: "maxHours") as? Int ?? 8
        maxHoursAC = d.object(forKey: "maxHoursAC") as? Int ?? 12
        thermalLimit = ThermalLimit(rawValue: d.object(forKey: "thermalLimit") as? Int ?? -1) ?? .recommended
        darkenLidClosed = d.object(forKey: "darkenLidClosed") as? Bool ?? true
        let savedMode = QuotaMode(rawValue: d.object(forKey: "quotaMode") as? Int ?? -1) ?? .wake
        quotaMode = savedMode == .resume ? .wake : savedMode   // o Claude Code continua sozinho: não tem "Retomar"
        let agMode: QuotaMode = d.bool(forKey: "antigravityAutoResume") ? .resume
            : QuotaMode(rawValue: d.object(forKey: "antigravityQuotaMode") as? Int ?? -1) ?? .ignore
        antigravityQuotaMode = agMode
        // Migração (08/11/2026): os interruptores de retomada viraram a opção "Retomar sozinho" da lista.
        let codexMode: QuotaMode = d.bool(forKey: "codexAutoResume") ? .resume
            : QuotaMode(rawValue: d.object(forKey: "codexQuotaMode") as? Int ?? -1) ?? .ignore
        codexQuotaMode = codexMode
        if d.object(forKey: "codexAutoResume") != nil || d.object(forKey: "antigravityAutoResume") != nil {
            d.set(codexMode.rawValue, forKey: "codexQuotaMode")   // no init o didSet não roda
            d.set(agMode.rawValue, forKey: "antigravityQuotaMode")
            d.removeObject(forKey: "codexAutoResume")
            d.removeObject(forKey: "antigravityAutoResume")
        }
        antigravityQuota = d.bool(forKey: AntigravityQuota.defaultsKey)
        // Quem só tinha a barra de status ligada (antes eram duas opções) passa a ter as duas leituras.
        claudeUsageCLI = d.bool(forKey: ClaudeUsageCLI.defaultsKey) || Hooks.statusLineInstalled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        strictHooks = d.bool(forKey: "strictHooks")
        // "Ligar ao abrir o LlMBO" virou fixo (04/11/2026): ligado sem agente não faz nada, e assim ninguém esquece.
        d.removeObject(forKey: "armOnLaunch")
        armOnLidOpen = d.object(forKey: "armOnLidOpen") as? Bool ?? true
        swapStatusClicks = d.bool(forKey: "swapStatusClicks")
        hookSeen = Set(d.stringArray(forKey: "hookSeen") ?? [])
        language = AppLanguage.saved
        iconStyle = IconStyle(rawValue: d.string(forKey: "iconStyle") ?? "") ?? .dark
        iconStyle.apply()

        Paths.prepare()
        agents = AgentStore.load()
        Hooks.cleanUpLegacy()
        Hooks.upgradeOutdated()
        refreshHooks()

        // Troca de versão (update.command): o app anterior saiu sem devolver o repouso; este assume o Mac
        // seguro de onde ele parou, para a tampa fechada não dormir no meio da atualização.
        if let since = Self.takeHandoff(), Power.sleepDisabled {
            holding = true
            holdingSince = since
            Watchdog.setHolding(true)
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "LlMBO aguardando agentes")
        } else {
            // Se o app fechou de forma inesperada com o repouso desligado, restaura.
            if Power.sleepDisabled { Power.setSleepDisabled(false) }
            Watchdog.setHolding(false)
        }
        if helperInstalled { Watchdog.install() }
        watchdogStatus = Watchdog.status
        canScheduleWake = helperInstalled && Power.canScheduleWake
        _ = UsageStore.shared

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        watchSignals()
        // Liga antes da primeira conferência: desligado, o tick solta o Mac assumido de uma atualização.
        arm(quietly: true)
        if !armed { tick() }
    }

    /// O script troca o arquivo de sinal com mv, o que muda a pasta. Vários avisos seguidos (cada ferramenta
    /// manda um) viram um tick só, 0,05 s depois do primeiro.
    private func watchSignals() {
        let fd = open(Paths.signals.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.signalTick == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in self?.signalTick = nil; self?.tick() }
                }
                self.signalTick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        signalSource = src
    }

    /// Marca um tick para quando a espera de quietude chegar a `seconds` (o timer de 5 s cairia até 5 s depois).
    private func scheduleQuietCheck(_ q: Date, after seconds: TimeInterval, now: Date) {
        quietCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.tick() } }
        quietCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, q.addingTimeInterval(seconds).timeIntervalSince(now) + 0.05),
                                      execute: work)
    }

    // MARK: Ações

    /// Liga o modo automático. Não desliga o repouso na hora: isso só acontece quando algum agente trabalha.
    func arm(quietly: Bool = false) {
        guard helperInstalled else {
            if !quietly { message = String(localized: "Instale a permissão primeiro.") }
            return
        }
        armed = true
        quietSince = nil
        if !quietly { message = String(localized: "Pode fechar a tampa.") }
        tick()
    }

    func disarm() {
        release()
        armed = false
        quietSince = nil
        notifiedEarly = false
    }

    func shutdown() {
        LogoLight.shared.stop()
        // Atualização em andamento: sai segurando o Mac; a versão nova assume em segundos. Se ela não abrir,
        // o vigia devolve o repouso (o arquivo `holding` continua e o sinal de vida para).
        if holding, handoffPending() { return }
        if armed || holding || Power.sleepDisabled { disarm() }
    }

    /// Aviso deixado pelo update.command antes de fechar o app: vale por 2 min. O app que sai grava nele desde
    /// quando segurava o Mac (o tempo máximo continua contando); o que abre lê e apaga.
    static let handoffFile = Paths.support.appendingPathComponent("update-handoff")

    private func handoffPending() -> Bool {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: Self.handoffFile.path))?[.modificationDate] as? Date
        else { return false }
        guard Date().timeIntervalSince(m) < 120 else { return false }
        let since = holdingSince ?? Date()
        try? String(Int(since.timeIntervalSince1970)).write(to: Self.handoffFile, atomically: true, encoding: .utf8)
        return true
    }

    private static func takeHandoff() -> Date? {
        defer { try? FileManager.default.removeItem(at: handoffFile) }
        guard let m = (try? FileManager.default.attributesOfItem(atPath: handoffFile.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(m) < 120,
              let text = try? String(contentsOf: handoffFile, encoding: .utf8),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Canário: hook instalado, agente aberto e trabalhando (arquivos de sessão mexendo há menos de 2 min), mas nenhum
    /// sinal do hook há 10 min ou mais. Três vezes seguidas (separadas por 10 min de calma) = o hook parou de chegar.
    private func checkMuteHook(_ a: AgentConfig, hasHook: Bool, running: Bool, sigs: [HookSignal], now: Date) {
        let id = "hook-" + a.id
        guard hasHook, running else { return }
        if let last = sigs.map(\.time).max(), now.timeIntervalSince(last) < 600 {
            muteEpisodes[a.id] = 0
            Canaries.shared.clear(id)
            return
        }
        guard let w = watcher.lastWrite[a.id], now.timeIntervalSince(w) < 120 else { return }
        if muteEpisodeAt[a.id].map({ now.timeIntervalSince($0) > 600 }) ?? true { muteEpisodes[a.id, default: 0] += 1 }
        muteEpisodeAt[a.id] = now
        guard muteEpisodes[a.id, default: 0] >= 3 else { return }
        Canaries.shared.raise(id, .agents, a.id == "codex"
            ? String(localized: "Não estou recebendo os sinais do Codex. Talvez ele precise aprovar o hook de novo: rode /hooks no Codex.")
            : String(localized: "Não estou recebendo os sinais do \(a.name). Uma atualização dele pode ter mudado ou apagado o hook: remova e instale de novo na seção Hooks."))
    }

    /// Agente trabalhando: desliga o repouso (inclusive com a tampa fechada).
    private func hold() {
        guard !holding else { return }
        guard Power.setSleepDisabled(true) else {
            message = String(localized: "Não consegui desativar o repouso.")
            // Com a regra instalada, o sudo passou a pedir senha: uma atualização do macOS pode ter mexido nela.
            if helperInstalled, Canaries.shared.issues["sudo"] == nil {
                let text = String(localized: "A permissão de administrador parou de funcionar e o Mac pode dormir com a tampa fechada. Reinstale a permissão no assistente (aba Sistema).")
                Canaries.shared.raise("sudo", .system, text)
                Notifier.shared.post(text, force: true)
            }
            return
        }
        Canaries.shared.clear("sudo")
        Canaries.shared.clear("external-sleep")   // aviso da vez anterior: fica até começar outro trabalho
        holding = true
        holdingSince = Date()
        Watchdog.setHolding(true)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "LlMBO aguardando agentes")
    }

    /// O LlMBO é quem manda enquanto segura: se outro app religou o repouso (o AlDente tem uma função que mexe no
    /// mesmo `disablesleep`), desliga de novo. Sem briga: depois de 3 vezes em 10 min, desiste e avisa.
    private func guardSleepDisabled(_ now: Date) {
        switch sleepGuard.check(sleepDisabled: Power.sleepDisabled, now: now) {
        case .ok: break
        case .restore:
            let ok = Power.setSleepDisabled(true)
            AppLog.write("repouso religado por fora durante o trabalho; \(ok ? "desligado de novo" : "falhou ao desligar de novo")")
            let time = now.formatted(date: .omitted, time: .shortened)
            Canaries.shared.raise("external-sleep", .system,
                String(localized: "Outro app religou o repouso enquanto um agente trabalhava (o AlDente, por exemplo, tem uma função que mexe nisso). Desliguei de novo às \(time)."))
        case .giveUp:
            AppLog.write("repouso religado por fora \(Power.SleepGuard.maxRestores) vezes em 10 min; parei de insistir")
            let text = String(localized: "Outro app religou o repouso várias vezes enquanto um agente trabalhava. Parei de desligar de novo para não brigar com ele, e o Mac pode dormir. Confira o AlDente ou outro app que controle o repouso.")
            Canaries.shared.raise("external-sleep", .system, text)
            Notifier.shared.post(text, force: true)
        }
    }

    /// Devolve o repouso normal.
    private func release() {
        sleepGuard = Power.SleepGuard()
        if holding || Power.sleepDisabled { Power.setSleepDisabled(false) }
        Watchdog.setHolding(false)
        holding = false
        holdingSince = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    func installHelper() {
        Power.installHelper()
        helperInstalled = Power.helperInstalled
        message = helperInstalled ? String(localized: "Permissão instalada.") : String(localized: "A permissão não foi instalada.")
        if helperInstalled { Watchdog.install() }
        watchdogStatus = Watchdog.status
        canScheduleWake = helperInstalled && Power.canScheduleWake
        LogoLight.shared.refreshPermission()
        if helperInstalled, !armed { arm(quietly: true) }
    }

    func uninstallHelper() {
        disarm()
        Watchdog.remove()
        watchdogStatus = Watchdog.status
        Power.uninstallHelper()
        helperInstalled = Power.helperInstalled
        message = helperInstalled ? nil : String(localized: "Permissão removida.")
    }

    var watcherDiagnostics: [String] { watcher.diagnosticLines }

    private func refreshHooks() {
        var m: [String: Hooks.State] = [:]
        for a in agents { m[a.id] = Hooks.state(a.id) }
        hookStates = m
    }

    // MARK: Lista de agentes

    /// Cria ou atualiza (mesmo id) um agente e grava no agents.json.
    /// Agente novo que tem hook e está instalado no Mac já sai com o hook dele ligado.
    func saveAgent(_ a: AgentConfig) {
        var list = agents
        let isNew = !list.contains { $0.id == a.id }
        if let i = list.firstIndex(where: { $0.id == a.id }) { list[i] = a } else { list.append(a) }
        commit(list)
        if isNew { link(a) }
    }

    /// Agente novo que está no Mac já sai conectado: hook e servidor MCP, o que ele aceitar.
    private func link(_ a: AgentConfig) {
        guard a.isPresentOnMac, let c = connections.first(where: { $0.agentIDs.contains(a.id) }), !isConnected(c) else { return }
        let errors = install(c)
        agentMessage = errors.isEmpty ? String(localized: "\(a.name) adicionado e conectado.")
                                      : String(localized: "\(a.name) adicionado, mas a conexão falhou: \(errors.joined(separator: "; "))")
    }

    // MARK: Conexão com os agentes (hook + MCP)

    /// Uma linha por arquivo de configuração: agentes que dividem hook e MCP (os três Antigravity, o Copilot CLI e o
    /// do VS Code) aparecem juntos. Inclui servidores MCP já instalados de agentes fora da lista, para poder tirar.
    var connections: [AgentConnection] {
        var out: [AgentConnection] = []
        var seen = Set<String>()
        for a in agents {
            let key = Hooks.familyKey(a.id)
            let target = MCPInstall.targets.first { $0.agentIDs.contains(a.id) }
            let hook = Hooks.supported.contains(a.id) ? a.id : nil
            guard hook != nil || target != nil else { continue }
            if let i = out.firstIndex(where: { $0.id == key }) {
                out[i].agentIDs.insert(a.id)
                if out[i].hookAgent == nil { out[i].hookAgent = hook }
                continue
            }
            seen.insert(key)
            out.append(AgentConnection(id: key, name: Hooks.displayName(a.id, fallback: a.name), hookAgent: hook, mcp: target,
                                       agentIDs: [a.id]))
        }
        for t in MCPInstall.targets where mcpInstalled.contains(t.id) && !out.contains(where: { $0.mcp?.id == t.id }) && !seen.contains(t.id) {
            out.append(AgentConnection(id: t.id, name: t.name, hookAgent: nil, mcp: t, agentIDs: t.agentIDs))
        }
        return out
    }

    func hookState(_ c: AgentConnection) -> Hooks.State {
        guard let h = c.hookAgent else { return .unsupported }
        return hookStates[h] ?? Hooks.state(h)
    }

    /// O Claude Code instala o MCP pelo próprio CLI: sem ele, a parte do MCP fica de fora.
    func mcpAvailable(_ c: AgentConnection) -> Bool {
        guard let t = c.mcp else { return false }
        return t.id != "claude" || MCPInstall.claudeCLI != nil || mcpInstalled.contains(t.id)
    }

    func mcpOn(_ c: AgentConnection) -> Bool { c.mcp.map { mcpInstalled.contains($0.id) } ?? false }

    /// Tudo o que o agente aceita está instalado (hook em conflito não conta).
    func isConnected(_ c: AgentConnection) -> Bool {
        let hook = hookState(c)
        let hookOK = hook == .installed || hook == .unsupported || { if case .conflict = hook { return true }; return false }()
        return hookOK && (!mcpAvailable(c) || mcpOn(c))
    }

    func anyPieceOn(_ c: AgentConnection) -> Bool { hookState(c) == .installed || mcpOn(c) }

    /// Instala o que falta; devolve os erros.
    @discardableResult
    private func install(_ c: AgentConnection) -> [String] {
        var errors: [String] = []
        if let h = c.hookAgent, hookState(c) == .notInstalled, case .failure(let e) = Hooks.install(h) {
            errors.append(String(localized: "hook: \(e.localizedDescription)"))
        }
        if let t = c.mcp, mcpAvailable(c), !mcpInstalled.contains(t.id) {
            do { try MCPInstall.install(t) } catch { errors.append("MCP: \(error.localizedDescription)") }
        }
        refreshHooks()
        mcpInstalled = Set(MCPInstall.targets.filter(MCPInstall.isInstalled).map(\.id))
        return errors
    }

    func connect(_ c: AgentConnection) { connect([c]) }

    func connect(_ list: [AgentConnection]) {
        let errors = list.flatMap { c in install(c).map { "\(c.name): \($0)" } }
        agentMessage = errors.isEmpty ? String(localized: "Conectado. Vale para as próximas sessões do agente.")
                                      : errors.joined(separator: "\n")
    }

    func disconnect(_ c: AgentConnection) {
        var errors: [String] = []
        if let h = c.hookAgent, hookState(c) == .installed, case .failure(let e) = Hooks.uninstall(h) {
            errors.append(String(localized: "hook: \(e.localizedDescription)"))
        }
        if let t = c.mcp, mcpInstalled.contains(t.id) {
            do { try MCPInstall.remove(t) } catch { errors.append("MCP: \(error.localizedDescription)") }
        }
        refreshHooks()
        mcpInstalled = Set(MCPInstall.targets.filter(MCPInstall.isInstalled).map(\.id))
        agentMessage = errors.isEmpty ? String(localized: "Desconectado.") : "\(c.name): " + errors.joined(separator: "; ")
    }

    /// Pré-cadastrados que ainda não estão na lista (o menu "Adicionar agente").
    var availableCatalog: [AgentConfig] {
        AgentConfig.catalog.filter { c in !agents.contains { $0.id == c.id } }
    }

    /// Tira da lista e desconecta (hook e MCP, só as entradas do LlMBO).
    func removeAgent(_ id: String) {
        // Agentes que dividem o mesmo arquivo (os três Antigravity; Copilot CLI e do VS Code): só desliga
        // quando o último sai da lista.
        let remaining = Set(agents.map(\.id)).subtracting([id])
        if Hooks.supported.contains(id), remaining.isDisjoint(with: Hooks.sharingFile(id)), Hooks.state(id) == .installed {
            Hooks.uninstall(id)
        }
        if let t = MCPInstall.targets.first(where: { $0.agentIDs.contains(id) }),
           remaining.isDisjoint(with: t.agentIDs), mcpInstalled.contains(t.id) {
            try? MCPInstall.remove(t)
            mcpInstalled = Set(MCPInstall.targets.filter(MCPInstall.isInstalled).map(\.id))
        }
        commit(agents.filter { $0.id != id })
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard var a = agents.first(where: { $0.id == id }) else { return }
        a.enabled = on
        saveAgent(a)
    }

    private func commit(_ list: [AgentConfig]) {
        AgentStore.save(list)
        agents = list
        refreshHooks()
        tick()
    }

    /// Para o formulário: quantos processos a regra encontra agora e quanta CPU somam.
    func probe(_ a: AgentConfig) -> (processes: Int, cpu: Double) {
        let found = processSnapshot().filter { a.matches($0) }
        return (found.count, found.map(\.cpu).reduce(0, +))
    }

    func openConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.agentsFile])
    }

    /// O macOS pode exigir que o usuário aprove o item de login nos Ajustes do Sistema.
    var loginItemNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            message = String(localized: "Abrir ao iniciar: \(error.localizedDescription)")
        }
    }

    // MARK: Ciclo

    private func tick() {
        let now = Date()
        defer { WidgetFeed.update(self, now: now) }
        Watchdog.beat()
        let wd = Watchdog.status
        if wd != watchdogStatus { watchdogStatus = wd }
        // O vigia religou o repouso (o app ficou travado): esquece o hold; se ainda houver trabalho, segura de novo.
        if holding, !Watchdog.holdingMarked {
            holding = false
            holdingSince = nil
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        }
        if holding { guardSleepDisabled(now) }
        // Tampa aberta de novo (inclusive ao acordar): religa se estiver desligado.
        let lidClosed = Power.lidClosed
        let lidOpened = lidWasClosed && !lidClosed
        lidWasClosed = lidClosed
        if !lidClosed { darkenedAt = nil }
        if lidOpened, armOnLidOpen, !armed, helperInstalled {
            message = String(localized: "Religado ao abrir a tampa.")
            arm(quietly: true)   // já roda o tick
            return
        }
        if let data = try? Data(contentsOf: Paths.agentsFile),
           let reloaded = try? JSONDecoder().decode([AgentConfig].self, from: data) {
            if reloaded != agents { agents = reloaded }
        }
        let monitored = agents.filter(\.isEnabled)
        watcher.update(monitored)

        let procs = processSnapshot()
        // Só lê a GPU quando algum agente a usa (IA local, por padrão).
        let gpuByPid = monitored.contains { $0.gpuLimit != nil } ? gpuSampler.sample() : [:]
        var children: [Int32: [Int32]] = [:]
        var byPid: [Int32: ProcInfo] = [:]
        for p in procs {
            children[p.ppid, default: []].append(p.pid)
            byPid[p.pid] = p
        }
        let signals = readSignals(now: now)
        let grace = TimeInterval(graceMinutes * 60)

        var list: [AgentStatus] = []
        for a in monitored {
            // CPU do agente + todos os processos filhos (ferramentas, builds, testes…)
            var stack = procs.filter { a.matches($0) }.map(\.pid)
            let running = !stack.isEmpty
            // Sinal 1b — tarefas em segundo plano do Claude Code: o Stop sai com elas ainda rodando.
            let backgroundTasks = a.id == "claude"
                ? ClaudeBackground.count(agentPids: stack, children: children, byPid: byPid,
                                         window: TimeInterval(backgroundTaskMinutes * 60), now: now)
                : 0
            var seen = Set<Int32>()
            while let pid = stack.popLast() {
                if seen.insert(pid).inserted { stack += children[pid] ?? [] }
            }
            let cpu = seen.compactMap { byPid[$0]?.cpu }.reduce(0, +)
            cpuStreak[a.id] = cpu >= a.cpuThreshold ? (cpuStreak[a.id] ?? 0) + 1 : 0
            if (cpuStreak[a.id] ?? 0) >= sustainedSamples { lastCPU[a.id] = now }
            let gpu = seen.compactMap { gpuByPid[$0] }.reduce(0, +)
            if let limit = a.gpuLimit {
                gpuStreak[a.id] = gpu >= limit ? (gpuStreak[a.id] ?? 0) + 1 : 0
                if (gpuStreak[a.id] ?? 0) >= sustainedSamples { lastGPU[a.id] = now }
            }

            // Sinal 1 — hooks: cada sessão guarda seu último estado. As ferramentas renovam o "busy",
            // então ele vale enquanto o processo existir (até 3 h) ou, sem processo, por 10 min.
            let sigs = signals.filter { $0.agent == a.id }
            if !sigs.isEmpty { hookSeen.formUnion(Hooks.sharedWith(a.id)) }
            let lastBusy = sigs.filter { s in
                guard s.busy else { return false }
                let age = now.timeIntervalSince(s.time)
                return running ? age < 3 * 3600 : age < 600
            }.map(\.time).max()
            // Pedindo aprovação: conta como trabalhando por approvalWaitMinutes (0 = não espera), para dar tempo de
            // aprovar à distância (ex.: controle remoto do Claude Code pelo celular). Depois disso vale como parado.
            let approvalWindow = TimeInterval(approvalWaitMinutes * 60)
            let waitingAt = sigs.filter { $0.waiting && now.timeIntervalSince($0.time) < approvalWindow }.map(\.time).max()
            let lastIdle = sigs.filter { !$0.busy && !($0.waiting && now.timeIntervalSince($0.time) < approvalWindow) }
                .map(\.time).max()

            // Limite de uso (Claude Code / Antigravity): parado esperando o reset, que vem da barra de status (aba Uso).
            let quotaAt = sigs.filter(\.quota).map(\.time).max()
            // App, IDE e CLI do Antigravity dividem a mesma cota (lida em byAgent["antigravity"]).
            let usageID = a.id.hasPrefix("antigravity") ? "antigravity" : a.id
            let quotaReset = quotaAt.flatMap { q in (UsageStore.shared.byAgent[usageID] ?? (a.id == "claude" ? UsageStore.shared.claude : nil))?.resetAfterLimit(hitAt: q) }
            let quotaHold = quotaAt.map { Self.quotaHolds(mode: quotaMode(for: a.id), hitAt: $0, reset: quotaReset, now: now) } ?? false
            if let q = quotaAt, loggedQuota[a.id] != q, now.timeIntervalSince(q) < 600 {
                loggedQuota[a.id] = q
                QuotaLog.write("\(a.id) reação modo=\(quotaMode(for: a.id).logName) reset=\(quotaReset.map(QuotaLog.time) ?? "desconhecido") segura=\(quotaHold ? "sim" : "não")")
            }

            // Um "idle" do hook encerra a espera na hora, desde que seja mais novo que a atividade
            // (com folga: o agente ainda grava a última mensagem logo depois do Stop).
            func endedByHook(_ t: Date) -> Bool { lastIdle.map { $0 > t.addingTimeInterval(-15) } ?? false }

            // Sinal 2 — arquivos de sessão escritos há pouco (pega o agente esperando o modelo, com CPU parada).
            // Pasta dividida com outro agente (app e IDE do Antigravity) só conta para quem estiver aberto.
            let sharesFolder = monitored.contains { o in
                o.id != a.id && !Set(o.expandedActivityPaths).isDisjoint(with: a.expandedActivityPaths)
            }
            var fileAt: Date?
            if let t = watcher.lastWrite[a.id], now.timeIntervalSince(t) < grace, !endedByHook(t),
               running || !sharesFolder { fileAt = t }

            // Sinal 3 — CPU do processo + filhos.
            var cpuAt: Date?
            if let t = lastCPU[a.id], now.timeIntervalSince(t) < grace, !endedByHook(t) { cpuAt = t }
            // Sinal 3b — GPU (IA local). Vale mesmo com "Priorizar hooks" para quem não aceita hook.
            var gpuAt: Date?
            if a.gpuLimit != nil, let t = lastGPU[a.id], now.timeIntervalSince(t) < grace, !endedByHook(t) { gpuAt = t }

            let hookBusy = lastBusy != nil
            // Hook completo (avisa começo e fim) instalado: ele é a fonte da verdade. CPU e arquivos
            // davam falso positivo (IDE indexando, Electron redesenhando…), então ficam de fora.
            // Só depois de visto funcionando: hook instalado mas nunca disparado (não aprovado, sessão antiga…)
            // deixaria o agente invisível.
            let hasHook = hookStates[a.id] == .installed
            // O Copilot do VS Code só passa a "só hook" depois de visto: os hooks do VS Code estão em prévia e,
            // se ele chamar um executável "copilot" por baixo, o sinal vai para o Copilot CLI.
            let hookCapable = Hooks.supported.contains(a.id) && (a.id != "copilot-vscode" || hookSeen.contains(a.id))
            let hookOnly = (strictHooks && hookCapable)
                || (Hooks.fullLifecycle.contains(a.id) && hasHook && hookSeen.contains(a.id))
            // Hierarquia: hook > arquivos de sessão > CPU.
            // "Priorizar hooks" (strictHooks): quem aceita hook só conta pelo hook; quem não aceita (extensões de
            // IDE, IA local, personalizados) conta pelos arquivos de sessão; a CPU nunca conta.
            if hookOnly { fileAt = nil; cpuAt = nil; gpuAt = nil }
            if strictHooks || !a.countsCPU { cpuAt = nil }
            // Um "busy" mais novo que o pedido de aprovação (de outra sessão) prevalece no rótulo.
            let waitingApproval = waitingAt.map { w in lastBusy.map { $0 < w } ?? true } ?? false
            let active = hookBusy || waitingApproval || quotaHold || backgroundTasks > 0
                || fileAt != nil || cpuAt != nil || gpuAt != nil

            var reason: String?
            if waitingApproval { reason = String(localized: "aguardando aprovação") }
            else if quotaHold && !hookBusy { reason = String(localized: "limite de uso") }
            else if hookBusy { reason = String(localized: "hook") }
            else if backgroundTasks > 0 { reason = String(localized: "tarefa em segundo plano") }
            else if let t = fileAt { reason = String(localized: "arquivos \(ago(t, now))") }
            else if gpuAt != nil && (cpuAt == nil || gpu >= (a.gpuLimit ?? 0)) { reason = String(localized: "GPU \(Int(gpu))%") }
            else if cpuAt != nil { reason = cpu >= a.cpuThreshold ? String(localized: "CPU \(Int(cpu))%") : String(localized: "CPU \(ago(cpuAt!, now))") }

            var status = AgentStatus(id: a.id, name: a.name, running: running, active: active, cpu: cpu,
                                     viaHook: hookBusy, reason: reason, hook: hookStates[a.id] ?? .unsupported)
            // Só quando o hook nunca disparou: sinais com mais de 24 h são apagados, e um agente parado há um dia
            // (hook já visto funcionando) não está "aguardando o hook".
            status.waitingHook = hookOnly && hasHook && running && sigs.isEmpty && !hookSeen.contains(a.id)
            // App, IDE e CLI do Antigravity dividem hook e pasta: sinal de qualquer um deles vale.
            checkMuteHook(a, hasHook: hasHook, running: running,
                          sigs: signals.filter { Hooks.sharedWith(a.id).contains($0.agent) }, now: now)
            status.waitingApproval = waitingApproval
            if let q = quotaAt, !hookBusy {
                status.waitingQuota = quotaReset.map { $0 > now } ?? (now.timeIntervalSince(q) < 5 * 3600)
                status.quotaReset = quotaReset
            }
            // Com "Priorizar hooks", aberto e sem nenhum sinal possível: aceita hook mas ele não está instalado,
            // ou não aceita hook e não tem arquivos de sessão.
            status.ignoredNoHook = strictHooks && running && sigs.isEmpty
                && ((hookCapable && !hasHook) || (!hookCapable && a.expandedActivityPaths.isEmpty))
            list.append(status)
        }
        // Em ordem alfabética: popover, aba Agentes e hooks seguem esta ordem.
        statuses = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        LogoLight.shared.agentsUpdate(statuses)   // modo Agentes da luz da maçã
        // Só com a opção ligada e o Codex na lista (ativado); senão não faz nada.
        let codexOn = codexAutoResume && agents.contains { $0.id == "codex" && $0.isEnabled }
        UsageStore.shared.readAntigravityQuota = antigravityQuota && antigravityListed
        UsageStore.shared.readClaudeUsage = claudeUsageCLI && claudeListed
        // Travas de segurança também valem para o que acontece no limite de uso: com o LlMBO desligado (inclusive
        // por uma trava), bateria no mínimo ou o Mac quente, não retoma o Codex nem agenda despertar.
        let blocked = !armed || travaBlocks
        let codexHold = codexResume.tick(now: now, enabled: codexOn, blocked: blocked,
                                         stops: UsageStore.shared.codexStops, usage: UsageStore.shared.codex)
        // Antigravity: paradas no limite (sinal "quota" da sessão), e a cota lida pelo hub diz quando volta.
        let agStops = signals.filter { $0.quota && $0.agent.hasPrefix("antigravity") && !$0.session.isEmpty }
            .map { AntigravityResume.Stop(agent: $0.agent, session: $0.session, cwd: $0.cwd, at: $0.time) }
        let agGroups = UsageStore.shared.byAgent["antigravity"]?.groups
        let agHold = antigravityResume.tick(now: now, enabled: antigravityAutoResume && antigravityListed, blocked: blocked,
                                            stops: agStops, groups: agGroups?.isEmpty == false ? agGroups : nil)
        updateWake(list, now: now, blocked: blocked)
        let liveHolds = Holds.read()
        if liveHolds != holds { holds = liveHolds }

        // Assumiu o Mac de uma atualização mas ficou desligado (sem permissão, por exemplo): devolve o repouso.
        guard armed else { if holding { release() }; return }

        let anyActive = list.contains(where: \.active) || !holds.isEmpty || codexHold || agHold
        if anyActive { quietSince = nil; notifiedEarly = false; hold() }
        // Sem agente trabalhando, o repouso é o normal do Mac: nada a vigiar.
        guard holding, let holdingSince else { return }

        // Tampa fechada sem monitor externo: a tela interna pode ficar acesa por trás da tampa. Apaga na hora e
        // confere de novo a cada minuto (ou antes, se ela voltar a acender).
        if darkenLidClosed, lidClosed, !Power.externalDisplayOnline,
           darkenedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true || Power.builtinDisplayAwake {
            Power.displaySleepNow()
            darkenedAt = now
        }

        if let b = Power.battery, !b.onAC, b.percent <= minBattery {
            finish(String(localized: "Bateria em \(b.percent)%"))
            return
        }
        // Tempo máximo: o limite é o da fonte de energia de agora (Mac sem bateria conta como tomada).
        let onAC = Power.battery?.onAC ?? true
        if let h = Self.limitReached(elapsed: now.timeIntervalSince(holdingSince), onAC: onAC,
                                     acHours: maxHoursAC, batteryHours: maxHours) {
            finish(onAC ? String(localized: "Limite de \(h) h na tomada atingido")
                        : String(localized: "Limite de \(h) h na bateria atingido"))
            return
        }

        // Proteção de temperatura: quente demais de tampa fechada (mochila, cobertor…) → dorme na hora.
        if Self.tooHot(ProcessInfo.processInfo.thermalState, limit: thermalLimit) {
            if Power.lidClosed {
                finish(String(localized: "Mac quente demais com a tampa fechada"))
                return
            }
            if !hotWarned {
                message = String(localized: "O Mac está quente. Com a tampa fechada, o LlMBO o põe para dormir.")
                Notifier.shared.post(message!)
                hotWarned = true
            }
        } else {
            hotWarned = false
        }

        if !anyActive {
            if quietSince == nil { quietSince = now }
            // Folga para o timer: com o tick a cada 5 s e a espera de 5 s, "4,99 s" perdia uma volta inteira.
            let slack: TimeInterval = 0.5
            let finishAt = confirmQuiet + TimeInterval(sleepDelaySeconds)
            // Todos terminaram (e passou o atraso escolhido): devolve o repouso ao macOS e continua ligado.
            // Se um agente voltar a trabalhar nesse meio-tempo, quietSince zera e a espera recomeça.
            if let q = quietSince, now.timeIntervalSince(q) >= finishAt - slack {
                finish(String(localized: "Agentes terminaram"), staysOn: true)
            } else if let q = quietSince, holding, !notifiedEarly {
                // Avisa na hora que terminaram (pedido do usuário: o mais instantâneo possível); os 5 s de quietude
                // e o atraso valem só para devolver o repouso, que depois volta sem outro aviso.
                notifiedEarly = true
                lastFinishedAt = now
                LogoLight.shared.agentsFinished()
                let f = DateFormatter()
                f.timeStyle = .short
                let back = q.addingTimeInterval(confirmQuiet + TimeInterval(sleepDelaySeconds))
                var body = String(localized: "\(String(localized: "Agentes terminaram")) às \(f.string(from: now)).") + " "
                    + String(localized: "O repouso normal volta às \(f.string(from: back)).")
                if let w = scheduledWake, w > now {
                    body += " " + String(localized: "O Mac acorda às \(f.string(from: w)) para o Claude Code continuar.")
                }
                Notifier.shared.post(body)
            }
            // Próxima conferência no instante exato do fim do atraso (o timer de 5 s cairia depois).
            if holding, let q = quietSince {
                scheduleQuietCheck(q, after: finishAt, now: now)
            }
        } else {
            quietCheck?.cancel()
            quietCheck = nil
        }
    }

    /// Segura o Mac acordado por um agente parado no limite de uso? Depende de "Quando bater no limite".
    /// O Claude Code só continua sozinho se o reset for em até 24 h; dormindo mais de ~30 min na hora do reset,
    /// ele espera um Enter — por isso o padrão acorda o Mac pouco antes e segura até ele continuar.
    nonisolated static func quotaHolds(mode: QuotaMode, hitAt: Date, reset: Date?, now: Date) -> Bool {
        if let r = reset, r.timeIntervalSince(now) > 24 * 3600 { return false }
        switch mode {
        case .ignore: return false
        case .stayAwake:
            if let r = reset { return now < r.addingTimeInterval(600) }
            return now.timeIntervalSince(hitAt) < 5 * 3600
        case .wake, .resume:
            guard let r = reset else { return false }
            return now >= r.addingTimeInterval(-300) && now < r.addingTimeInterval(600)
        }
    }

    /// LLMBO_TEST_QUOTA=1: confere qual janela define o reset e quando cada modo segura o Mac. Grava quota-test.log.
    nonisolated static func quotaSelfTest() {
        let now = Date()
        let hit = now.addingTimeInterval(-3600)
        func w(_ pct: Double, _ min: Double) -> LimitWindow { LimitWindow(usedPercent: pct, resetsAt: now.addingTimeInterval(min * 60)) }
        var out: [String] = []
        func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "ok " : "ERRO") \(name)") }
        let fiveFull = AgentUsage(fiveHour: w(100, 30), weekly: w(60, 3000))
        check("5h cheia → reset da 5h", fiveFull.resetAfterLimit(hitAt: hit) == fiveFull.fiveHour!.resetsAt)
        let weekFull = AgentUsage(fiveHour: w(40, 30), weekly: w(100, 3000))
        check("semana cheia → reset da semana", weekFull.resetAfterLimit(hitAt: hit) == weekFull.weekly!.resetsAt)
        let noneFull = AgentUsage(fiveHour: w(80, 30), weekly: w(50, 3000))
        check("nenhuma cheia → reset da 5h", noneFull.resetAfterLimit(hitAt: hit) == noneFull.fiveHour!.resetsAt)
        check("sem limites → nil", AgentUsage().resetAfterLimit(hitAt: hit) == nil)
        let r30 = now.addingTimeInterval(30 * 60), r3 = now.addingTimeInterval(3 * 60)
        let past5 = now.addingTimeInterval(-5 * 60), past15 = now.addingTimeInterval(-15 * 60)
        check("acordar: 30 min antes não segura", !quotaHolds(mode: .wake, hitAt: hit, reset: r30, now: now))
        check("acordar: 3 min antes segura", quotaHolds(mode: .wake, hitAt: hit, reset: r3, now: now))
        check("acordar: 5 min depois segura", quotaHolds(mode: .wake, hitAt: hit, reset: past5, now: now))
        check("acordar: 15 min depois solta", !quotaHolds(mode: .wake, hitAt: hit, reset: past15, now: now))
        check("acordar: sem reset não segura", !quotaHolds(mode: .wake, hitAt: hit, reset: nil, now: now))
        check("acordado: 30 min antes segura", quotaHolds(mode: .stayAwake, hitAt: hit, reset: r30, now: now))
        check("acordado: sem reset, 1 h depois do limite segura", quotaHolds(mode: .stayAwake, hitAt: hit, reset: nil, now: now))
        check("acordado: sem reset, 6 h depois solta", !quotaHolds(mode: .stayAwake, hitAt: now.addingTimeInterval(-6 * 3600), reset: nil, now: now))
        check("acordado: reset em 2 dias não segura", !quotaHolds(mode: .stayAwake, hitAt: hit, reset: now.addingTimeInterval(2 * 86400), now: now))
        check("não esperar: nunca segura", !quotaHolds(mode: .ignore, hitAt: hit, reset: r3, now: now))
        check("retomar: 3 min antes segura, como acordar", quotaHolds(mode: .resume, hitAt: hit, reset: r3, now: now))
        check("retomar: fora da lista do Claude", !QuotaMode.continuesAlone.contains(.resume) && QuotaMode.resumable.first == .resume)
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("quota-test.log"), atomically: true, encoding: .utf8)
    }

    /// Agenda (ou cancela) o despertar 2 min antes do reset mais próximo de um agente parado no limite.
    private func updateWake(_ list: [AgentStatus], now: Date, blocked: Bool) {
        var candidates: [Date] = []
        if !blocked, canScheduleWake {
            candidates += list.filter { $0.waitingQuota && [.wake, .resume].contains(quotaMode(for: $0.id)) }.compactMap(\.quotaReset)
                .filter { $0.timeIntervalSince(now) > 180 && $0.timeIntervalSince(now) < 24 * 3600 }
                .map { $0.addingTimeInterval(-120) }
            candidates += codexResume.wakeTimes(now: now)   // vazio com a opção desligada
            candidates += antigravityResume.wakeTimes(now: now)
        }
        let target = candidates.min()
        guard target != scheduledWake else { return }
        if let old = scheduledWake, old > now {
            Power.cancelWake(old)
            QuotaLog.write("despertar cancelado (era \(QuotaLog.time(old)))")
        }
        scheduledWake = nil
        if let t = target {
            let ok = Power.scheduleWake(t)
            if ok { scheduledWake = t }
            QuotaLog.write(ok ? "despertar agendado para \(QuotaLog.time(t))" : "despertar para \(QuotaLog.time(t)) falhou")
        }
    }

    /// Instala ou remove o servidor MCP do LlMBO nos destinos dados (MCPInstall.targets).
    func setMCP(_ ids: [String], _ on: Bool) {
        var failed: [String] = []
        for t in MCPInstall.targets where ids.contains(t.id) {
            do {
                if on { try MCPInstall.install(t) } else { try MCPInstall.remove(t) }
            } catch {
                failed.append("\(t.name): \(error.localizedDescription)")
            }
        }
        if failed.isEmpty {
            agentMessage = on ? String(localized: "Servidor MCP instalado. Vale para as próximas sessões do agente.")
                              : String(localized: "Servidor MCP removido.")
        } else {
            agentMessage = String(localized: "MCP: \(failed.joined(separator: "; "))")
        }
        mcpInstalled = Set(MCPInstall.targets.filter(MCPInstall.isInstalled).map(\.id))
    }


    /// "Ler limites de uso" do Claude Code (aba Uso): uma opção só para as duas leituras — o `/usage` (funciona também
    /// pelo app Claude, a cada 5 min) e a barra de status (na hora, só no Claude Code de terminal).
    var claudeLimits: Bool { claudeUsageCLI || claudeStatusLine }
    func setClaudeLimits(_ on: Bool) {
        claudeUsageCLI = on
        if claudeStatusLine != on { setClaudeStatusLine(on) }
    }

    /// Liga ou desliga a barra de status do Claude Code que lê os limites de uso.
    func setClaudeStatusLine(_ on: Bool) {
        do {
            if on { try Hooks.installStatusLine() } else { try Hooks.removeStatusLine() }
        } catch {
            message = String(localized: "Barra de status: \(error.localizedDescription)")
        }
        claudeStatusLine = Hooks.statusLineInstalled
        UsageStore.shared.refresh()
    }

    /// Limite (em horas) estourado para a fonte de energia atual, ou nil. Na tomada, 0 = sem limite.
    /// Bateria no mínimo (fora da tomada) ou o Mac no nível de temperatura escolhido: travas que valem mesmo sem
    /// o repouso estar seguro (o tempo máximo só conta enquanto ele está).
    private var travaBlocks: Bool {
        if let b = Power.battery, !b.onAC, b.percent <= minBattery { return true }
        return Self.tooHot(ProcessInfo.processInfo.thermalState, limit: thermalLimit)
    }

    nonisolated static func limitReached(elapsed: TimeInterval, onAC: Bool, acHours: Int, batteryHours: Int) -> Int? {
        let hours = onAC ? acHours : batteryHours
        guard hours > 0, elapsed > TimeInterval(hours * 3600) else { return nil }
        return hours
    }

    /// O nível atual atingiu o escolhido? `.off` nunca dispara.
    nonisolated static func tooHot(_ state: ProcessInfo.ThermalState, limit: ThermalLimit) -> Bool {
        guard let level = limit.state else { return false }
        return state.rawValue >= level.rawValue
    }

    private func ago(_ t: Date, _ now: Date) -> String {
        let s = Int(now.timeIntervalSince(t))
        return s < 60 ? String(localized: "há \(s) s") : String(localized: "há \(s / 60) min")
    }

    /// Devolve o repouso e avisa. `staysOn`: os agentes terminaram e o modo automático continua ligado;
    /// senão (bateria, tempo máximo, temperatura) o modo desliga.
    private func finish(_ reason: String, staysOn: Bool = false) {
        if staysOn { release(); quietSince = nil } else { disarm() }
        let f = DateFormatter()
        f.timeStyle = .short
        message = String(localized: "\(reason) às \(f.string(from: Date())).")
        let lidClosed = Power.lidClosed
        // Agentes terminaram: só devolve o repouso e deixa o macOS seguir do jeito dele. Se com a tampa
        // fechada ele não dormir sozinho em 1 min, dorme como faria ao fechar a tampa (não ficar ligado na mochila).
        if staysOn {
            // Já avisou quando os agentes terminaram: devolve o repouso em silêncio.
            if notifiedEarly {
                notifiedEarly = false
                if lidClosed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                        guard let self, Power.lidClosed, !self.holding else { return }
                        Power.sleepNow()
                    }
                }
                return
            }
            var body = message! + " " + String(localized: "O repouso normal voltou.")
            if let w = scheduledWake, w > Date() {
                body += " " + String(localized: "O Mac acorda às \(f.string(from: w)) para o Claude Code continuar.")
            }
            Notifier.shared.post(body)
            if lidClosed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    guard let self, Power.lidClosed, !self.holding else { return }
                    Power.sleepNow()
                }
            }
            return
        }
        let body = message! + " " + (lidClosed ? String(localized: "O Mac vai dormir agora.")
                                               : String(localized: "O repouso normal voltou."))
        // A notificação é registrada antes de o Mac dormir (fica na Central para quando você voltar);
        // se o macOS demorar, dorme mesmo assim depois de 2 s. Com o som da tampa fechada, espera ele acabar.
        guard lidClosed else { Notifier.shared.post(body); return }
        let sound = Notifier.shared.lidSoundDuration
        var slept = false
        let sleep = { if !slept { slept = true; Power.sleepNow() } }
        Notifier.shared.post(body) { DispatchQueue.main.asyncAfter(deadline: .now() + max(1, sound + 0.3)) { sleep() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, sound + 0.5)) { sleep() }
    }
}

/// Níveis da proteção de temperatura. O macOS não dá a temperatura em graus para apps comuns; dá o nível
/// térmico (ProcessInfo.thermalState), já calibrado para cada modelo de Mac.
enum ThermalLimit: Int, CaseIterable, Identifiable {
    case off = 0, fair = 1, serious = 2, critical = 3

    static let recommended: ThermalLimit = .serious
    var id: Int { rawValue }

    var state: ProcessInfo.ThermalState? {
        switch self {
        case .off: return nil
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }

    var title: String {
        switch self {
        case .off: return String(localized: "Desligada")
        case .fair: return String(localized: "Levemente quente")
        case .serious: return String(localized: "Quente (recomendado)")
        case .critical: return String(localized: "Crítico")
        }
    }
}

/// O que fazer quando o Claude Code bate no limite de uso e fica esperando o reset para continuar sozinho.
/// quota-events.log: o llmbo-signal grava "data hora agente quota" ao estourar o limite, e o app acrescenta como
/// reagiu (modo, reset, se segura, despertar agendado). Só horários e ids, nada da conversa; últimas 50 linhas.
enum QuotaLog {
    private static let queue = DispatchQueue(label: "llmbo.quotalog")
    private static var last = ""   // a mesma linha repetida (despertar que falha a cada tick) não enche o arquivo
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
    }
    static func write(_ text: String) {
        let url = Paths.support.appendingPathComponent("quota-events.log")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(text)"
        queue.async {
            guard text != last else { return }
            last = text
            var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append(line)
            if lines.count > 50 { lines.removeFirst(lines.count - 50) }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Uma linha de "Conexão com os agentes": o hook (avisa começo e fim) e o servidor MCP (o agente pede para segurar o
/// Mac em tarefas que continuam depois da resposta) de um agente, ou de uma família que divide os arquivos.
struct AgentConnection: Identifiable, Equatable {
    let id: String
    let name: String
    var hookAgent: String?
    let mcp: MCPTarget?
    var agentIDs: Set<String>
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.hookAgent == b.hookAgent && a.agentIDs == b.agentIDs }
}

enum QuotaMode: Int, CaseIterable, Identifiable {
    /// Deixa o Mac dormir e o acorda 2 min antes do reset (precisa da barra de status e da permissão nova).
    case wake = 0
    /// Segura o Mac acordado até o reset.
    case stayAwake = 1
    /// Conta como parado: o Mac dorme e o Claude Code espera você.
    case ignore = 2
    /// Só Codex e Antigravity (não continuam sozinhos): acorda no reset e o LlMBO retoma a sessão
    /// (CodexResume / AntigravityResume). Para o Mac, vale como "Acordar no reset".
    case resume = 3

    var id: Int { rawValue }
    /// Nome fixo (sem tradução) para o quota-events.log.
    var logName: String {
        switch self { case .wake: "acordar"; case .stayAwake: "acordado"; case .ignore: "nao-esperar"; case .resume: "retomar" }
    }
    /// Escolhas de quem continua sozinho (Claude Code) e de quem o LlMBO retoma (Codex, Antigravity).
    static let continuesAlone: [QuotaMode] = [.wake, .stayAwake, .ignore]
    static let resumable: [QuotaMode] = [.resume, .wake, .stayAwake, .ignore]

    var title: String {
        switch self {
        case .wake: return String(localized: "Acordar no reset (recomendado)")
        case .stayAwake: return String(localized: "Ficar acordado até o reset")
        case .ignore: return String(localized: "Não esperar")
        case .resume: return String(localized: "Retomar sozinho")
        }
    }
}
