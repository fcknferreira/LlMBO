import Foundation

/// Instala/remove os hooks que avisam o LlMBO quando um agente começa e termina.
/// Só acrescenta entradas próprias (reconhecidas pelo caminho do llmbo-signal); nunca mexe nas dos outros.
enum Hooks {
    enum State: Equatable {
        case installed
        case notInstalled
        /// Já existe outra configuração no lugar (ex.: `notify` do Codex usado por outro app).
        case conflict(String)
        /// Agente sem suporte a hooks aqui; depende de arquivos de sessão e CPU.
        case unsupported
    }

    /// Windsurf fica de fora: virou Devin Desktop e o formato antigo (~/.codeium/windsurf/hooks.json) não tem
    /// documentação confiável hoje.
    static let supported: Set<String> = Set(["claude", "codex", "qwen", "gemini", "cursor", "opencode", "aider", "crush"])
        .union(antigravityFamily).union(copilotFamily)

    /// App, IDE e CLI do Antigravity leem o mesmo ~/.gemini/config/hooks.json: um hook só (`auto`), e o
    /// llmbo-signal descobre pela árvore de processos qual dos três chamou.
    static let antigravityFamily: Set<String> = ["antigravity", "antigravity-ide", "antigravity-cli"]

    /// Copilot CLI e Copilot do VS Code leem o mesmo ~/.copilot/hooks/ (code.visualstudio.com/docs/copilot/customization/hooks,
    /// em prévia): um arquivo só, e o llmbo-signal manda para "copilot-vscode" quando o VS Code está acima.
    static let copilotFamily: Set<String> = ["copilot", "copilot-vscode"]

    /// Chave do arquivo de hook: agentes da mesma família dividem um hook só.
    static func familyKey(_ agent: String) -> String {
        if antigravityFamily.contains(agent) { return "antigravity" }
        if copilotFamily.contains(agent) { return "copilot" }
        return agent
    }

    /// Agentes que dividem o mesmo arquivo de hook que `agent` (inclusive ele): só desliga quando o último sai.
    static func sharingFile(_ agent: String) -> Set<String> {
        if antigravityFamily.contains(agent) { return antigravityFamily }
        if copilotFamily.contains(agent) { return copilotFamily }
        return [agent]
    }

    /// Nome para a linha do hook: os três Antigravity aparecem juntos, porque o hook é um só.
    static func displayName(_ agent: String, fallback: String) -> String {
        if antigravityFamily.contains(agent) { return String(localized: "Antigravity (Standard, IDE e CLI)") }
        if copilotFamily.contains(agent) { return String(localized: "GitHub Copilot (CLI e VS Code)") }
        return fallback
    }

