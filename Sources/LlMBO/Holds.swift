import Foundation

/// Tarefa longa que segura o Mac acordado mesmo sem agente trabalhando (build, render, download…).
/// Criada por `llmbo-signal hold` (terminal) ou pela ferramenta `keep_mac_awake` do servidor MCP.
/// Cada uma é um arquivo JSON em holds/: vale enquanto o processo existir (pid) ou até o prazo (until).
struct HoldTask: Identifiable, Equatable {
    let id: String
    let name: String
    let pid: Int32?
    let until: Date?
    /// "cli" ou "mcp".
    let source: String

    var isAlive: Bool {
        if let pid { return kill(pid, 0) == 0 || errno == EPERM }
        if let until { return until > Date() }
        return false
    }
}

enum Holds {
    static let dir = Paths.support.appendingPathComponent("holds")

    /// Tarefas válidas; as que acabaram (processo morto, prazo vencido) são apagadas.
    static func read() -> [HoldTask] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [HoldTask] = []
        for url in files where !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? fm.removeItem(at: url)
                continue
            }
            let task = HoldTask(id: url.lastPathComponent,
                                name: obj["name"] as? String ?? url.lastPathComponent,
                                pid: (obj["pid"] as? NSNumber).map { Int32(truncating: $0) },
                                until: (obj["until"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                source: obj["source"] as? String ?? "cli")
            if task.isAlive { out.append(task) } else { try? fm.removeItem(at: url) }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Grava uma tarefa (usado pelo servidor MCP). Devolve o id.
    @discardableResult
    static func write(name: String, pid: Int32?, minutes: Int?, source: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        let id = pid.map { "\(source)-pid-\($0)" } ?? "\(source)-timer-\(now)"
        var obj: [String: Any] = ["name": String(name.prefix(80)), "source": source, "started": now]
        if let pid { obj["pid"] = Int(pid) }
        if let minutes { obj["until"] = now + min(max(minutes, 1), 1440) * 60 }
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent(id), options: .atomic)
        return id
    }

    static func remove(source: String? = nil) -> Int {
        let all = read()
        let gone = all.filter { source == nil || $0.source == source }
        for t in gone { try? FileManager.default.removeItem(at: dir.appendingPathComponent(t.id)) }
        return gone.count
    }
}
