import AppKit

/// Servidor MCP do LlMBO (stdio, JSON-RPC uma mensagem por linha): o próprio executável rodado pelo agente
/// com `--mcp`. Dá aos agentes as ferramentas `keep_mac_awake` (segura o Mac enquanto um processo roda ou por
/// N minutos, para jobs que continuam depois do fim do turno) e `allow_sleep`. Grava em holds/ (Holds.swift);
/// quem decide segurar é o app, como para `llmbo-signal hold`.
enum MCPServer {
    static let argument = "--mcp"

    private static let tools: [[String: Any]] = [
        [
            "name": "keep_mac_awake",
            "description": "Keep the user's Mac awake (even with the lid closed) for a long-running job that will keep going after your turn ends, such as a build, test suite, render, model training or download you started in the background. Pass `pid` to hold while that process runs (preferred), or `minutes` for a fixed time. LlMBO lets the Mac sleep again on its own when the process exits or the time is up.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer", "description": "Process ID of the background job. The Mac stays awake while it runs."],
                    "minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "Keep awake for this many minutes (used when there is no pid)."],
                    "reason": ["type": "string", "description": "Short description shown to the user, e.g. \"npm run build\"."],
                ],
            ],
        ],
        [
            "name": "allow_sleep",
            "description": "Release every keep-awake request made through this tool, so the Mac can sleep normally once agents are done.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    /// Lê mensagens até o stdin fechar.
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }   // notificações (notifications/initialized…) não têm resposta
            switch method {
            case "initialize":
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "llmbo", "version": version],
                    "instructions": "LlMBO keeps this Mac awake while AI agents work and lets it sleep when they finish. If you start a job that will keep running after your turn ends, call keep_mac_awake with its pid so the Mac doesn't fall asleep in the middle of it.",
                ])
            case "ping":
                reply(id, result: [String: Any]())
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = call(params["name"] as? String ?? "", args)
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                reply(id, error: ["code": -32601, "message": "Method not found: \(method)"])
            }
        }
        exit(0)
    }

    private static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "keep_mac_awake":
            let pid = (args["pid"] as? NSNumber).map { Int32(truncating: $0) }
            let minutes = (args["minutes"] as? NSNumber)?.intValue
            let reason = (args["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let pid, !(kill(pid, 0) == 0 || errno == EPERM) {
                return ("Process \(pid) is not running; nothing to hold.", true)
            }
            guard pid != nil || (minutes ?? 0) > 0 else { return ("Pass `pid` or `minutes`.", true) }
            do {
                try Holds.write(name: reason ?? pid.map { "PID \($0)" } ?? "\(minutes!) min",
                                pid: pid, minutes: pid == nil ? minutes : nil, source: "mcp")
            } catch {
                return ("Could not save the request: \(error.localizedDescription)", true)
            }
            var text = pid.map { "The Mac will stay awake while process \($0) runs." }
                ?? "The Mac will stay awake for \(min(minutes!, 1440)) minutes."
            if !appRunning { text += " Note: the LlMBO app is not running, so nothing holds the Mac awake until it is opened." }
            return (text, false)
        case "allow_sleep":
            let n = Holds.remove(source: "mcp")
            return (n == 0 ? "There were no keep-awake requests." : "Released \(n) keep-awake request(s).", false)
        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    /// O app (não este processo, que também se chama LlMBO) está aberto.
    private static var appRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.llmbo.app").isEmpty
    }

    private static func reply(_ id: Any?, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { msg["result"] = result }
        if let error { msg["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Liga o servidor MCP nos agentes: Claude Code pelo próprio CLI (`claude mcp add --scope user`, que cuida do
/// ~/.claude.json), Codex por um bloco [mcp_servers.llmbo] no ~/.codex/config.toml. Outros: JSON para copiar.
enum MCPInstall {
    static var executable: String { Bundle.main.executablePath ?? "/Applications/LlMBO.app/Contents/MacOS/LlMBO" }
    /// Home de teste (LLMBO_TEST_MCP); nil = a do usuário.
    nonisolated(unsafe) static var homeOverride: URL?
    private static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }

    static var json: String {
        let obj: [String: Any] = ["mcpServers": ["llmbo": ["command": executable, "args": [MCPServer.argument]]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Claude Code

    /// O CLI do Claude Code: no PATH comum ou o que vem com o app Claude (pasta com a versão, que muda a cada
    /// atualização — pega a mais nova).
    static var claudeCLI: String? {
        let fm = FileManager.default
        let fixed = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { NSString(string: $0).expandingTildeInPath }
        if let p = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) { return p }
        let base = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            let vdir = base.appendingPathComponent(v)
            for sub in (try? fm.contentsOfDirectory(atPath: vdir.path)) ?? [] {
                let p = vdir.appendingPathComponent(sub).appendingPathComponent("claude.app/Contents/MacOS/claude").path
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    static var claudeInstalled: Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (obj["mcpServers"] as? [String: Any])?["llmbo"] != nil
    }

    static func installClaude() throws {
        guard let cli = claudeCLI else { throw HookError(String(localized: "Não encontrei o Claude Code neste Mac.")) }
        if claudeInstalled { run(cli, ["mcp", "remove", "--scope", "user", "llmbo"]) }
        let r = run(cli, ["mcp", "add", "--scope", "user", "llmbo", "--", executable, MCPServer.argument])
        guard r.status == 0 else { throw HookError(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func removeClaude() throws {
        guard let cli = claudeCLI else { return }
        let r = run(cli, ["mcp", "remove", "--scope", "user", "llmbo"])
        guard r.status == 0 || !claudeInstalled else { throw HookError(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Codex

    private static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    private static let codexHeader = "[mcp_servers.llmbo]"

    static var codexPresent: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) }

    static var codexInstalled: Bool {
        ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").contains(codexHeader)
    }

    static func installCodex() throws {
        try removeCodex()
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        let exe = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        text += "\n\(codexHeader)\ncommand = \"\(exe)\"\nargs = [\"\(MCPServer.argument)\"]\n"
        try backupCodex()
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// Tira o bloco [mcp_servers.llmbo] (até a próxima tabela) e nada mais.
    static func removeCodex() throws {
        guard codexInstalled, let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == codexHeader { skipping = true; continue }
            if skipping && t.hasPrefix("[") { skipping = false }
            if !skipping { out.append(line) }
        }
        while out.count > 1, out.last?.isEmpty == true, out[out.count - 2].isEmpty { out.removeLast() }
        try backupCodex()
        try out.joined(separator: "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    private static func backupCodex() throws {
        let b = codexConfig.appendingPathExtension("llmbo-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: codexConfig.path), !fm.fileExists(atPath: b.path) { try fm.copyItem(at: codexConfig, to: b) }
    }
}
