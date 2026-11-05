import Foundation
import Darwin

/// Um agente monitorado. Editável em ~/Library/Application Support/LlMBO/agents.json
struct AgentConfig: Codable, Hashable {
    /// Identificador usado pelos hooks (ex.: llmbo-signal claude busy)
    var id: String
    var name: String
    /// Nome exato do executável (o primeiro ou segundo item da linha de comando)
    var executables: [String]
    /// Trechos que, se aparecerem na linha de comando, identificam o agente
    var argsContains: [String]
    /// Trechos que, se aparecerem, descartam o processo (ex.: o `agy --hub` do IDE não é o CLI)
    var argsExcludes: [String]? = nil
    /// CPU somada (processo + filhos) acima da qual o agente conta como "trabalhando"
    var cpuThreshold: Double
    /// Pastas onde o agente grava a conversa enquanto trabalha (aceita ~). Escrita recente = atividade.
    var activityPaths: [String]?
    /// Desativado = não monitora nem aparece no popover (nil conta como ativado, para configs antigas).
    var enabled: Bool?
    /// Categoria só para organizar a lista: "codigo" ou "local".
    var kind: String?
    /// Só conta escrita em caminhos que contenham este trecho (sem diferenciar maiúsculas), ex.: "chatSessions".
    var activityFilter: String? = nil
    /// Ids de extensão (VS Code/Cursor): "presente no Mac" = extensão instalada.
    var extensionIDs: [String]? = nil
    /// false = a CPU nunca conta (extensões rodam dentro do processo da IDE, cuja CPU é de tudo).
    var useCPU: Bool? = nil
    /// GPU somada (processo + filhos) acima da qual conta como "trabalhando"; 0 = não conta.
    /// nil = padrão: 10 % para IA local (trabalha na GPU com a CPU quase parada), não conta para os outros.
    var gpuThreshold: Double? = nil

    var isEnabled: Bool { enabled ?? true }
    /// Limite de GPU em vigor, ou nil se a GPU não conta para este agente.
    var gpuLimit: Double? {
        let v = gpuThreshold ?? (isLocalAI ? 10 : 0)
        return v > 0 ? v : nil
    }
    var isLocalAI: Bool { kind == "local" }
    var isIDEExtension: Bool { kind == "ide" }
    var countsCPU: Bool { useCPU ?? true }

    /// Uma regra sem nada para procurar nunca encontraria o agente.
    var hasRule: Bool { !executables.isEmpty || !argsContains.isEmpty || !(activityPaths ?? []).isEmpty }

    func matches(_ p: ProcInfo) -> Bool {
        if let ex = argsExcludes, ex.contains(where: { p.args.contains($0) }) { return false }
        // Nome real do executável (o caminho pode ter espaços, então não dá para confiar só nos args).
        if executables.contains((p.exe as NSString).lastPathComponent) { return true }
        // Scripts de node: "node /caminho/bin/claude …"
        let tokens = p.args.split(separator: " ", maxSplits: 2)
        if tokens.count > 1, executables.contains((String(tokens[1]) as NSString).lastPathComponent) { return true }
        return argsContains.contains { p.args.contains($0) }
    }

