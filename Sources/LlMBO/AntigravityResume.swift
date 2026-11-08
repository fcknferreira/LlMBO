import Foundation

/// "Retomar o Antigravity depois do limite" (opcional, desligado por padrão). O Antigravity não continua sozinho
/// quando a cota volta. Ligado, o LlMBO usa a leitura da cota (AntigravityQuota, pelo hub do app ou da IDE abertos)
/// para saber QUANDO a cota volta e só então age, o que evita o laço de erros 429 de tentar cedo demais:
/// - Conversa do Antigravity CLI: roda em segundo plano, na pasta da conversa,
///     agy -p "<prompt>" --conversation <id> --mode accept-edits --sandbox --print-timeout 3h
///   SÓ se a conversa existir em ~/.gemini/antigravity-cli/conversations/<id>.db: com um id que não conhece, o agy
///   só avisa "not found" e começa uma conversa NOVA com o pedido (visto em 07/11/2026 no agy 1.4.12).
/// - Conversa do app ou da IDE: ficam em outras pastas e com o hub do app usando os arquivos; o LlMBO só avisa que
///   a cota voltou, para você continuar.
/// Contra laço: na hora marcada relê a cota e adia se o grupo ainda estiver cheio (até 3 vezes); bateu no limite de
/// novo até 10 min depois de uma retomada = desiste e avisa; no máximo 2 retomadas por conversa a cada 6 h.
/// Nunca testado com o Antigravity batendo no limite de verdade.
@MainActor
final class AntigravityResume: ObservableObject {
    struct Stop: Equatable {
        let agent: String
        let session: String
        let cwd: String?
        let at: Date
        var key: String { "\(session)@\(Int(at.timeIntervalSince1970))" }
        var isCLI: Bool { agent == "antigravity-cli" }
        var folder: String { cwd.map { ($0 as NSString).lastPathComponent } ?? session.prefix(8).description }
    }
    struct Pending: Equatable {
        let stop: Stop
        var at: Date
        var postpones = 0
        /// false = conversa do app ou da IDE: só avisa.
        let launches: Bool
    }

    @Published private(set) var pending: [Pending] = []
    var notify: (String) -> Void = { Notifier.shared.post($0) }
    var handledKey = "antigravityResumeHandled"
    var launchesKey = "antigravityResumeLaunches"
    /// Teste: home falsa (pasta das conversas do CLI) e comando falso.
    var home: URL = Hooks.realHome
    private var command: String {
        if let c = ProcessInfo.processInfo.environment["LLMBO_AGY_CMD"] { return c }
        let local = home.appendingPathComponent(".gemini/bin/agy").path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "agy"
    }
    static let prompt = "The usage limit has reset. Continue the task you were working on before the limit stopped you."
    static let logDir = Paths.support.appendingPathComponent("antigravity-resume")