    /// Ids repetidos de um mesmo hook viram um só (mantém a ordem).
    static func uniqueHooks(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            seen.insert(familyKey(id)).inserted
        }
    }

    /// Hooks que avisam começo E fim: com eles instalados (e já vistos funcionando), só o hook decide.
    /// O OpenCode e o Aider ficam de fora: o OpenCode tem começo aproximado, e o Aider só avisa o fim (idle).
    static let fullLifecycle: Set<String> = Set(["claude", "codex", "qwen", "gemini", "cursor", "crush"])
        .union(antigravityFamily).union(copilotFamily)

    /// Observação mostrada na linha do hook, quando o agente pede um passo a mais.
    static func note(_ agent: String) -> String? {
        switch agent {
        case "codex": return String(localized: "No Codex, aprove uma vez com /hooks.")
        case "aider": return String(localized: "O Aider avisa quando termina; o início é pela CPU.")
        case "copilot", "copilot-vscode": return String(localized: "No VS Code, os hooks ainda estão em prévia.")
        default: return nil
        }
    }

    /// O hook avisa quando o agente para pedindo aprovação ("Esperar acordado por aprovações")?
    enum ApprovalSupport { case yes, partial, no }

    /// Claude Code e Qwen Code: Notification "permission_prompt"; Codex: PermissionRequest; Gemini CLI:
    /// Notification "ToolPermission"; OpenCode: evento permission.asked. Antigravity: ferramentas
    /// ask_permission e ask_question (acesso a recursos ou perguntas ao usuário), não a aprovação de comandos no terminal. Copilot CLI: o
    /// permissionRequest dispara antes das regras, em toda ferramenta, então não diz se vai perguntar.
    /// Cursor, Crush e Aider não têm evento para isso.
    static func approvalSupport(_ agent: String) -> ApprovalSupport {
        switch agent {
        case "claude", "qwen", "codex", "gemini", "opencode": return .yes
        case _ where antigravityFamily.contains(agent): return .partial
        default: return .no
        }
    }

    /// Hooks instalados por versões anteriores do LlMBO, sem os eventos novos (ex.: pedido de aprovação):
    /// reinstala ao abrir, para não aparecerem como "Não instalados".
    static func upgradeOutdated(home: URL = realHome) {
        for (agent, spec) in settingsHooks where settingsHasOurs(spec, home) && !settingsInstalled(spec, home) {
            if agent == "codex" { try? removeCodexNotify(home) }
            try? installSettings(spec, home)
        }
        if opencodeInstalled(home) && !opencodeCurrent(home) { try? installOpenCode(home) }
    }

    /// LLMBO_TEST_HOOKS=1: numa pasta temporária, instala os hooks de aprovação, simula uma instalação de
    /// versão anterior (sem o evento novo) e confere se `upgradeOutdated` a atualiza. Grava hooks-test.log.
    static func selfTest() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("llmbo-hooks-test-\(UUID().uuidString)")
        var out: [String] = []
        let older: [String: String] = ["qwen": "Notification", "codex": "PermissionRequest", "gemini": "AfterTool"]
        for (agent, event) in older {
            install(agent, home: home)
            let fresh = state(agent, home: home)
            let spec = settingsHooks[agent]!
            var root = (try? readJSON(spec.file(home))) ?? [:]
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            hooks.removeValue(forKey: event)
            root["hooks"] = hooks
            try? writeJSON(root, to: spec.file(home))
            let old = state(agent, home: home)
            upgradeOutdated(home: home)
            let text = (try? String(contentsOf: spec.file(home), encoding: .utf8)) ?? ""
            out.append("\(agent): nova=\(fresh) antiga=\(old) depois=\(state(agent, home: home)) evento \(event)=\(text.contains(event))")
        }
        try? FileManager.default.createDirectory(at: opencodeFile(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "// \(marker) versão antiga".write(to: opencodeFile(home), atomically: true, encoding: .utf8)
        let before = opencodeCurrent(home)
        upgradeOutdated(home: home)
        out.append("opencode: atual antes=\(before) depois=\(opencodeCurrent(home)) instalado=\(state("opencode", home: home))")
        try? FileManager.default.removeItem(at: home)
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("hooks-test.log"), atomically: true, encoding: .utf8)
    }

    /// Agentes que usam o mesmo hook que `agent` (inclusive ele).
    static func sharedWith(_ agent: String) -> Set<String> {
        antigravityFamily.contains(agent) ? antigravityFamily : [agent]
    }

    fileprivate static let marker = "LlMBO/llmbo-signal"
    fileprivate static var signal: String { Paths.signalScript.path }

    // MARK: Interface

    static func state(_ agent: String, home: URL = realHome) -> State {
        switch agent {
        case _ where settingsHooks[agent] != nil:
            return settingsInstalled(settingsHooks[agent]!, home) ? .installed : .notInstalled
        case "opencode": return opencodeInstalled(home) ? .installed : .notInstalled
        case _ where antigravityFamily.contains(agent): return antigravityInstalled(home) ? .installed : .notInstalled
        case "copilot", "copilot-vscode": return copilotInstalled(home) ? .installed : .notInstalled
        case "cursor": return cursorInstalled(home) ? .installed : .notInstalled
        case "aider": return aiderState(home)
        case "crush": return crushInstalled(home) ? .installed : .notInstalled
        default: return .unsupported
        }
    }

    @discardableResult
    static func install(_ agent: String, home: URL = realHome) -> Result<Void, Error> {
        Result {
            switch agent {
            case _ where settingsHooks[agent] != nil:
                if agent == "codex" { try removeCodexNotify(home) }
                try installSettings(settingsHooks[agent]!, home)
            case "opencode": try installOpenCode(home)
            case _ where antigravityFamily.contains(agent): try installAntigravity(home)
            case "copilot", "copilot-vscode": try installCopilot(home)
            case "cursor": try installCursor(home)
            case "aider": try installAider(home)
            case "crush": try installCrush(home)
            default: break
            }
        }
    }

    @discardableResult
    static func uninstall(_ agent: String, home: URL = realHome) -> Result<Void, Error> {
        Result {
            switch agent {
            case _ where settingsHooks[agent] != nil:
                if agent == "codex" { try removeCodexNotify(home) }
                try uninstallSettings(settingsHooks[agent]!, home)
            case "opencode": try uninstallOpenCode(home)
            case _ where antigravityFamily.contains(agent): try uninstallAntigravity(home)
            case "copilot", "copilot-vscode": try uninstallCopilot(home)
            case "cursor": try uninstallCursor(home)
            case "aider": try uninstallAider(home)
            case "crush": try uninstallCrush(home)
            default: break
            }
        }
    }

    static var realHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Remove a entrada "llmbo-gemini" que versões anteriores gravavam no hooks.json do Antigravity.
    static func cleanUpLegacy(home: URL = realHome) {
        let url = geminiSettings(home)
        guard var root = try? readJSON(url), root["llmbo-gemini"] != nil else { return }
        root.removeValue(forKey: "llmbo-gemini")
        backup(url)
        try? writeJSON(root, to: url)
    }

    // MARK: Formato do Claude Code: {"hooks": {Evento: [{matcher?, hooks: [{type, command}]}]}}
    // Vale para Claude Code, Codex (~/.codex/hooks.json), Qwen Code e Gemini CLI: muda só o arquivo,
    // os eventos e o que o script imprime no stdout ("silent" = nada, "json" = {}, vazio = {} como sempre foi).

    fileprivate struct SettingsHook {
        typealias Event = (event: String, state: String, kind: String, matcher: Bool)
        let agent: String
        let path: String   // relativo à home
        let events: [Event]

        func file(_ home: URL) -> URL { home.appendingPathComponent(path) }
        func command(_ e: Event) -> String {
            "\"\(Hooks.signal)\" \(agent) \(e.state) --stdin" + (e.kind.isEmpty ? "" : " \(e.kind)")
        }
    }

    fileprivate static let settingsHooks: [String: SettingsHook] = [
        // Ferramentas = batimento num turno longo; Notification = parado esperando você → livre.
        "claude": SettingsHook(agent: "claude", path: ".claude/settings.json", events: [
            ("UserPromptSubmit", "busy", "", false), ("PreToolUse", "busy", "", true),
            ("PostToolUse", "busy", "", true), ("Stop", "idle", "", false),
            ("Notification", "idle", "", false), ("SessionEnd", "idle", "", false),
            // Limite de uso: o script grava "quota" (StopFailure "rate_limit"); outros erros da API = parado.
            ("StopFailure", "idle", "", false)]),
        // Codex: texto no UserPromptSubmit vira contexto do modelo (fica mudo); o Stop exige JSON.
        // O Codex só roda hook novo depois que o usuário aprova em /hooks.
        // PermissionRequest só dispara quando o Codex vai pedir aprovação; mudo = segue para o pedido normal.
        "codex": SettingsHook(agent: "codex", path: ".codex/hooks.json", events: [
            ("UserPromptSubmit", "busy", "silent", false), ("PostToolUse", "busy", "silent", false),
            ("PermissionRequest", "waiting", "silent", false),
            ("Stop", "idle", "json", false), ("SessionEnd", "idle", "silent", false)]),
        // Qwen Code: qualquer texto no stdout vai para o modelo, então tudo mudo. A Notification traz
        // notification_type como no Claude Code (permission_prompt → o script grava "waiting").
        "qwen": SettingsHook(agent: "qwen", path: ".qwen/settings.json", events: [
            ("UserPromptSubmit", "busy", "silent", false), ("PostToolUse", "busy", "silent", false),
            ("Notification", "idle", "silent", false),
            ("Stop", "idle", "silent", false), ("SessionEnd", "idle", "silent", false)]),
        // Gemini CLI: stdout só pode ter JSON. O script confere a árvore de processos para não confundir com
        // o Antigravity CLI, que divide a pasta ~/.gemini. Notification "ToolPermission" = pedindo aprovação;
        // AfterTool marca a volta ao trabalho depois da resposta.
        "gemini": SettingsHook(agent: "gemini", path: ".gemini/settings.json", events: [
            ("BeforeAgent", "busy", "json", false), ("AfterTool", "busy", "json", false),
            ("Notification", "idle", "json", false), ("AfterAgent", "idle", "json", false),
            ("SessionEnd", "idle", "json", false)]),
    ]

    fileprivate static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError(String(localized: "\(url.lastPathComponent) não é um objeto JSON; não vou mexer nele."))
        }
        return obj
    }

    fileprivate static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Guarda uma cópia do arquivo original antes da primeira alteração.
    fileprivate static func backup(_ url: URL) {
        let b = url.appendingPathExtension("llmbo-backup")
        if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: b.path) {
            try? FileManager.default.copyItem(at: url, to: b)
        }
    }

    private static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    /// Alguma entrada do LlMBO no arquivo (mesmo que de uma versão antiga, com menos eventos).
    private static func settingsHasOurs(_ spec: SettingsHook, _ home: URL) -> Bool {
        guard let hooks = (try? readJSON(spec.file(home)))?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { ($0["hooks"] as? [Any] ?? []).contains(where: isOurs) }
        }
    }

    private static func settingsInstalled(_ spec: SettingsHook, _ home: URL) -> Bool {
        guard let hooks = (try? readJSON(spec.file(home)))?["hooks"] as? [String: Any] else { return false }
        return spec.events.allSatisfy { e in
            (hooks[e.event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [Any] ?? []).contains(where: isOurs)
            }
        }
    }

    private static func installSettings(_ spec: SettingsHook, _ home: URL) throws {
        try uninstallSettings(spec, home)   // começa limpo: evita entradas duplicadas
        let url = spec.file(home)
        var root = try readJSON(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for e in spec.events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": spec.command(e)]]]
            if e.matcher { group["matcher"] = "*" }
            hooks[e.event] = (hooks[e.event] as? [Any] ?? []) + [group]
        }
        root["hooks"] = hooks
        backup(url)
        try writeJSON(root, to: url)
    }

    private static func uninstallSettings(_ spec: SettingsHook, _ home: URL) throws {
        let url = spec.file(home)
        var root = try readJSON(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var g in groups {
                let list = g["hooks"] as? [Any] ?? []
                let filtered = list.filter { !isOurs($0) }
                if filtered.count != list.count { changed = true }
                if filtered.isEmpty && !list.isEmpty { continue }
                g["hooks"] = filtered
                kept.append(g)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard changed else { return }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        backup(url)
        // Arquivo que só existia por causa do LlMBO (ex.: ~/.codex/hooks.json) some junto.
        if root.isEmpty { try FileManager.default.removeItem(at: url) } else { try writeJSON(root, to: url) }
    }

    // MARK: Codex: `notify` antigo (~/.codex/config.toml)
    // Versões anteriores usavam o `notify`, que só avisa o fim do turno. Agora o Codex usa hooks.json;
    // a linha antiga do LlMBO é removida ao instalar ou remover.

    private static func removeCodexNotify(_ home: URL) throws {
        let url = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("notify") && l.contains(marker))
        }
        guard kept.count != lines.count else { return }
        backup(url)
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Antigravity (~/.gemini/config/hooks.json)

    private static func geminiSettings(_ home: URL) -> URL {
        home.appendingPathComponent(".gemini/config/hooks.json")
    }

    /// Entrada única "llmbo" com `auto`; o script resolve antigravity / antigravity-ide / antigravity-cli.
    private static var antigravityEvents: [String: Any] {
        let cmd = { (state: String, kind: String) in "\"\(signal)\" auto \(state) --stdin \(kind)" }
        return [
            "PreInvocation": [["type": "command", "command": cmd("busy", "pre-invocation")]],
            "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": cmd("busy", "pre-tool")]]]],
            "PostToolUse": [["matcher": "*", "hooks": [["type": "command", "command": cmd("busy", "post-tool")]]]],
            "Stop": [["type": "command", "command": cmd("idle", "stop")]],
        ]
    }

    /// Chaves que versões anteriores usavam (uma por agente).
    private static let legacyAntigravityKeys = ["llmbo-antigravity", "llmbo-gemini"]

    private static func antigravityInstalled(_ home: URL) -> Bool {
        guard let entry = (try? readJSON(geminiSettings(home)))?["llmbo"] as? [String: Any] else { return false }
        return ["PreInvocation", "PreToolUse", "PostToolUse", "Stop"].allSatisfy { event in
            (entry[event] as? [[String: Any]] ?? []).contains { h in
                isOurs(h) || ((h["hooks"] as? [Any])?.contains(where: isOurs) ?? false)
            }
        }
    }

    private static func installAntigravity(_ home: URL) throws {
        let url = geminiSettings(home)
        var root = (try? readJSON(url)) ?? [:]
        for k in legacyAntigravityKeys { root.removeValue(forKey: k) }
        root["llmbo"] = antigravityEvents
        backup(url)
        try writeJSON(root, to: url)
    }

    private static func uninstallAntigravity(_ home: URL) throws {
        let url = geminiSettings(home)
        var root = (try? readJSON(url)) ?? [:]
        let keys = ["llmbo"] + legacyAntigravityKeys
        guard keys.contains(where: { root[$0] != nil }) else { return }
        for k in keys { root.removeValue(forKey: k) }
        backup(url)
        if root.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try writeJSON(root, to: url)
        }
    }
}