    static let defaults: [AgentConfig] = [
        // MARK: Agentes de código
        AgentConfig(id: "claude", name: "Claude Code",
                    executables: ["claude"], argsContains: ["@anthropic-ai/claude-code"], cpuThreshold: 5,
                    activityPaths: ["~/.claude/projects"]),
        AgentConfig(id: "codex", name: "Codex",
                    executables: ["codex"], argsContains: ["@openai/codex"], cpuThreshold: 5,
                    activityPaths: ["~/.codex/sessions"]),
        // Três produtos do Antigravity. App e IDE gravam em ~/.gemini/antigravity (o IDE roda `agy --hub
        // --app_data_dir=antigravity`); por isso essa pasta só conta para quem estiver aberto (Engine).
        // Só o processo principal (Contents/MacOS); helpers, language_server e agy são filhos e entram na CPU.
        AgentConfig(id: "antigravity", name: "Antigravity",
                    executables: [], argsContains: ["Antigravity.app/Contents/MacOS/"],
                    cpuThreshold: 20,
                    activityPaths: ["~/.gemini/antigravity/brain", "~/.gemini/antigravity/conversations"]),
        AgentConfig(id: "antigravity-ide", name: "Antigravity IDE",
                    executables: [], argsContains: ["Antigravity IDE.app/Contents/MacOS/"],
                    cpuThreshold: 20,
                    activityPaths: ["~/.gemini/antigravity/brain", "~/.gemini/antigravity/conversations",
                                    "~/.gemini/antigravity-ide/brain"]),
        // O CLI é o mesmo binário `agy`, só que sem --hub (com --hub é o agente do IDE).
        AgentConfig(id: "antigravity-cli", name: "Antigravity CLI",
                    executables: ["agy"], argsContains: [], argsExcludes: ["--hub"], cpuThreshold: 5,
                    activityPaths: ["~/.gemini/antigravity-cli"]),
        AgentConfig(id: "gemini", name: "Gemini CLI",
                    executables: ["gemini"], argsContains: ["@google/gemini-cli"], cpuThreshold: 5,
                    activityPaths: ["~/.gemini/tmp"]),
        // IDEs com agente: a CPU da IDE parada é maior, por isso o limite mais alto.
        AgentConfig(id: "cursor", name: "Cursor",
                    executables: ["cursor-agent"], argsContains: ["Cursor.app/Contents/MacOS/"], cpuThreshold: 20),
        AgentConfig(id: "windsurf", name: "Windsurf",
                    executables: [], argsContains: ["Windsurf.app/Contents/MacOS/"], cpuThreshold: 20),
        AgentConfig(id: "kiro", name: "Kiro",
                    executables: [], argsContains: ["Kiro.app/Contents/MacOS/"], cpuThreshold: 20),
        AgentConfig(id: "copilot", name: "GitHub Copilot CLI",
                    executables: ["copilot"], argsContains: ["@github/copilot"], cpuThreshold: 5,
                    activityPaths: ["~/.copilot/session-state"]),
        AgentConfig(id: "opencode", name: "OpenCode",
                    executables: ["opencode"], argsContains: ["opencode-ai"], cpuThreshold: 5,
                    activityPaths: ["~/.local/share/opencode"]),
        AgentConfig(id: "aider", name: "Aider",
                    executables: ["aider"], argsContains: ["aider-chat"], cpuThreshold: 5),
        AgentConfig(id: "amp", name: "Amp",
                    executables: ["amp"], argsContains: ["@sourcegraph/amp"], cpuThreshold: 5),
        AgentConfig(id: "qwen", name: "Qwen Code",
                    executables: ["qwen"], argsContains: ["@qwen-code/qwen-code"], cpuThreshold: 5,
                    activityPaths: ["~/.qwen/tmp"]),
        AgentConfig(id: "goose", name: "Goose",
                    executables: ["goose"], argsContains: [], cpuThreshold: 5,
                    activityPaths: ["~/.local/share/goose/sessions"]),
        AgentConfig(id: "crush", name: "Crush",
                    executables: ["crush"], argsContains: [], cpuThreshold: 5),

        // MARK: Extensões de IDE — rodam dentro do VS Code/Cursor: a CPU é da IDE inteira, então não conta;
        // o sinal é o arquivo de conversa que a extensão grava enquanto trabalha (e o hook, onde houver).
        AgentConfig(id: "copilot-vscode", name: "GitHub Copilot (VS Code)",
                    executables: [], argsContains: ideApps, cpuThreshold: 15,
                    activityPaths: ["~/Library/Application Support/Code/User/workspaceStorage",
                                    "~/Library/Application Support/Code/User/globalStorage/emptyWindowChatSessions",
                                    "~/Library/Application Support/Code - Insiders/User/workspaceStorage"],
                    kind: "ide", activityFilter: "chatsessions", extensionIDs: ["github.copilot-chat"], useCPU: false),
        AgentConfig(id: "cline", name: "Cline",
                    executables: [], argsContains: ideApps, cpuThreshold: 15,
                    activityPaths: ideStorage("saoudrizwan.claude-dev/tasks"),
                    kind: "ide", extensionIDs: ["saoudrizwan.claude-dev"], useCPU: false),
        AgentConfig(id: "roo-code", name: "Roo Code",
                    executables: [], argsContains: ideApps, cpuThreshold: 15,
                    activityPaths: ideStorage("rooveterinaryinc.roo-cline/tasks"),
                    kind: "ide", extensionIDs: ["rooveterinaryinc.roo-cline"], useCPU: false),
        AgentConfig(id: "kilo-code", name: "Kilo Code",
                    executables: [], argsContains: ideApps, cpuThreshold: 15,
                    activityPaths: ideStorage("kilocode.kilo-code/tasks"),
                    kind: "ide", extensionIDs: ["kilocode.kilo-code"], useCPU: false),
        AgentConfig(id: "continue", name: "Continue",
                    executables: [], argsContains: ideApps, cpuThreshold: 15,
                    activityPaths: ["~/.continue/sessions"],
                    kind: "ide", extensionIDs: ["continue.continue"], useCPU: false),

        // MARK: IA local — gerar texto ocupa CPU/GPU do processo do modelo (o servidor parado fica quase em 0).
        AgentConfig(id: "ollama", name: "Ollama",
                    executables: ["ollama"], argsContains: ["Ollama.app/Contents/"], cpuThreshold: 15, kind: "local"),
        AgentConfig(id: "lmstudio", name: "LM Studio",
                    executables: ["lms"], argsContains: ["LM Studio.app/Contents/"], cpuThreshold: 15, kind: "local"),
        AgentConfig(id: "llamacpp", name: "llama.cpp",
                    executables: ["llama-server", "llama-cli", "llama-run"], argsContains: [], cpuThreshold: 15,
                    kind: "local"),
        AgentConfig(id: "mlx", name: "MLX",
                    executables: [], argsContains: ["mlx_lm"], cpuThreshold: 15, kind: "local"),
        AgentConfig(id: "jan", name: "Jan",
                    executables: [], argsContains: ["Jan.app/Contents/"], cpuThreshold: 15, kind: "local"),
    ]

