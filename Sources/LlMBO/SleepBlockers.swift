import Foundation
import Darwin

/// Outro processo impedindo o Mac de dormir (asserção de energia), lido de `pmset -g assertions`.
struct SleepBlocker: Identifiable, Equatable {
    let id: String
    let pid: Int32
    /// Nome do processo; com o áudio, o app que pediu ("Zen (coreaudiod)").
    let name: String
    /// Descrição que o próprio processo deu (texto do sistema, não traduzido).
    let detail: String
    let seconds: Int

    /// `caffeinate` esquecido é o caso comum (agentes e scripts que não o encerram): dá para encerrar.
    var canStop: Bool { name == "caffeinate" }
}

enum SleepBlockers {
    /// Tipos que impedem o repouso do sistema (os de tela e "usuário ativo" não contam).
    private static let types: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    private static let line = try! NSRegularExpression(
        pattern: #"^\s*pid (\d+)\(([^)]*)\): \[[^\]]*\] (\d+):(\d+):(\d+) (\w+) named: "(.*)""#)
    private static let createdFor = try! NSRegularExpression(pattern: #"Created for PID: (\d+)"#)

    static func read() -> [SleepBlocker] {
        let out = run("/usr/bin/pmset", ["-g", "assertions"]).output
        let lines = out.components(separatedBy: "\n")
        let me = getpid()
        var result: [SleepBlocker] = []
        for (i, l) in lines.enumerated() {
            let ns = l as NSString
            guard let m = line.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ k: Int) -> String { ns.substring(with: m.range(at: k)) }
            guard let pid = Int32(g(1)), pid != me, types.contains(g(6)) else { continue }
            let detail = g(7)
            if g(2) == "powerd" && detail.contains("display is on") { continue }   // regra padrão do macOS
            var name = g(2)
            // O áudio (coreaudiod) segura em nome do app que está tocando: a linha seguinte diz qual.
            if i + 1 < lines.count, let c = createdFor.firstMatch(in: lines[i + 1], range: NSRange(location: 0, length: (lines[i + 1] as NSString).length)),
               let owner = Int32((lines[i + 1] as NSString).substring(with: c.range(at: 1))), let app = processName(owner) {
                name = "\(app) (\(name))"
            }
            let secs = (Int(g(3)) ?? 0) * 3600 + (Int(g(4)) ?? 0) * 60 + (Int(g(5)) ?? 0)
            result.append(SleepBlocker(id: "\(pid)-\(i)", pid: pid, name: name, detail: detail, seconds: secs))
        }
        return result
    }

    private static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        // Dentro de um .app, o nome do app; senão, o do executável.
        if let r = path.range(of: ".app/") { return (String(path[..<r.lowerBound]) as NSString).lastPathComponent }
        return (path as NSString).lastPathComponent
    }

    static func stop(_ b: SleepBlocker) {
        kill(b.pid, SIGTERM)
    }
}

/// Lista da aba Repouso: relida a cada 5 s só enquanto a aba está aberta.
@MainActor
final class SleepBlockersModel: ObservableObject {
    @Published private(set) var blockers: [SleepBlocker] = []
    /// O repouso está desligado (pmset disablesleep) sem ser pelo LlMBO.
    @Published private(set) var disabledOutside = false
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let list = SleepBlockers.read()
        if list != blockers { blockers = list }
        let outside = Power.sleepDisabled && !Engine.shared.holding
        if outside != disabledOutside { disabledOutside = outside }
    }
}
