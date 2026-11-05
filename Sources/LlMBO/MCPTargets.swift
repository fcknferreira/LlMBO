import Foundation

/// Onde cada agente guarda os servidores MCP (docs oficiais de 02/11/2026). Todos recebem o mesmo servidor:
/// o executável do LlMBO com `--mcp`, com o nome "llmbo". Arquivos JSON que não forem um objeto válido
/// (com comentários, por exemplo) não são tocados; antes da primeira mudança fica um `.llmbo-backup`.
struct MCPTarget: Identifiable {
    enum Format {
        /// Claude Code: pelo próprio CLI (`claude mcp add --scope user`).
        case claudeCLI
        /// Codex: tabela [mcp_servers.llmbo] no ~/.codex/config.toml.
        case codexTOML
        /// Arquivo JSON com um mapa de servidores em `key`; `extra` vai junto do command/args.
        case json(paths: [String], key: String, extra: [String: Any])
        /// OpenCode: chave "mcp", `type: local`, `command` como lista.
        case opencode
        /// Crush: linha `mcp add` no ~/.config/crush/crushrc.
        case crush
        /// Goose: extensão em `extensions:` do ~/.config/goose/config.yaml.
        case goose
        /// Continue: arquivo próprio em ~/.continue/mcpServers/.
        case continueYAML
    }

    let id: String
    let name: String
    /// Agentes da lista que usam este destino (a interface mostra o destino se algum deles estiver na lista).
    let agentIDs: Set<String>
    let format: Format
}