    /// Id para hooks e arquivos de sinal a partir do nome (sem ponto: o ponto separa a sessão no arquivo).
    static func slug(_ name: String, avoiding used: Set<String>) -> String {
        let base = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        var id = base.isEmpty ? "agente" : base
        var n = 2
        while used.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// IDEs onde as extensões rodam (o processo principal; o resto é filho dele).
    static let ideApps = ["Visual Studio Code.app/Contents/MacOS/", "Visual Studio Code - Insiders.app/Contents/MacOS/",
                          "Cursor.app/Contents/MacOS/"]

    /// Pasta globalStorage de uma extensão no VS Code, no Insiders e no Cursor.
    static func ideStorage(_ sub: String) -> [String] {
        ["Code", "Code - Insiders", "Cursor"].map { "~/Library/Application Support/\($0)/User/globalStorage/\(sub)" }
    }

    /// Catálogo do botão "Adicionar agente": os pré-cadastrados.
    static var catalog: [AgentConfig] { defaults }

    /// Sinais de que o agente está instalado neste Mac: pasta de sessão, app em /Applications ou comando no PATH.
    var isPresentOnMac: Bool {
        let fm = FileManager.default
        if let ids = extensionIDs, !ids.isEmpty {
            let dirs = ["~/.vscode/extensions", "~/.vscode-insiders/extensions", "~/.cursor/extensions"]
                .map { ($0 as NSString).expandingTildeInPath }
            return dirs.contains { dir in
                let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                return names.contains { n in ids.contains { n.lowercased().hasPrefix($0.lowercased() + "-") } }
            }
        }
        let appDirs = ["/Applications", "/Applications/Setapp", ("~/Applications" as NSString).expandingTildeInPath]
        let bundles = argsContains.compactMap { arg in arg.range(of: ".app/").map { String(arg[..<$0.lowerBound]) + ".app" } }
        if !bundles.isEmpty {
            // Agente que é um app: vale o app instalado (a pasta de dados pode ser de outro, ex.: app e IDE do Antigravity).
            if bundles.contains(where: { b in appDirs.contains { fm.fileExists(atPath: "\($0)/\(b)") } }) { return true }
        } else if expandedActivityPaths.contains(where: { fm.fileExists(atPath: $0) }) {
            return true
        }
        let binDirs = ["/usr/local/bin", "/opt/homebrew/bin", "~/.local/bin", "~/.gemini/bin", "~/.bun/bin", "~/.npm-global/bin",
                       "~/.volta/bin", "~/.cargo/bin", "~/go/bin"].map { ($0 as NSString).expandingTildeInPath }
        return executables.contains { e in binDirs.contains { fm.isExecutableFile(atPath: "\($0)/\(e)") } }
    }

    /// Caminhos de atividade já expandidos (sem ~).
    var expandedActivityPaths: [String] {
        (activityPaths ?? []).map { ($0 as NSString).expandingTildeInPath }
    }
}

enum AgentStore {
    /// Marca a limpeza única da versão em que o catálogo saiu da lista (antes, todos os padrões entravam nela).
    private static let catalogKey = "agentsCatalogV2"