// MARK: - GitHub Copilot CLI (~/.copilot/hooks/llmbo.json, arquivo só do LlMBO)
// Formato: docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference

extension Hooks {
    private static func copilotFile(_ home: URL) -> URL {
        home.appendingPathComponent(".copilot/hooks/llmbo.json")
    }

    /// agentStop = o agente principal terminou o turno. Saída vazia é válida; o script devolve {}.
    private static let copilotEvents: [(event: String, state: String)] = [
        ("userPromptSubmitted", "busy"),
        ("postToolUse", "busy"),
        ("agentStop", "idle"),
        ("sessionEnd", "idle"),
    ]

    fileprivate static func copilotInstalled(_ home: URL) -> Bool {
        guard let hooks = (try? readJSON(copilotFile(home)))?["hooks"] as? [String: Any] else { return false }
        return copilotEvents.allSatisfy { e in
            (hooks[e.event] as? [[String: Any]] ?? []).contains { ($0["bash"] as? String)?.contains(marker) ?? false }
        }
    }

    fileprivate static func installCopilot(_ home: URL) throws {
        var hooks: [String: Any] = [:]
        for e in copilotEvents {
            hooks[e.event] = [["type": "command",
                               "bash": "\"\(signal)\" copilot \(e.state) --stdin json",
                               "timeoutSec": 10]]
        }
        try writeJSON(["version": 1, "hooks": hooks], to: copilotFile(home))
    }

