import AppKit
import Foundation

/// Endereços públicos do projeto. O repositório fica numa constante só (site, atualização e relatos usam esta).
enum Project {
    static let repo = "fcknferreira/LlMBO"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!
    /// `LLMBO_UPDATE_API` troca o endereço só para testar a atualização com um servidor local.
    static let latestAPI = ProcessInfo.processInfo.environment["LLMBO_UPDATE_API"].flatMap(URL.init(string:))
        ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// Certificado com que as Releases são assinadas ("LlMBO Local Signing"). A atualização pelo app só aceita
    /// um pacote assinado por ele: quem tomasse a conta do GitHub não conseguiria entregar outro app.
    static let signingLeaf = "9e652604d46ed9ddec648e1beeb56bf92d869d77"

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}

/// Registro local de erros e avisos (`app.log` em Application Support, últimas 300 linhas). Nada sai do Mac;
/// o "Relatar problema…" só mostra o fim dele numa issue que a própria pessoa revisa antes de enviar.
enum AppLog {
    static let file = Paths.support.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "llmbo.applog")
    private static var last = ""

    static func write(_ text: String) {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        queue.async {
            guard line != last else { return }   // a mesma mensagem repetida a cada tick não enche o arquivo
            last = line
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append("\(f.string(from: Date())) \(line)")
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Fim de um registro, com o caminho da pasta pessoal trocado por ~.
    static func tail(_ url: URL, lines n: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
        return redact(tail)
    }

    static func redact(_ s: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return s.replacingOccurrences(of: home, with: "~")
            .replacingOccurrences(of: NSUserName(), with: "<user>")
    }
}

/// "Relatar problema…": abre uma issue nova no GitHub já preenchida com versão, macOS, modelo e o fim dos
/// registros. A pessoa vê e edita tudo antes de enviar; nada é mandado pelo app.
enum ProblemReport {
    static func body() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let lang = Locale.preferredLanguages.first ?? "?"
        var parts = [
            "**\(String(localized: "O que aconteceu?"))**\n\n\n",
            "**\(String(localized: "O que você esperava?"))**\n\n\n",
            "---",
            "LlMBO \(Project.version) (\(Project.build)) · macOS \(os) · \(String(cString: model)) · \(lang)",
        ]
        for (name, n) in [("app.log", 40), ("watchdog.log", 10)] {
            let t = AppLog.tail(Paths.support.appendingPathComponent(name), lines: n)
            if !t.isEmpty { parts.append("<details><summary>\(name)</summary>\n\n```\n\(t)\n```\n</details>") }
        }
        var text = parts.joined(separator: "\n")
        // URLs muito longas são recusadas pelo GitHub: corta o registro, não o cabeçalho.
        if text.count > 6000 { text = String(text.prefix(6000)) + "\n```\n</details>" }
        return text
    }

    static func open() {
        var c = URLComponents(string: "https://github.com/\(Project.repo)/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body())]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}

/// Atualização sem servidor: consulta a última Release do GitHub (1×/dia e no botão), baixa o LlMBO.zip,
/// confere a assinatura, troca o app no lugar e reabre — passando o Mac adiante como o update.command.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading, failed(String)
    }

    @Published var state: State = .idle
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") }
    }

    var available: Release? { if case .available(let r) = state { return r }; return nil }

    private var timer: Timer?
    private static let lastCheckKey = "updateLastCheck"

    /// Chamado ao abrir: confere uma vez por dia (se a opção estiver ligada), sem incomodar quando não há nada.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Updater.shared.checkIfDue() }
    }

    private func checkIfDue() {
        guard autoCheck, Self.isInstalledCopy else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool = true) async {
        if case .downloading = state { return }
        if manual { state = .checking }
        do {
            var req = URLRequest(url: Project.latestAPI, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("LlMBO/\(Project.version)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw UpdateError.message(String(localized: "Nenhuma versão publicada ainda.")) }
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                throw UpdateError.message(String(localized: "O GitHub não respondeu (código \(code))."))
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String) == "LlMBO.zip" }?["browser_download_url"] as? String
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Project.releasesURL
            if Self.isNewer(version, than: Project.version), let zip, let zipURL = URL(string: zip) {
                let release = Release(version: version, notes: json["body"] as? String ?? "", zip: zipURL, page: page)
                let wasNew = available != release
                state = .available(release)
                if wasNew && !manual { Notifier.shared.updateAvailable(version) }
            } else {
                state = manual ? .upToDate : .idle
            }
        } catch {
            AppLog.write("atualização: \(error.localizedDescription)")
            state = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Só a cópia em Aplicativos se troca sozinha (rodando de um build, de Downloads ou de uma pasta temporária
    /// do macOS — "App Translocation" —, o pacote não está onde a pessoa vai abrir da próxima vez).
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    func install() async {
        guard let release = available else { return }
        guard Self.isInstalledCopy else {
            state = .failed(String(localized: "Mova o LlMBO para a pasta Aplicativos para atualizar por aqui."))
            return
        }
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("llmbo-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: release.zip)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.message(String(localized: "Não consegui baixar a versão nova."))
            }
            let zip = work.appendingPathComponent("LlMBO.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            let newApp = try await Task.detached { try Self.unpackAndVerify(zip: zip, in: work) }.value
            try handOff(to: newApp)
        } catch {
            AppLog.write("atualização: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Descompacta e só aceita o pacote se for o LlMBO, inteiro e assinado pelo certificado das Releases.
    nonisolated private static func unpackAndVerify(zip: URL, in work: URL) throws -> URL {
        let out = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status == 0 else {
            throw UpdateError.message(String(localized: "O arquivo baixado está corrompido."))
        }
        let app = out.appendingPathComponent("LlMBO.app")
        guard Bundle(url: app)?.bundleIdentifier == "com.llmbo.app" else {
            throw UpdateError.message(String(localized: "O arquivo baixado não é o LlMBO."))
        }
        let requirement = "=identifier \"com.llmbo.app\" and certificate leaf = H\"\(Project.signingLeaf)\""
        let check = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path])
        guard check.status == 0 else {
            throw UpdateError.message(String(localized: "A assinatura da versão nova não confere; nada foi trocado."))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Deixa um script trocando o app depois que este sair (o aviso de troca faz o app sair segurando o Mac,
    /// e a versão nova assume — `Engine.shutdown`/`takeHandoff`). Se a troca falhar, reabre o app antigo.
    private func handOff(to newApp: URL) throws {
        let dest = Bundle.main.bundleURL
        let parent = dest.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.message(String(localized: "Sem permissão para trocar o app em \(parent.path)."))
        }
        let script = newApp.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("swap.sh")
        let log = Paths.support.appendingPathComponent("update.log").path
        let text = """
        #!/bin/bash
        PID=\(ProcessInfo.processInfo.processIdentifier)
        NEW=\(shellQuote(newApp.path))
        DEST=\(shellQuote(dest.path))
        exec >\(shellQuote(log)) 2>&1
        echo "$(date '+%F %T') troca para \(release(of: newApp))"
        for _ in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.25; done
        if kill -0 $PID 2>/dev/null; then kill -TERM $PID; for _ in $(seq 1 20); do kill -0 $PID 2>/dev/null || break; sleep 0.25; done; fi
        if kill -0 $PID 2>/dev/null; then echo "o app não saiu; nada trocado"; exit 1; fi
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && ditto "$NEW" "$DEST"; then
          rm -rf "$DEST.old"; echo "trocado"
        else
          echo "falhou; voltando a versão anterior"; rm -rf "$DEST"; mv "$DEST.old" "$DEST"
        fi
        for i in 1 2 3; do open "$DEST" && break; sleep 2; done
        rm -rf \(shellQuote(newApp.deletingLastPathComponent().deletingLastPathComponent().path))
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        try p.run()
        try? "pending".write(to: Engine.handoffFile, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func release(of app: URL) -> String {
        Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Aberto fora de Aplicativos (Downloads, DMG, pasta temporária do macOS): oferece mover para lá, onde a
/// atualização e o "abrir ao iniciar sessão" funcionam.
enum MoveToApplications {
    @MainActor static func offerIfNeeded() {
        let path = Bundle.main.bundlePath
        guard !Updater.isInstalledCopy, !path.contains("/build/"), !path.contains("/.build/"),
              !UserDefaults.standard.bool(forKey: "moveToApplicationsDeclined") else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Mover o LlMBO para Aplicativos?")
        alert.informativeText = String(localized: "O LlMBO está rodando fora da pasta Aplicativos. Lá ele abre ao iniciar sessão e se atualiza sozinho.")
        alert.addButton(withTitle: String(localized: "Mover para Aplicativos"))
        alert.addButton(withTitle: String(localized: "Agora não"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "moveToApplicationsDeclined")
            return
        }
        let dest = URL(fileURLWithPath: "/Applications/LlMBO.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", dest.path]
            try? x.run(); x.waitUntilExit()
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            Engine.shared.shutdown()
            NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
                DispatchQueue.main.async { exit(0) }
            }
        } catch {
            AppLog.write("mover para Aplicativos: \(error.localizedDescription)")
            let fail = NSAlert()
            fail.messageText = String(localized: "Não consegui mover o LlMBO.")
            fail.informativeText = String(localized: "Arraste o LlMBO para a pasta Aplicativos no Finder e abra de lá.")
            fail.runModal()
        }
    }
}
