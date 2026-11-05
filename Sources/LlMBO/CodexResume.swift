import Foundation

/// "Retomar o Codex depois do limite" (opcional, desligado por padrão). O Codex não continua sozinho quando o
/// limite de uso volta (pedidos abertos no openai/codex: #21073, #34188, #43605). Ligado, para cada sessão parada
/// no limite (UsageStore.codexStops: task_complete com usage_limit_exceeded e nenhum turno depois), o LlMBO avisa,
/// acorda o Mac antes do reset e roda em segundo plano, na pasta da sessão:
///   codex exec --sandbox workspace-write --skip-git-repo-check resume <sessão> "<prompt>"
/// (`codex exec` não pede aprovações; workspace-write deixa editar só a pasta da sessão. As flags gerais vão antes
/// de `resume`, conforme codex-rs/exec/src/cli.rs.) Avisa ao agendar, ao retomar e ao terminar. Desligado, `tick`
/// sai na primeira linha.
@MainActor
final class CodexResume: ObservableObject {
    struct Pending: Equatable {
        let stop: CodexStop
        let at: Date
        var folder: String { (stop.cwd as NSString).lastPathComponent }
    }

    @Published private(set) var pending: [Pending] = []
    private var running: [String: Process] = [:]
    /// Avisos (respeitam "Receber notificações", aba Notificações). O teste troca.
    var notify: (String) -> Void = { Notifier.shared.post($0) }
    /// LLMBO_CODEX_CMD troca o comando (teste com um script falso).
    private var command: String { ProcessInfo.processInfo.environment["LLMBO_CODEX_CMD"] ?? "codex" }
    /// Chave dos tratados no UserDefaults (o teste usa outra).
    var handledKey = "codexResumeHandled"
    /// Paradas já tratadas (agendadas e retomadas, ou avisadas que não dá): não repete.
    private var handled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: handledKey) }
    }
    static let logDir = Paths.support.appendingPathComponent("codex-resume")
    static let prompt = "The usage limit has reset. Continue the task you were working on before the limit stopped you."

    /// Um passo, a cada tick do Engine. Devolve se o Mac deve ficar acordado agora (perto da hora de retomar).
    /// `blocked`: o LlMBO está desligado ou uma trava de segurança vale agora (bateria baixa, Mac quente). Agenda e
    /// avisa igual, mas não retoma nem segura o Mac; a retomada atrasada roda quando a trava sair.
    func tick(now: Date, enabled: Bool, blocked: Bool = false, stops: [CodexStop], usage: AgentUsage) -> Bool {
        guard enabled else {
            if !pending.isEmpty { pending = [] }
            return false
        }
        var done = handled
        let live = Set(stops.map(\.key))
        // Retomada à mão (apareceu um turno depois da parada): esquece a agendada.
        pending.removeAll { !live.contains($0.stop.key) }

        for stop in stops where !done.contains(stop.key) && !pending.contains(where: { $0.stop.key == stop.key }) {
            let folder = (stop.cwd as NSString).lastPathComponent
            guard let reset = usage.resetAfterLimit(hitAt: stop.stoppedAt) else {
                notify(String(localized: "O Codex parou no limite em \(folder), mas o LlMBO não sabe quando o limite volta. Retome a sessão você mesmo."))
                done.insert(stop.key)
                continue
            }
            if reset.timeIntervalSince(now) > 24 * 3600 {
                notify(String(localized: "O Codex parou no limite em \(folder), e ele só volta em mais de 24 h. Retome a sessão você mesmo."))
                done.insert(stop.key)
                continue
            }
            let p = Pending(stop: stop, at: max(reset, now).addingTimeInterval(60))
            pending.append(p)
            notify(String(localized: "O Codex parou no limite em \(folder). O LlMBO vai retomar a sessão às \(UsageFormat.when(p.at)), em segundo plano."))
        }

        guard !blocked else { handled = done; return false }
        for p in pending where now >= p.at {
            launch(p)
            done.insert(p.stop.key)
        }
        pending.removeAll { now >= $0.at }
        handled = done
        return pending.contains { now >= $0.at.addingTimeInterval(-300) }
    }

    /// Despertares necessários (2 min antes de cada retomada).
    func wakeTimes(now: Date) -> [Date] {
        pending.map { $0.at.addingTimeInterval(-120) }.filter { $0.timeIntervalSince(now) > 60 }
    }

    private func launch(_ p: Pending) {
        let folder = p.folder
        // Pelo shell de login: acha o codex (e o node, se veio do npm) no PATH do usuário.
        guard run("/bin/zsh", ["-lc", "command -v \"$0\"", command]).status == 0 else {
            notify(String(localized: "Não encontrei o comando codex para retomar a sessão em \(folder). Retome você mesmo."))
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let log = Self.logDir.appendingPathComponent("\(p.stop.sessionID).log")
        fm.createFile(atPath: log.path, contents: nil)
        let out = try? FileHandle(forWritingTo: log)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "exec \"$0\" \"$@\"", command,
                          "exec", "--sandbox", "workspace-write", "--skip-git-repo-check",
                          "resume", p.stop.sessionID, Self.prompt]
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p.stop.cwd, isDirectory: &isDir), isDir.boolValue {
            proc.currentDirectoryURL = URL(fileURLWithPath: p.stop.cwd)
        }
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        let key = p.stop.key
        proc.terminationHandler = { [weak self] pr in
            let status = Int(pr.terminationStatus)
            Task { @MainActor in
                guard let self else { return }
                self.running.removeValue(forKey: key)
                try? out?.close()
                self.notify(status == 0
                    ? String(localized: "A retomada do Codex em \(folder) terminou. Abra a sessão no Codex para ver o resultado.")
                    : String(localized: "A retomada do Codex em \(folder) terminou com erro (código \(status)). O registro está em Application Support/LlMBO/codex-resume."))
            }
        }
        do { try proc.run() } catch {
            notify(String(localized: "Não encontrei o comando codex para retomar a sessão em \(folder). Retome você mesmo."))
            return
        }
        running[key] = proc
        // Segura o Mac enquanto a retomada roda e mostra em "Tarefas longas".
        _ = try? Holds.write(name: String(localized: "Codex · \(folder) (retomada)"), pid: proc.processIdentifier, minutes: nil, source: "codex")
        notify(String(localized: "O Codex voltou a trabalhar em \(folder), em segundo plano."))
    }
}