    static func load() -> [AgentConfig] {
        let d = UserDefaults.standard
        defer { d.set(true, forKey: catalogKey) }
        if let data = try? Data(contentsOf: Paths.agentsFile),
           let list = try? JSONDecoder().decode([AgentConfig].self, from: data) {
            var migrated = splitAntigravity(migrate(list))
            if !d.bool(forKey: catalogKey) { migrated = keepInUse(migrated) }
            if migrated != list { save(migrated) }
            return migrated
        }
        // Instalação nova: começa com os agentes encontrados neste Mac.
        let initial = AgentConfig.catalog.filter(\.isPresentOnMac)
        save(initial)
        return initial
    }

    /// Fica na lista o que está em uso: personalizados, editados, presentes no Mac ou rodando agora.
    /// O resto volta para o catálogo (menu "Adicionar agente").
    static func keepInUse(_ list: [AgentConfig]) -> [AgentConfig] {
        let procs = processSnapshot()
        return list.filter { a in
            guard let d = AgentConfig.catalog.first(where: { $0.id == a.id }) else { return true }
            var plain = a
            plain.enabled = nil
            return plain != d || a.isPresentOnMac || procs.contains(where: a.matches)
        }
    }

    /// Versões anteriores tinham um "Antigravity" só, que pegava o app e o IDE. Agora são três agentes:
    /// a entrada antiga vira o app, e o IDE/CLI entram se estiverem neste Mac.
    static func splitAntigravity(_ list: [AgentConfig]) -> [AgentConfig] {
        guard let i = list.firstIndex(where: { $0.id == "antigravity" }),
              list[i].argsContains.contains("Antigravity IDE.app/Contents/MacOS/") else { return list }
        var out = list
        let enabled = out[i].enabled
        let app = AgentConfig.catalog.first { $0.id == "antigravity" }!
        out[i] = app
        out[i].enabled = enabled
        for id in ["antigravity-ide", "antigravity-cli"] where !out.contains(where: { $0.id == id }) {
            if let c = AgentConfig.catalog.first(where: { $0.id == id }), c.isPresentOnMac { out.insert(c, at: i + 1) }
        }
        // O app comum só fica se estiver instalado (antes ele vinha junto com o IDE).
        if !app.isPresentOnMac { out.remove(at: i) }
        return out
    }

