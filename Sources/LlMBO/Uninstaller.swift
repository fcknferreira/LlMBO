import AppKit
import ServiceManagement

/// Tira do Mac tudo o que o LlMBO instalou e manda o app para o Lixo. Arrastar o app para o Lixo deixaria para trás
/// a regra do sudoers, os hooks e o MCP nos arquivos dos agentes, a barra de status do Claude Code e os backups.
/// Toda integração nova que mexe fora do app entra aqui também.
enum Uninstaller {
    @MainActor static func confirmAndRun(_ engine: Engine) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Desinstalar o LlMBO?")
        alert.informativeText = String(localized: "Sai tudo o que o LlMBO instalou: a permissão de administrador, os hooks e o servidor MCP dos agentes, a barra de status do Claude Code, o vigia, o abrir ao iniciar sessão, os ajustes e o próprio app, que vai para o Lixo. Os arquivos de configuração dos agentes continuam, só sem as entradas do LlMBO.")
        alert.addButton(withTitle: String(localized: "Desinstalar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // A senha vem primeiro: cancelada, nada muda.
        engine.disarm()
        if Power.helperInstalled, !Power.uninstallHelper() {
            let fail = NSAlert()
            fail.messageText = String(localized: "A desinstalação foi cancelada.")
            fail.informativeText = String(localized: "Sem a senha de administrador a permissão não sai. Nada foi mudado.")
            fail.runModal()
            return
        }

        var failed: [String] = []
        if let w = engine.scheduledWake, w > Date() { Power.cancelWake(w) }
        failed += removeIntegrations(home: Hooks.realHome, includeClaude: true)
        Watchdog.remove()
        if SMAppService.mainApp.status != .notRegistered { try? SMAppService.mainApp.unregister() }
        for url in leftovers(home: Hooks.realHome) + [Paths.support] { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }

        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
        removeWidget()
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)

        let done = NSAlert()
        done.messageText = String(localized: "O LlMBO foi desinstalado.")
        done.informativeText = failed.isEmpty
            ? String(localized: "O app foi para o Lixo.")
            : String(localized: "O app foi para o Lixo. Não deu para tirar: \(failed.joined(separator: ", ")).")
        done.runModal()
        exit(0)
    }

    /// Widgets: a extensão vai junto com o app; aqui só sai do registro do macOS (some da galeria na hora) e a pasta
    /// isolada dela vai para o Lixo. Essa pasta é protegida pelo macOS e às vezes não sai: não conta como falha.
    static func removeWidget() {
        let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/LlMBOWidget.appex")
        _ = run("/usr/bin/pluginkit", ["-r", appex.path])
        let container = Hooks.realHome.appendingPathComponent("Library/Containers/com.llmbo.app.widget")
        try? FileManager.default.trashItem(at: container, resultingItemURL: nil)
    }

    /// Tira hooks, barra de status e MCP de todos os agentes. Devolve o que não saiu.
    /// `includeClaude: false` (teste) pula o que só existe na home real: o MCP do Claude Code vai pelo CLI e a
    /// barra de status mexe no ~/.claude/settings.json de verdade.
    static func removeIntegrations(home: URL, includeClaude: Bool) -> [String] {
        var failed: [String] = []
        for agent in Hooks.supported.sorted() where Hooks.state(agent, home: home) == .installed {
            if case .failure = Hooks.uninstall(agent, home: home) { failed.append("hook \(agent)") }
        }
        Hooks.cleanUpLegacy(home: home)
        if includeClaude, (try? Hooks.removeStatusLine()) == nil {
            failed.append(String(localized: "barra de status do Claude Code"))
        }
        for target in MCPInstall.targets where (includeClaude || target.id != "claude") && MCPInstall.isInstalled(target) {
            if (try? MCPInstall.remove(target)) == nil { failed.append("MCP \(target.name)") }
        }
        return failed
    }

    /// Backups `.llmbo-backup` ao lado dos arquivos dos agentes e a pasta que o `/usage` deixa em ~/.claude/projects.
    /// Vão para o Lixo junto com a pasta de dados do LlMBO (dá para recuperar).
    static func leftovers(home: URL) -> [URL] {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support")
        let roots = [".claude", ".codex", ".gemini", ".qwen", ".copilot", ".cursor", ".config", ".kiro",
                     ".lmstudio", ".continue", ".cline", ".codeium"].map { home.appendingPathComponent($0) }
            + ["Code", "Code - Insiders", "Cursor", "Windsurf"].map {
                support.appendingPathComponent($0).appendingPathComponent("User/globalStorage")
            }
        var found: [URL] = []
        // Arquivos soltos na pasta de casa (~/.aider.conf.yml).
        for url in (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "llmbo-backup" { found.append(url) }
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e {
                if e.level > 6 { e.skipDescendants(); continue }
                if url.pathExtension == "llmbo-backup" { found.append(url) }
            }
        }
        let projects = home.appendingPathComponent(".claude/projects")
        for url in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasSuffix("-Application-Support-LlMBO") { found.append(url) }
        return found
    }