    private var handled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: handledKey) }
    }
    /// Retomadas por conversa (epoch), para o teto de 2 a cada 6 h e o "bateu de novo logo depois".
    private var launchLog: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: launchesKey) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: launchesKey) }
    }

    func conversationExists(_ session: String) -> Bool {
        FileManager.default.fileExists(atPath: home
            .appendingPathComponent(".gemini/antigravity-cli/conversations/\(session).db").path)
    }

    /// Um passo por tick do Engine. `groups`: cota lida agora (nil = sem leitura). Devolve se o Mac deve ficar
    /// acordado (perto da hora de retomar). `blocked`: LlMBO desligado ou trava valendo; agenda, mas não age.
    func tick(now: Date, enabled: Bool, blocked: Bool = false, stops: [Stop], groups: [LimitGroup]?) -> Bool {
        guard enabled else {
            if !pending.isEmpty { pending = [] }
            return false
        }
        var done = handled
        let live = Set(stops.map(\.key))
        pending.removeAll { !live.contains($0.stop.key) }   // a conversa voltou a trabalhar: esquece

        for stop in stops where !done.contains(stop.key) && !pending.contains(where: { $0.stop.key == stop.key }) {
            done.insert(stop.key)
            let recent = (launchLog[stop.session] ?? []).map { Date(timeIntervalSince1970: $0) }
            if let last = recent.max(), stop.at.timeIntervalSince(last) < 600, stop.at >= last {
                notify(String(localized: "O Antigravity bateu no limite de novo logo depois da retomada em \(stop.folder). O LlMBO parou de tentar; retome você mesmo."))
                continue
            }
            if recent.filter({ now.timeIntervalSince($0) < 6 * 3600 }).count >= 2 {
                notify(String(localized: "O Antigravity já foi retomado duas vezes em \(stop.folder) nas últimas 6 h. O LlMBO parou de tentar; retome você mesmo."))
                continue
            }
            guard let groups, !groups.isEmpty else {
                notify(String(localized: "O Antigravity parou no limite, mas o LlMBO não sabe quando a cota volta: ela é lida pelo app ou pela IDE do Antigravity abertos, com a leitura da cota ligada na aba Uso."))
                continue
            }
            let reset = AntigravityQuota.reset(groups, hitAt: stop.at) ?? now
            if reset.timeIntervalSince(now) > 24 * 3600 {
                notify(String(localized: "O Antigravity parou no limite e a cota só volta em mais de 24 h. Retome você mesmo."))
                continue
            }
            let at = max(reset, now).addingTimeInterval(60)
            if stop.isCLI {
                guard conversationExists(stop.session), let cwd = stop.cwd, isDirectory(cwd) else {
                    notify(String(localized: "O Antigravity CLI parou no limite em \(stop.folder), mas o LlMBO não achou a conversa ou a pasta dela para retomar. Retome você mesmo."))
                    continue
                }
                pending.append(Pending(stop: stop, at: at, launches: true))
                notify(String(localized: "O Antigravity parou no limite em \(stop.folder). O LlMBO vai retomar a conversa às \(UsageFormat.when(at)), quando a cota voltar, em segundo plano."))
            } else {
                // A conversa do app ou da IDE não dá para retomar de fora; avisa quando a cota voltar.
                pending.append(Pending(stop: stop, at: at, launches: false))
            }
        }

        if !blocked {
            var still: [Pending] = []
            for var p in pending {
                guard now >= p.at else { still.append(p); continue }
                // Relê a cota na hora: grupo ainda cheio = adia (até 3 vezes), em vez de bater num 429.
                if let groups, let r = AntigravityQuota.reset(groups, hitAt: now), r > now, p.postpones < 3 {
                    p.at = r.addingTimeInterval(60)
                    p.postpones += 1
                    still.append(p)
                    continue
                }
                if p.launches {
                    launch(p.stop)
                } else {
                    notify(String(localized: "A cota do Antigravity voltou. Continue a conversa no Antigravity."))
                }
            }
            pending = still
        }
        handled = done
        return !blocked && pending.contains { $0.launches && now >= $0.at.addingTimeInterval(-300) }
    }

    /// Despertares (2 min antes de cada retomada do CLI; o aviso das conversas do app não acorda o Mac).
    func wakeTimes(now: Date) -> [Date] {
        pending.filter(\.launches).map { $0.at.addingTimeInterval(-120) }.filter { $0.timeIntervalSince(now) > 60 }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func launch(_ stop: Stop) {
        let folder = stop.folder
        guard conversationExists(stop.session), let cwd = stop.cwd, isDirectory(cwd) else {
            notify(String(localized: "O Antigravity CLI parou no limite em \(folder), mas o LlMBO não achou a conversa ou a pasta dela para retomar. Retome você mesmo."))
            return
        }
        guard run("/bin/zsh", ["-lc", "command -v \"$0\"", command]).status == 0 else {
            notify(String(localized: "Não encontrei o comando agy para retomar a conversa em \(folder). Retome você mesmo."))
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let log = Self.logDir.appendingPathComponent("\(stop.session).log")
        fm.createFile(atPath: log.path, contents: nil)
        let out = try? FileHandle(forWritingTo: log)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // accept-edits: edita arquivos sem perguntar; --sandbox: terminal com restrições. Sem pular permissões.
        proc.arguments = ["-lc", "exec \"$0\" \"$@\"", command,
                          "-p", Self.prompt, "--conversation", stop.session,
                          "--mode", "accept-edits", "--sandbox", "--print-timeout", "3h"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] pr in
            let status = Int(pr.terminationStatus)
            Task { @MainActor in
                try? out?.close()
                self?.notify(status == 0
                    ? String(localized: "A retomada do Antigravity em \(folder) terminou. Abra a conversa para ver o resultado.")
                    : String(localized: "A retomada do Antigravity em \(folder) terminou com erro (código \(status)). O registro está em Application Support/LlMBO/antigravity-resume."))
            }
        }
        do { try proc.run() } catch {
            notify(String(localized: "Não encontrei o comando agy para retomar a conversa em \(folder). Retome você mesmo."))
            return
        }
        var l = launchLog
        l[stop.session, default: []].append(Date().timeIntervalSince1970)
        l = l.mapValues { Array($0.suffix(5)) }
        launchLog = l
        _ = try? Holds.write(name: String(localized: "Antigravity · \(folder) (retomada)"), pid: proc.processIdentifier,
                             minutes: nil, source: "antigravity")
        notify(String(localized: "O Antigravity voltou a trabalhar em \(folder), em segundo plano."))
    }
}

// MARK: - Teste

extension AntigravityResume {
    /// LLMBO_TEST_AGRESUME=1: agy falso (anota argumentos e pasta), home falsa com uma conversa do CLI e cotas
    /// sintéticas. Confere desligado, agendar pelo reset, adiar com a cota cheia, retomar, conversa inexistente,
    /// conversa do app (só aviso), sem leitura da cota e o "bateu de novo logo depois". Grava agresume-test.log.
    static func selfTest() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("llmbo-agresume-test-\(UUID().uuidString)")
        let cwd = dir.appendingPathComponent("meu-projeto")
        let convs = dir.appendingPathComponent(".gemini/antigravity-cli/conversations")
        try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try? fm.createDirectory(at: convs, withIntermediateDirectories: true)
        fm.createFile(atPath: convs.appendingPathComponent("conv-1.db").path, contents: Data())
        let record = dir.appendingPathComponent("chamada.txt")
        let fake = dir.appendingPathComponent("agy-falso")
        try? "#!/bin/sh\necho \"$PWD | $*\" > '\(record.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("LLMBO_AGY_CMD", fake.path, 1)

