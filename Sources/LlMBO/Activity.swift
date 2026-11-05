import CoreServices
import Foundation

/// Observa (via FSEvents) as pastas onde os agentes gravam a conversa.
/// Arquivo escrito há pouco = o agente está trabalhando, mesmo com a CPU parada esperando o modelo.
final class ActivityWatcher {
    /// Última escrita vista por agente.
    private(set) var lastWrite: [String: Date] = [:]

    private var stream: FSEventStreamRef?
    private var watched: [String: [String]] = [:]   // agente → pastas existentes
    private var filters: [String: String] = [:]     // agente → trecho que o caminho precisa ter (minúsculo)

    private static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// Para o diagnóstico.
    var diagnosticLines: [String] {
        watched.keys.sorted().map { a in
            "observa \(a): \(watched[a]!.joined(separator: ", ")) filtro=\(filters[a] ?? "-") última=\(lastWrite[a].map { "\($0)" } ?? "-")"
        }
    }

    private func matches(_ agent: String, _ path: String) -> Bool {
        guard let f = filters[agent] else { return true }
        return path.lowercased().contains(f)
    }

    /// Recria o stream quando a lista de pastas existentes muda (uma pasta pode surgir depois).
    func update(_ agents: [AgentConfig]) {
        var next: [String: [String]] = [:]
        filters = [:]
        for a in agents {
            // Caminho real (/var → /private/var etc.): é assim que o FSEvents informa os eventos. O
            // resolvingSymlinksInPath do Foundation tira o /private de propósito, por isso o realpath.
            let dirs = a.expandedActivityPaths.filter { FileManager.default.fileExists(atPath: $0) }.map(Self.realPath)
            if !dirs.isEmpty { next[a.id] = dirs }
            if let f = a.activityFilter, !f.isEmpty { filters[a.id] = f.lowercased() }
        }
        guard next != watched else { return }
        watched = next
        seed()
        restart()
    }

    /// Ao começar a observar, parte da última modificação já existente nos arquivos:
    /// sem isso, logo depois de abrir o app todo agente pareceria parado.
    private func seed() {
        let fm = FileManager.default
        let since = Date().addingTimeInterval(-3600)
        for (agent, dirs) in watched {
            var newest = lastWrite[agent] ?? .distantPast
            for dir in dirs {
                guard let e = fm.enumerator(at: URL(fileURLWithPath: dir),
                                            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in e {
                    guard matches(agent, url.path),
                          let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          v.isRegularFile == true, let m = v.contentModificationDate, m > since, m > newest else { continue }
                    newest = min(m, Date())
                }
            }
            if newest > since { lastWrite[agent] = newest }
        }
    }

    private func restart() {
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        let paths = Array(Set(watched.values.joined()))
        guard !paths.isEmpty else { return }

        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            for i in 0..<count {
                // Só escrita/criação/renomeação de arquivos, não de pastas.
                let f = flags[i]
                let isFile = f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
                let changed = f & UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated
                                         | kFSEventStreamEventFlagItemRenamed) != 0
                if isFile && changed { me.record(paths[i]) }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func record(_ path: String) {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return }   // .DS_Store, travas, temporários
        for (agent, dirs) in watched where dirs.contains(where: { path.hasPrefix($0 + "/") }) && matches(agent, path) {
            lastWrite[agent] = Date()
        }
    }
}
