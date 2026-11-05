import Foundation

/// Roda um comando e devolve status + saída (stdout e stderr juntos).
@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LlMBO")
    static let signals = support.appendingPathComponent("signals")
    static let agentsFile = support.appendingPathComponent("agents.json")
    static let signalScript = support.appendingPathComponent("llmbo-signal")

    /// Cria as pastas e instala o script de sinal usado pelos hooks dos agentes.
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: signals, withIntermediateDirectories: true)
        if let src = Bundle.main.url(forResource: "llmbo-signal", withExtension: nil) {
            try? fm.removeItem(at: signalScript)
            try? fm.copyItem(at: src, to: signalScript)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signalScript.path)
        }
    }
}