        let r = AntigravityResume()
        r.home = dir
        r.handledKey = "antigravityResumeHandledTest"
        r.launchesKey = "antigravityResumeLaunchesTest"
        for k in [r.handledKey, r.launchesKey] { UserDefaults.standard.removeObject(forKey: k) }
        var msgs: [String] = []
        r.notify = { msgs.append($0) }
        var out: [String] = []
        func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "ok " : "ERRO") \(name)") }

        let t0 = Date()
        func full(_ resets: Date) -> [LimitGroup] {
            [LimitGroup(name: "Claude", fiveHour: LimitWindow(usedPercent: 100, resetsAt: resets), weekly: nil)]
        }
        let free = [LimitGroup(name: "Claude", fiveHour: LimitWindow(usedPercent: 10, resetsAt: t0 + 5 * 3600), weekly: nil)]
        let cli = Stop(agent: "antigravity-cli", session: "conv-1", cwd: cwd.path, at: t0)

        _ = r.tick(now: t0, enabled: false, stops: [cli], groups: full(t0 + 3600))
        check("desligado: nada agendado", r.pending.isEmpty && msgs.isEmpty)

        _ = r.tick(now: t0, enabled: true, stops: [cli], groups: full(t0 + 3600))
        check("agenda 1 min depois do reset", r.pending.first?.at == t0 + 3660)
        check("avisa ao agendar", msgs.count == 1)
        check("perto da hora segura o Mac", r.tick(now: t0 + 3500, enabled: true, stops: [cli], groups: full(t0 + 3600)))
        check("acorda 2 min antes", r.wakeTimes(now: t0).first == t0 + 3540)

        _ = r.tick(now: t0 + 3700, enabled: true, stops: [cli], groups: full(t0 + 7200))
        check("cota ainda cheia: adia", r.pending.first?.at == t0 + 7260 && r.pending.first?.postpones == 1)

        _ = r.tick(now: t0 + 7300, enabled: true, stops: [cli], groups: free)
        Thread.sleep(forTimeInterval: 1.5)
        let call = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        check("retoma na pasta da conversa", call.hasPrefix(cwd.resolvingSymlinksInPath().path) || call.hasPrefix("/private" + cwd.path))
        check("com --conversation e sem pular permissões", call.contains("--conversation conv-1")
            && call.contains("--mode accept-edits") && call.contains("--sandbox") && !call.contains("dangerously"))
        check("tira da lista depois de retomar", r.pending.isEmpty)
        _ = Holds.remove(source: "antigravity")

        let again = Stop(agent: "antigravity-cli", session: "conv-1", cwd: cwd.path, at: Date() + 60)
        msgs = []
        _ = r.tick(now: Date() + 120, enabled: true, stops: [again], groups: full(Date() + 3600))
        check("bateu de novo logo depois: desiste", r.pending.isEmpty && msgs.first?.contains("parou de tentar") == true)

        let missing = Stop(agent: "antigravity-cli", session: "nao-existe", cwd: cwd.path, at: t0)
        msgs = []
        _ = r.tick(now: t0, enabled: true, stops: [missing], groups: full(t0 + 3600))
        check("conversa inexistente: não agenda (o agy abriria uma nova)", r.pending.isEmpty && msgs.count == 1)

        let app = Stop(agent: "antigravity", session: "conv-app", cwd: nil, at: t0)
        msgs = []
        _ = r.tick(now: t0, enabled: true, stops: [app], groups: full(t0 + 3600))
        check("app: agenda só o aviso, sem acordar", r.pending.first?.launches == false && r.wakeTimes(now: t0).isEmpty)
        _ = r.tick(now: t0 + 3700, enabled: true, stops: [app], groups: free)
        check("app: avisa quando a cota volta", msgs.last?.contains("cota do Antigravity voltou") == true && r.pending.isEmpty)

        let noQuota = Stop(agent: "antigravity-cli", session: "conv-1", cwd: cwd.path, at: t0 + 30000)
        msgs = []
        _ = r.tick(now: t0 + 30000, enabled: true, stops: [noQuota], groups: nil)
        check("sem leitura da cota: só avisa", r.pending.isEmpty && msgs.count == 1)

        for k in [r.handledKey, r.launchesKey] { UserDefaults.standard.removeObject(forKey: k) }
        unsetenv("LLMBO_AGY_CMD")
        try? fm.removeItem(at: dir)
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("agresume-test.log"),
                                               atomically: true, encoding: .utf8)
    }
}