    /// Completa configs antigas com o que surgiu depois, sem desfazer edições do usuário.
    static func migrate(_ list: [AgentConfig]) -> [AgentConfig] {
        list.map { a in
            guard let d = AgentConfig.defaults.first(where: { $0.id == a.id }) else { return a }
            var m = a
            if m.activityPaths == nil { m.activityPaths = d.activityPaths }
            if m.kind == nil { m.kind = d.kind }
            if m.activityFilter == nil { m.activityFilter = d.activityFilter }
            if m.extensionIDs == nil { m.extensionIDs = d.extensionIDs }
            if m.useCPU == nil { m.useCPU = d.useCPU }
            // Regra antiga do Antigravity só acertava por acaso (o caminho tem espaço).
            if m.id == "antigravity" {
                m.executables.removeAll { $0 == "Antigravity" }
                m.argsContains.removeAll { $0 == "Antigravity.app" }
            }
            if m.argsExcludes == nil { m.argsExcludes = d.argsExcludes }
            // Antigravity: a regra antiga juntava app e IDE; splitAntigravity cuida disso.
            if m.id != "antigravity" {
                for x in d.argsContains where !m.argsContains.contains(x) { m.argsContains.append(x) }
            }
            return m
        }
    }

    static func save(_ list: [AgentConfig]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: Paths.agentsFile) }
    }
}

// MARK: - Processos

struct ProcInfo {
    let pid: Int32
    let ppid: Int32
    let cpu: Double
    let args: String
    /// Caminho real do executável (proc_pidpath); vazio se não der para ler.
    let exe: String
}

private func executablePath(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

private let psRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(\d+)\s+([\d.,]+)\s+(.*)$"#)

func processSnapshot() -> [ProcInfo] {
    let out = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,pcpu=,args="]).output
    var result: [ProcInfo] = []
    for line in out.split(separator: "\n") {
        let s = String(line)
        let ns = s as NSString
        guard let m = psRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let pid = Int32(ns.substring(with: m.range(at: 1))),
              let ppid = Int32(ns.substring(with: m.range(at: 2))),
              let cpu = Double(ns.substring(with: m.range(at: 3)).replacingOccurrences(of: ",", with: "."))
        else { continue }
        result.append(ProcInfo(pid: pid, ppid: ppid, cpu: cpu, args: ns.substring(with: m.range(at: 4)),
                               exe: executablePath(pid)))
    }
    return result
}

// MARK: - Sinais dos hooks

struct HookSignal {
    let agent: String
    let busy: Bool
    /// Parado pedindo sua aprovação (Claude Code: Notification "permission_prompt").
    var waiting = false
    /// Bateu no limite de uso e espera o reset para continuar sozinho (Claude Code: StopFailure "rate_limit").
    var quota = false
    let time: Date
}

/// Lê os arquivos escritos pelo llmbo-signal. Nome do arquivo: "<agente>" ou "<agente>.<sessão>".
func readSignals(now: Date) -> [HookSignal] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: Paths.signals, includingPropertiesForKeys: nil) else { return [] }
    var result: [HookSignal] = []
    for url in files where !url.lastPathComponent.hasPrefix(".") {   // ".nome.pid" = sendo gravado pelo script
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let ts = TimeInterval(parts[1]) else { continue }
        let time = Date(timeIntervalSince1970: ts)
        if now.timeIntervalSince(time) > 24 * 3600 {   // limpa sessões antigas
            try? fm.removeItem(at: url)
            continue
        }
        let agent = String(url.lastPathComponent.split(separator: ".").first ?? "")
        result.append(HookSignal(agent: agent, busy: parts[0] == "busy", waiting: parts[0] == "waiting",
                                 quota: parts[0] == "quota", time: time))
    }
    return result
}