// MARK: - Teste

extension CodexResume {
    /// LLMBO_TEST_CODEX=1: com um `codex` falso (anota argumentos e pasta) e paradas sintéticas, confere
    /// desligado, agendar, segurar perto da hora, retomar, cancelar e "sem hora de reset". Grava codex-test.log.
    static func selfTest() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("llmbo-codex-test-\(UUID().uuidString)")
        let cwd = dir.appendingPathComponent("meu-projeto")
        try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let record = dir.appendingPathComponent("chamada.txt")
        let fake = dir.appendingPathComponent("codex-falso")
        try? "#!/bin/sh\necho \"$PWD | $*\" > '\(record.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("LLMBO_CODEX_CMD", fake.path, 1)

        let r = CodexResume()
        r.handledKey = "codexResumeHandledTest"
        UserDefaults.standard.removeObject(forKey: r.handledKey)
        var msgs: [String] = []
        r.notify = { msgs.append($0) }
        var out: [String] = []
        func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "ok " : "ERRO") \(name)") }

        let now = Date()
        let stop = CodexStop(sessionID: "sess-1", cwd: cwd.path, stoppedAt: now.addingTimeInterval(-600))
        let usage = AgentUsage(fiveHour: LimitWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(600)))

        check("desligado não faz nada", !r.tick(now: now, enabled: false, stops: [stop], usage: usage) && r.pending.isEmpty && msgs.isEmpty)
        check("agenda e avisa", !r.tick(now: now, enabled: true, stops: [stop], usage: usage) && r.pending.count == 1 && msgs.count == 1)
        check("agendada para reset + 1 min", abs((r.pending.first?.at ?? .distantPast).timeIntervalSince(now.addingTimeInterval(660))) < 1)
        check("despertar 2 min antes", r.wakeTimes(now: now).count == 1)
        check("segura o Mac 5 min antes", r.tick(now: now.addingTimeInterval(400), enabled: true, stops: [stop], usage: usage))
        // Trava de segurança na hora da retomada: não roda nem segura; roda quando a trava sair.
        check("trava: não segura o Mac", !r.tick(now: now.addingTimeInterval(400), enabled: true, blocked: true, stops: [stop], usage: usage))
        _ = r.tick(now: now.addingTimeInterval(700), enabled: true, blocked: true, stops: [stop], usage: usage)
        check("trava: não retoma na hora", r.pending.count == 1 && msgs.count == 1)
        _ = r.tick(now: now.addingTimeInterval(700), enabled: true, stops: [stop], usage: usage)
        check("retomou e avisou", r.pending.isEmpty && msgs.count == 2)
        var call = ""
        for _ in 0..<50 where call.isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
            call = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        }
        check("rodou na pasta da sessão", call.hasPrefix(cwd.path) || call.contains("/meu-projeto |"))
        check("argumentos certos", call.contains("exec --sandbox workspace-write --skip-git-repo-check resume sess-1 The usage limit has reset."))
        check("não repete a mesma parada", !r.tick(now: now.addingTimeInterval(800), enabled: true, stops: [stop], usage: usage) && r.pending.isEmpty)

        let stop2 = CodexStop(sessionID: "sess-2", cwd: cwd.path, stoppedAt: now.addingTimeInterval(-60))
        _ = r.tick(now: now, enabled: true, stops: [stop2], usage: usage)
        _ = r.tick(now: now, enabled: true, stops: [], usage: usage)   // você retomou à mão
        check("retomada à mão cancela", r.pending.isEmpty)

        let stop3 = CodexStop(sessionID: "sess-3", cwd: cwd.path, stoppedAt: now)
        let before = msgs.count
        _ = r.tick(now: now, enabled: true, stops: [stop3], usage: AgentUsage())
        check("sem hora de reset: só avisa", r.pending.isEmpty && msgs.count == before + 1)

        out.append("avisos:")
        out += msgs.map { "  " + $0 }
        out.append("chamada: " + call.trimmingCharacters(in: .whitespacesAndNewlines))
        unsetenv("LLMBO_CODEX_CMD")
        UserDefaults.standard.removeObject(forKey: r.handledKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { try? fm.removeItem(at: dir) }
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("codex-test.log"), atomically: true, encoding: .utf8)
    }
}
