import Foundation
import ServiceManagement

/// Vigia contra travamento: um processo companheiro do próprio executável (`LlMBO --watchdog-loop <pid do app>`),
/// aberto pelo app ao iniciar. Aparece como LlMBO no Monitor de Atividade e continua vivo se o app travar ou for
/// derrubado (kill -9 não leva os filhos junto). O app avisa que segura o repouso pelo arquivo `holding` e que está
/// vivo pelo `heartbeat` (a cada tick). Se `holding` existe e o batimento parou há mais de 60 s, o vigia devolve o
/// repouso e, com a tampa fechada, põe o Mac para dormir.
/// Antes era um agente do launchd registrado com `SMAppService.agent` (rodando a cada 20 s), mas a cada build com
/// assinatura ad-hoc o macOS passava a recusar o executável (launchctl: "spawn failed", código 78, restrição de
/// lançamento com lista de cdhash vazia) e registrar de novo não resolvia — visto no teste de tampa fechada de
/// 02/11/2026, em que o app foi derrubado e o vigia não rodou. O registro antigo é desfeito ao abrir.
enum Watchdog {
    static let plistName = "com.llmbo.app.watchdog.plist"
    /// Uma passada só (o agente antigo do launchd usava isto).
    static let argument = "--watchdog"
    /// O processo companheiro: `--watchdog-loop <pid do app>`.
    static let loopArgument = "--watchdog-loop"
    static let holding = Paths.support.appendingPathComponent("holding")
    static let heartbeat = Paths.support.appendingPathComponent("heartbeat")
    static let log = Paths.support.appendingPathComponent("watchdog.log")
    /// Batimento mais velho que isso = app travado ou fechado.
    static let limit: TimeInterval = 60
    /// De quanto em quanto tempo o companheiro confere.
    static let interval: UInt32 = 10

    /// Só para desfazer o registro antigo (o plist continua no pacote para isso).
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }
    nonisolated(unsafe) private static var companion: Process?

    enum Status { case active, needsApproval, off }

    static var status: Status { companion?.isRunning == true ? .active : .off }

    /// Abre o companheiro (se ainda não estiver rodando) e desfaz o agente antigo do launchd.
    static func install() {
        removeLegacy()
        if service.status != .notRegistered { try? service.unregister() }
        guard companion?.isRunning != true, let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = [loopArgument, String(getpid())]
        do { try p.run(); companion = p } catch { write("não consegui abrir o vigia: \(error.localizedDescription)") }
    }

    static func remove() {
        companion?.terminate()
        companion = nil
        if service.status != .notRegistered { try? service.unregister() }
        setHolding(false)
    }

    /// Laço do companheiro. Sai quando o app terminou e não deixou o Mac seguro, ou quando outra instância do app
    /// já está dando sinal de vida (atualização pelo update.command: o app novo abre o próprio vigia).
    static func loop(appPID: pid_t) -> Never {
        while true {
            check()
            if appPID <= 0 || kill(appPID, 0) != 0 {
                if !holdingMarked || otherAppRunning(than: appPID) { exit(0) }
            }
            sleep(interval)
        }
    }

    /// Outro processo do app (não um vigia nem um servidor MCP, que têm argumentos) está rodando.
    private static func otherAppRunning(than pid: pid_t) -> Bool {
        run("/usr/bin/pgrep", ["-f", "/Contents/MacOS/LlMBO$"]).output
            .split(separator: "\n").contains { pid_t($0) != pid && pid_t($0) != getpid() }
    }

    private static var heartbeatAge: Int {
        let beatDate = (try? FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate] as? Date) ?? .distantPast
        return Int(Date().timeIntervalSince(beatDate))
    }

    /// A primeira versão (02/11/2026) era um script bash num LaunchAgent solto em ~/Library/LaunchAgents.
    private static func removeLegacy() {
        let fm = FileManager.default
        let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.llmbo.watchdog.plist")
        guard fm.fileExists(atPath: plist.path) else { return }
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/com.llmbo.watchdog"])
        try? fm.removeItem(at: plist)
        try? fm.removeItem(at: Paths.support.appendingPathComponent("llmbo-watchdog"))
    }

    static func beat() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: heartbeat.path) {
            fm.createFile(atPath: heartbeat.path, contents: nil)
        } else {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: heartbeat.path)
        }
    }

    static func setHolding(_ on: Bool) {
        if on {
            beat()   // o vigia não pode achar o batimento velho logo depois de segurar
            FileManager.default.createFile(atPath: holding.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: holding)
        }
    }

    /// O vigia apaga `holding` quando age: o app usa isso para saber que perdeu o repouso.
    static var holdingMarked: Bool { FileManager.default.fileExists(atPath: holding.path) }

    // MARK: Processo do vigia

    /// Uma passada do vigia (a cada 10 s no companheiro). Não abre interface.
    static func check() {
        guard holdingMarked else { return }
        let age = heartbeatAge
        guard Double(age) > limit else { return }

        let appRunning = otherAppRunning(than: 0)
        write(appRunning ? "app sem resposta há \(age)s; religando o repouso"
                         : "app fechado há \(age)s com o repouso desligado; religando o repouso")
        guard Power.setSleepDisabled(false) else {
            write("não consegui religar o repouso (permissão do sudo ausente?)")
            return
        }
        setHolding(false)
        if Power.lidClosed {
            write("tampa fechada; dormindo")
            Power.sleepNow()
        }
    }

    private static func write(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime])
        let text = "\(stamp) \(line)\n"
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: log)
        }
        // Mantém o log curto.
        if let all = try? String(contentsOf: log, encoding: .utf8) {
            let lines = all.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 200 { try? lines.suffix(100).joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8) }
        }
    }
}