    /// LLMBO_TEST_UNINSTALL=1: numa home temporária com configurações "de antes", instala todos os hooks e o MCP
    /// em todos os destinos (menos o Claude Code), roda a remoção e confere que nada do LlMBO ficou, que o que já
    /// existia continua e que os backups foram achados. Grava uninstall-test.log.
    static func selfTest() {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("llmbo-uninstall-test-\(UUID().uuidString)")
        MCPInstall.homeOverride = home
        defer { MCPInstall.homeOverride = nil; try? fm.removeItem(at: home) }
        func put(_ path: String, _ text: String) {
            let u = home.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String { (try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        put(".claude/settings.json", #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"outro"}]}]}}"#)
        put(".codex/config.toml", "model = \"gpt\"\n")
        put(".gemini/config/hooks.json", "{}")
        put(".gemini/config/mcp_config.json", #"{"mcpServers":{"outro":{"command":"x"}}}"#)
        put(".qwen/settings.json", #"{"theme":"dark"}"#)
        put(".cursor/hooks.json", #"{"version":1,"hooks":{}}"#)
        put(".aider.conf.yml", "model: x\n")
        put(".config/opencode/opencode.json", #"{"model":"m"}"#)
        put(".claude/projects/-Users-x-Library-Application-Support-LlMBO/memory/.keep", "")

        var out: [String] = []
        for agent in Hooks.supported.sorted() {
            if case .failure(let e) = Hooks.install(agent, home: home) { out.append("instalar hook \(agent): \(e.localizedDescription)") }
        }
        for t in MCPInstall.targets where t.id != "claude" {
            do { try MCPInstall.install(t) } catch { out.append("instalar MCP \(t.id): \(error.localizedDescription)") }
        }
        let hooksOn = Hooks.supported.filter { Hooks.state($0, home: home) == .installed }.count
        let mcpOn = MCPInstall.targets.filter { $0.id != "claude" && MCPInstall.isInstalled($0) }.count
        out.append("antes: hooks=\(hooksOn) mcp=\(mcpOn)")

        let failed = removeIntegrations(home: home, includeClaude: false)
        let hooksLeft = Hooks.supported.filter { Hooks.state($0, home: home) == .installed }.sorted()
        let mcpLeft = MCPInstall.targets.filter { $0.id != "claude" && MCPInstall.isInstalled($0) }.map(\.id)
        out.append("depois: hooks=\(hooksLeft) mcp=\(mcpLeft) falhas=\(failed)")

        // Nada com o caminho do llmbo-signal ou do executável sobrou nos arquivos (fora os backups).
        var mentions: [String] = []
        if let e = fm.enumerator(at: home, includingPropertiesForKeys: nil, options: []) {
            for case let url as URL in e where url.pathExtension != "llmbo-backup" {
                let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if t.contains("llmbo-signal") || t.contains(MCPServer.argument) {
                    mentions.append(url.path.replacingOccurrences(of: home.path, with: "~"))
                }
            }
        }
        out.append("sobras: \(mentions)")
        out.append("preservado claude=\(read(".claude/settings.json").contains("outro") && read(".claude/settings.json").contains("opus"))"
                   + " gemini=\(read(".gemini/config/mcp_config.json").contains("outro"))"
                   + " qwen=\(read(".qwen/settings.json").contains("dark"))"
                   + " aider=\(read(".aider.conf.yml").contains("model"))"
                   + " codex=\(read(".codex/config.toml").contains("gpt"))"
                   + " opencode=\(read(".config/opencode/opencode.json").contains("\"model\""))")
        let found = leftovers(home: home).map { $0.path.replacingOccurrences(of: home.path, with: "~") }.sorted()
        out.append("lixo (\(found.count)): \(found)")
        let ok = failed.isEmpty && hooksLeft.isEmpty && mcpLeft.isEmpty && mentions.isEmpty && hooksOn > 0 && mcpOn > 0
        out.append(ok ? "RESULTADO: ok" : "RESULTADO: FALHOU")
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("uninstall-test.log"),
                                                atomically: true, encoding: .utf8)
    }
}