extension MCPInstall {
    private static var homeURL: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }
    private static func url(_ path: String) -> URL { homeURL.appendingPathComponent(path) }
    private static let serverName = "llmbo"

    /// Pastas globais das extensões nos editores do VS Code (Code, Insiders, Cursor, Windsurf).
    private static func extensionSettings(_ ext: String, _ file: String) -> [String] {
        ["Code", "Code - Insiders", "Cursor", "Windsurf"].map {
            "Library/Application Support/\($0)/User/globalStorage/\(ext)/settings/\(file)"
        }
    }

    static let targets: [MCPTarget] = [
        MCPTarget(id: "claude", name: "Claude Code", agentIDs: ["claude"], format: .claudeCLI),
        MCPTarget(id: "codex", name: "Codex", agentIDs: ["codex"], format: .codexTOML),
        // App, IDE e CLI leem o mesmo arquivo global (antigravity.google/docs/mcp).
        MCPTarget(id: "antigravity", name: "Antigravity", agentIDs: ["antigravity", "antigravity-ide", "antigravity-cli"],
                  format: .json(paths: [".gemini/config/mcp_config.json"], key: "mcpServers", extra: [:])),
        MCPTarget(id: "gemini", name: "Gemini CLI", agentIDs: ["gemini"],
                  format: .json(paths: [".gemini/settings.json"], key: "mcpServers", extra: [:])),
        MCPTarget(id: "qwen", name: "Qwen Code", agentIDs: ["qwen"],
                  format: .json(paths: [".qwen/settings.json"], key: "mcpServers", extra: [:])),
        // Copilot CLI e o Copilot do VS Code ("Copilot Global") leem ~/.copilot/mcp-config.json.
        MCPTarget(id: "copilot", name: "GitHub Copilot", agentIDs: ["copilot", "copilot-vscode"],
                  format: .json(paths: [".copilot/mcp-config.json"], key: "mcpServers", extra: ["type": "local", "tools": ["*"]])),
        MCPTarget(id: "cursor", name: "Cursor", agentIDs: ["cursor"],
                  format: .json(paths: [".cursor/mcp.json"], key: "mcpServers", extra: ["type": "stdio"])),
        MCPTarget(id: "kiro", name: "Kiro", agentIDs: ["kiro"],
                  format: .json(paths: [".kiro/settings/mcp.json"], key: "mcpServers", extra: [:])),
        // Windsurf virou Devin Desktop (~/.config/devin); o caminho antigo ainda vale para versões antigas.
        MCPTarget(id: "windsurf", name: "Windsurf / Devin", agentIDs: ["windsurf"],
                  format: .json(paths: [".config/devin/mcp_config.json", ".codeium/windsurf/mcp_config.json"],
                                key: "mcpServers", extra: [:])),
        MCPTarget(id: "amp", name: "Amp", agentIDs: ["amp"],
                  format: .json(paths: [".config/amp/settings.json"], key: "amp.mcpServers", extra: [:])),
        MCPTarget(id: "opencode", name: "OpenCode", agentIDs: ["opencode"], format: .opencode),
        MCPTarget(id: "crush", name: "Crush", agentIDs: ["crush"], format: .crush),
        MCPTarget(id: "goose", name: "Goose", agentIDs: ["goose"], format: .goose),
        MCPTarget(id: "cline", name: "Cline", agentIDs: ["cline"],
                  format: .json(paths: extensionSettings("saoudrizwan.claude-dev", "cline_mcp_settings.json")
                                + [".cline/data/settings/cline_mcp_settings.json"], key: "mcpServers", extra: ["disabled": false])),
        MCPTarget(id: "roo-code", name: "Roo Code", agentIDs: ["roo-code"],
                  format: .json(paths: extensionSettings("rooveterinaryinc.roo-cline", "mcp_settings.json"),
                                key: "mcpServers", extra: ["disabled": false])),
        MCPTarget(id: "kilo-code", name: "Kilo Code", agentIDs: ["kilo-code"],
                  format: .json(paths: extensionSettings("kilocode.kilo-code", "mcp_settings.json"),
                                key: "mcpServers", extra: ["disabled": false])),
        MCPTarget(id: "continue", name: "Continue", agentIDs: ["continue"], format: .continueYAML),
        // IA local com cliente MCP: o modelo local também pode pedir para segurar o Mac.
        MCPTarget(id: "lmstudio", name: "LM Studio", agentIDs: ["lmstudio"],
                  format: .json(paths: [".lmstudio/mcp.json"], key: "mcpServers", extra: [:])),
    ]

    // MARK: Estado

    static func isInstalled(_ t: MCPTarget) -> Bool {
        switch t.format {
        case .claudeCLI: return claudeInstalled
        case .codexTOML: return codexInstalled
        case .json(let paths, let key, _):
            return jsonFiles(paths, creating: false).contains { (readObject($0)?[key] as? [String: Any])?[serverName] != nil }
        case .opencode: return (readObject(opencodeFile)?["mcp"] as? [String: Any])?[serverName] != nil
        case .crush: return text(crushFile).contains(crushLine)
        case .goose: return text(gooseFile).contains(gooseMarker)
        case .continueYAML: return FileManager.default.fileExists(atPath: continueFile.path)
        }
    }

    static func install(_ t: MCPTarget) throws {
        switch t.format {
        case .claudeCLI: try installClaude()
        case .codexTOML: try installCodex()
        case .json(let paths, let key, let extra):
            var entry = extra
            entry["command"] = executable
            entry["args"] = [MCPServer.argument]
            for file in jsonFiles(paths, creating: true) { try setEntry(file, key: key, entry) }
        case .opencode:
            try setEntry(opencodeFile, key: "mcp",
                         ["type": "local", "command": [executable, MCPServer.argument], "enabled": true])
        case .crush:
            try removeCrush()
            var s = text(crushFile)
            if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            try write(s + crushLine + "\n", to: crushFile)
        case .goose:
            try removeGoose()
            var lines = text(gooseFile).components(separatedBy: "\n")
            let block = ["  \(serverName):  \(gooseMarker)", "    name: \(serverName)", "    type: stdio",
                         "    cmd: \(executable)", "    args:", "    - \"\(MCPServer.argument)\"",
                         "    enabled: true", "    timeout: 300"]
            if let i = lines.firstIndex(where: { $0.hasPrefix("extensions:") }) {
                lines.insert(contentsOf: block, at: i + 1)
            } else {
                if lines.last?.isEmpty == true { lines.removeLast() }
                lines += ["extensions:"] + block + [""]
            }
            try write(lines.joined(separator: "\n"), to: gooseFile)
        case .continueYAML:
            try write("""
            name: LlMBO
            version: 0.0.1
            schema: v1
            mcpServers:
              - name: \(serverName)
                type: stdio
                command: \(executable)
                args:
                  - "\(MCPServer.argument)"

            """, to: continueFile)
        }
    }

    static func remove(_ t: MCPTarget) throws {
        switch t.format {
        case .claudeCLI: try removeClaude()
        case .codexTOML: try removeCodex()
        case .json(let paths, let key, _):
            for file in jsonFiles(paths, creating: false) { try removeEntry(file, key: key) }
        case .opencode: try removeEntry(opencodeFile, key: "mcp")
        case .crush: try removeCrush()
        case .goose: try removeGoose()
        case .continueYAML: try? FileManager.default.removeItem(at: continueFile)
        }
    }

    // MARK: JSON

    /// Arquivos que existem (ou cuja pasta existe); criando, usa o primeiro caminho se nenhum existir.
    private static func jsonFiles(_ paths: [String], creating: Bool) -> [URL] {
        let fm = FileManager.default
        let found = paths.map(url).filter {
            fm.fileExists(atPath: $0.path) || fm.fileExists(atPath: $0.deletingLastPathComponent().path)
        }
        if found.isEmpty, creating, let first = paths.first { return [url(first)] }
        return found
    }

    private static func readObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func setEntry(_ file: URL, key: String, _ entry: [String: Any]) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookError(String(localized: "\(file.lastPathComponent) não é um objeto JSON; não vou mexer nele."))
            }
            root = obj
        }
        var servers = root[key] as? [String: Any] ?? [:]
        servers[serverName] = entry
        root[key] = servers
        try writeJSON(root, to: file)
    }

    private static func removeEntry(_ file: URL, key: String) throws {
        guard var root = readObject(file), var servers = root[key] as? [String: Any], servers[serverName] != nil else { return }
        servers.removeValue(forKey: serverName)
        if servers.isEmpty { root.removeValue(forKey: key) } else { root[key] = servers }
        try writeJSON(root, to: file)
    }

    private static func writeJSON(_ obj: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try write(String(decoding: data, as: UTF8.self) + "\n", to: file)
    }

    // MARK: Texto (Crush, Goose, Continue)

    private static var opencodeFile: URL { url(".config/opencode/opencode.json") }
    private static var crushFile: URL { url(".config/crush/crushrc") }
    private static var gooseFile: URL { url(".config/goose/config.yaml") }
    private static var continueFile: URL { url(".continue/mcpServers/llmbo.yaml") }
    private static var crushLine: String { "mcp add \(serverName) --command \"\(executable)\" --args \"\(MCPServer.argument)\"" }
    /// Comentário na linha do nome: é por ele que o bloco do Goose é reconhecido e removido.
    private static let gooseMarker = "# LlMBO"

    private static func text(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    private static func write(_ s: String, to file: URL) throws {
        let fm = FileManager.default
        let b = file.appendingPathExtension("llmbo-backup")
        if fm.fileExists(atPath: file.path), !fm.fileExists(atPath: b.path) { try? fm.copyItem(at: file, to: b) }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func removeCrush() throws {
        let s = text(crushFile)
        guard s.contains(crushLine) else { return }
        try write(s.components(separatedBy: "\n").filter { $0 != crushLine }.joined(separator: "\n"), to: crushFile)
    }

    /// Tira o bloco do LlMBO (a linha marcada e as mais indentadas que vêm depois).
    private static func removeGoose() throws {
        let s = text(gooseFile)
        guard s.contains(gooseMarker) else { return }
        var out: [String] = []
        var skipping = false
        for line in s.components(separatedBy: "\n") {
            if line.contains(gooseMarker) && line.hasPrefix("  \(serverName):") { skipping = true; continue }
            if skipping {
                if line.hasPrefix("    ") { continue }
                skipping = false
            }
            out.append(line)
        }
        try write(out.joined(separator: "\n"), to: gooseFile)
    }
}

// MARK: - Teste

extension MCPInstall {
    /// LLMBO_TEST_MCP=1: numa home temporária com configurações "de antes" (outros servidores, hooks do Crush,
    /// extensões do Goose), instala e remove o LlMBO em todos os destinos menos o Claude Code (que usa o CLI) e
    /// confere que o que já existia continua lá. Grava mcp-test.log.
    static func selfTest() {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("llmbo-mcp-test-\(UUID().uuidString)")
        homeOverride = home
        defer { homeOverride = nil; try? fm.removeItem(at: home) }
        func put(_ path: String, _ text: String) {
            let u = home.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String { (try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        // Configurações que já existiam: nada disso pode sumir.
        put(".gemini/config/mcp_config.json", #"{"mcpServers":{"outro":{"command":"x"}}}"#)
        put(".copilot/mcp-config.json", #"{"mcpServers":{"outro":{"type":"local","command":"x","tools":["*"]}}}"#)
        put(".config/amp/settings.json", #"{"amp.theme":"dark"}"#)
        put(".config/opencode/opencode.json", #"{"$schema":"https://opencode.ai/config.json","model":"m"}"#)
        put(".config/crush/crushrc", "# LlMBO\nhook add Stop --name \"llmbo-stop\" --command \"x/LlMBO/llmbo-signal crush idle\"\n")
        put(".config/goose/config.yaml", "GOOSE_PROVIDER: openai\nextensions:\n  developer:\n    name: developer\n    type: builtin\n    enabled: true\n")
        put(".codex/config.toml", "model = \"gpt\"\n")
        put("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/.keep", "")
        put(".cursor/mcp.json", "{ // comentário\n }")   // JSON com comentário: não pode ser tocado
        var out: [String] = []
        for t in targets where t.id != "claude" {
            let before = isInstalled(t)
            var err = ""
            do { try install(t) } catch { err = " erro=\(error.localizedDescription)" }
            let on = isInstalled(t)
            try? remove(t)
            let off = isInstalled(t)
            out.append("\(t.id): antes=\(before) instalado=\(on) removido=\(!off)\(err)")
        }
        out.append("preservado gemini=\(read(".gemini/config/mcp_config.json").contains("outro"))"
                   + " copilot=\(read(".copilot/mcp-config.json").contains("outro"))"
                   + " amp=\(read(".config/amp/settings.json").contains("amp.theme"))"
                   + " opencode=\(read(".config/opencode/opencode.json").contains("\"model\""))"
                   + " crush=\(read(".config/crush/crushrc").contains("llmbo-stop"))"
                   + " goose=\(read(".config/goose/config.yaml").contains("developer") && !read(".config/goose/config.yaml").contains("# LlMBO"))"
                   + " codex=\(read(".codex/config.toml").contains("model"))"
                   + " cursor-intacto=\(read(".cursor/mcp.json").contains("comentário"))")
        // Um ciclo do Goose com o arquivo à mostra, para conferir o YAML.
        if let g = targets.first(where: { $0.id == "goose" }) {
            try? install(g)
            out.append("goose.yaml:\n" + read(".config/goose/config.yaml"))
            try? remove(g)
        }
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("mcp-test.log"), atomically: true, encoding: .utf8)
    }
}