    fileprivate static func uninstallCopilot(_ home: URL) throws {
        let url = copilotFile(home)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Cursor (~/.cursor/hooks.json, dividido com outros hooks do usuário)
// Formato: cursor.com/docs/agent/hooks

extension Hooks {
    private static func cursorFile(_ home: URL) -> URL {
        home.appendingPathComponent(".cursor/hooks.json")
    }

    /// beforeSubmitPrompt precisa responder {"continue": true}, senão o Cursor bloqueia o prompt.
    private static let cursorEvents: [(event: String, state: String, kind: String)] = [
        ("beforeSubmitPrompt", "busy", "continue"),
        ("postToolUse", "busy", "json"),
        ("stop", "idle", "json"),
        ("sessionEnd", "idle", "json"),
    ]

    private static func isOursCursor(_ h: Any) -> Bool {
        ((h as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    fileprivate static func cursorInstalled(_ home: URL) -> Bool {
        guard let hooks = (try? readJSON(cursorFile(home)))?["hooks"] as? [String: Any] else { return false }
        return cursorEvents.allSatisfy { e in (hooks[e.event] as? [Any] ?? []).contains(where: isOursCursor) }
    }

    fileprivate static func installCursor(_ home: URL) throws {
        try uninstallCursor(home)   // começa limpo: evita duplicar
        let url = cursorFile(home)
        var root = try readJSON(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for e in cursorEvents {
            hooks[e.event] = (hooks[e.event] as? [Any] ?? []) +
                [["command": "\"\(signal)\" cursor \(e.state) --stdin \(e.kind)", "timeout": 10]]
        }
        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
        backup(url)
        try writeJSON(root, to: url)
    }

    fileprivate static func uninstallCursor(_ home: URL) throws {
        let url = cursorFile(home)
        var root = try readJSON(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            let kept = list.filter { !isOursCursor($0) }
            if kept.count != list.count { changed = true }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard changed else { return }
        root["hooks"] = hooks
        backup(url)
        // Se só sobrou o esqueleto que o próprio LlMBO criou, apaga o arquivo.
        if hooks.isEmpty && root.keys.allSatisfy({ $0 == "version" || $0 == "hooks" }) {
            try FileManager.default.removeItem(at: url)
        } else {
            try writeJSON(root, to: url)
        }
    }
}

// MARK: - OpenCode (~/.config/opencode/plugins/llmbo.js, arquivo só do LlMBO)
// Formato: opencode.ai/docs/plugins. Fim: evento session.idle. Começo: ferramentas e mensagens novas.

extension Hooks {
    private static func opencodeFile(_ home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/plugins/llmbo.js")
    }

    fileprivate static func opencodeInstalled(_ home: URL) -> Bool {
        ((try? String(contentsOf: opencodeFile(home), encoding: .utf8)) ?? "").contains(marker)
    }

    /// Versão atual do plugin (com os eventos de aprovação).
    fileprivate static func opencodeCurrent(_ home: URL) -> Bool {
        ((try? String(contentsOf: opencodeFile(home), encoding: .utf8)) ?? "").contains("permission.asked")
    }

    fileprivate static func installOpenCode(_ home: URL) throws {
        let js = """
        // LlMBO: avisa quando o OpenCode trabalha e quando termina. Instalado pelo LlMBO; remova pelo app.
        const SIGNAL = \(String(reflecting: signal))
        export const LlMBO = async ({ $ }) => {
          const send = (state, id) => $`${SIGNAL} opencode ${state} --session ${id ?? ""}`.quiet().nothrow()
          const sid = (p) => p?.sessionID ?? p?.info?.sessionID ?? p?.part?.sessionID
          return {
            event: async ({ event }) => {
              const p = event.properties
              if (event.type === "session.idle") await send("idle", sid(p))
              // Pedindo aprovação (permission.updated é o nome antigo) e respondido.
              else if (event.type === "permission.asked" || event.type === "permission.updated") await send("waiting", sid(p))
              else if (event.type === "permission.replied") await send("busy", sid(p))
              else if (event.type === "session.status" && p?.status?.type === "busy") await send("busy", sid(p))
              else if (event.type === "message.updated" && p?.info?.role === "user") await send("busy", sid(p))
            },
            "tool.execute.before": async (input) => { await send("busy", input?.sessionID) },
          }
        }

        """
        try FileManager.default.createDirectory(at: opencodeFile(home).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try js.write(to: opencodeFile(home), atomically: true, encoding: .utf8)
    }

    fileprivate static func uninstallOpenCode(_ home: URL) throws {
        let url = opencodeFile(home)
        if opencodeInstalled(home) { try FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Aider (~/.aider.conf.yml, chave `notifications-command`)
// O Aider dispara o comando configurado quando o modelo termina de responder (idle). O início é pela CPU.

extension Hooks {
    private static func aiderConfig(_ home: URL) -> URL {
        home.appendingPathComponent(".aider.conf.yml")
    }

    fileprivate static func aiderState(_ home: URL) -> State {
        guard let text = try? String(contentsOf: aiderConfig(home), encoding: .utf8) else { return .notInstalled }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("notifications-command:") {
                return t.contains(marker) ? .installed : .conflict(String(localized: "O Aider já usa outro comando de notificação."))
            }
        }
        return .notInstalled
    }

    fileprivate static func installAider(_ home: URL) throws {
        switch aiderState(home) {
        case .installed: return
        case .conflict(let why): throw HookError(why)
        default: break
        }
        let url = aiderConfig(home)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        backup(url)

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var foundNotifications = false
        for i in 0..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("notifications:") {
                lines[i] = "notifications: true"
                foundNotifications = true
                break
            }
        }
        if !foundNotifications {
            lines.append("notifications: true")
        }
        lines.append("notifications-command: \"\\\"\(signal)\\\" aider idle\"  # LlMBO")

        let newText = lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try newText.write(to: url, atomically: true, encoding: .utf8)
    }

    fileprivate static func uninstallAider(_ home: URL) throws {
        let url = aiderConfig(home)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard text.contains(marker) else { return }
        backup(url)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        for line in lines {
            if line.contains(marker) { continue }
            kept.append(line)
        }
        let cleaned = kept.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if cleaned.isEmpty || cleaned == ["notifications: true"] {
            try? FileManager.default.removeItem(at: url)
        } else {
            try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Crush (~/.config/crush/crushrc)
// Sintaxe Bash nativa do Crush com comandos built-in `hook add`.

extension Hooks {
    private static func crushFile(_ home: URL) -> URL {
        home.appendingPathComponent(".config/crush/crushrc")
    }

    fileprivate static func crushInstalled(_ home: URL) -> Bool {
        guard let text = try? String(contentsOf: crushFile(home), encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    fileprivate static func installCrush(_ home: URL) throws {
        try uninstallCrush(home)
        let url = crushFile(home)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        backup(url)

        let hooksCode = """
        # LlMBO
        hook add UserPromptSubmit --name "llmbo-start" --command "\(signal) crush busy --stdin"
        hook add PreToolUse --name "llmbo-pre-tool" --command "\(signal) crush busy --stdin pre-tool"
        hook add PostToolUse --name "llmbo-post-tool" --command "\(signal) crush busy --stdin post-tool"
        hook add Stop --name "llmbo-stop" --command "\(signal) crush idle --stdin stop"

        """
        let newContent = text.isEmpty ? hooksCode : (text.hasSuffix("\n") ? text + hooksCode : text + "\n" + hooksCode)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    fileprivate static func uninstallCrush(_ home: URL) throws {
        let url = crushFile(home)
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) else { return }
        backup(url)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var skipComment = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "# LlMBO" {
                skipComment = true
                continue
            }
            if line.contains(marker) {
                skipComment = false
                continue
            }
            if skipComment {
                skipComment = false
                kept.append("# LlMBO")
            }
            kept.append(line)
        }
        let cleaned = kept.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct HookError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Barra de status do Claude Code (limites de uso)

/// O Claude Code só entrega os limites de uso (5 horas e semanal, com a hora do reset) para o comando da barra
/// de status. Ligado na aba Uso, o LlMBO põe `llmbo-signal statusline` como barra: ele guarda os dados e repassa
/// para a barra que o usuário já tinha (guardada em statusline-previous.json; o comando em statusline-chain).
/// Desligar devolve a barra anterior.
extension Hooks {
    static let statusLinePrevious = Paths.support.appendingPathComponent("statusline-previous.json")
    static let statusLineChain = Paths.support.appendingPathComponent("statusline-chain")
    private static var claudeSettings: URL { realHome.appendingPathComponent(".claude/settings.json") }

    static var statusLineInstalled: Bool {
        let cmd = ((try? readJSON(claudeSettings))?["statusLine"] as? [String: Any])?["command"] as? String
        return cmd?.contains(marker) ?? false
    }

    static func installStatusLine() throws {
        guard !statusLineInstalled else { return }
        let url = claudeSettings
        var root = try readJSON(url)
        let previous = root["statusLine"] as? [String: Any]
        let fm = FileManager.default
        try? fm.removeItem(at: statusLinePrevious)
        try? fm.removeItem(at: statusLineChain)
        if let previous {
            try JSONSerialization.data(withJSONObject: previous).write(to: statusLinePrevious)
            if let cmd = previous["command"] as? String { try cmd.write(to: statusLineChain, atomically: true, encoding: .utf8) }
        }
        var ours = previous ?? [:]   // mantém padding, refreshInterval etc. da barra anterior
        ours["type"] = "command"
        ours["command"] = "\"\(signal)\" statusline"
        root["statusLine"] = ours
        backup(url)
        try writeJSON(root, to: url)
    }

    static func removeStatusLine() throws {
        guard statusLineInstalled else { return }
        let url = claudeSettings
        var root = try readJSON(url)
        if let data = try? Data(contentsOf: statusLinePrevious),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root["statusLine"] = previous
        } else {
            root.removeValue(forKey: "statusLine")
        }
        backup(url)
        try writeJSON(root, to: url)
        try? FileManager.default.removeItem(at: statusLinePrevious)
        try? FileManager.default.removeItem(at: statusLineChain)
    }
}
