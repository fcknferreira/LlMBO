import Foundation

/// Limites do Claude Code pelo próprio CLI: `claude -p /usage --output-format json`. É um comando local do Claude Code
/// (0 turnos, 0 tokens, ~0,4 s): quem consulta a Anthropic é o Claude Code, com o login dele; o LlMBO só lê o texto.
/// Funciona para quem usa o Claude Code só pelo app Claude (que não chama a barra de status): o CLI vem dentro do app
/// (`MCPInstall.claudeCLI`). Roda sem gravar sessão (`--no-session-persistence`) e sem disparar hooks
/// (`disableAllHooks`), na pasta do LlMBO. Opcional (aba Uso, `claudeUsageCLI`, desligado por padrão), a cada 5 min
/// e só com o Claude Code na lista. Texto em inglês, conferido em 02/11/2026 (Claude Code 2.1.309):
///   Current session: 95% used · resets Nov 3 at 1:09am (America/Maceio)
///   Current week (all models): 89% used · resets Nov 5 at 12:59am (America/Maceio)
enum ClaudeUsageCLI {
    static let defaultsKey = "claudeUsageCLI"
    static let interval: TimeInterval = 300

    /// Roda o comando (até 30 s) e devolve os limites; nil se o CLI não existe ou a saída não tem os limites.
    static func read(now: Date) -> AgentUsage? {
        guard let cli = MCPInstall.claudeCLI else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                       "--settings", #"{"disableAllHooks":true}"#]
        p.currentDirectoryURL = Paths.support
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = obj["result"] as? String else { return nil }
        var u = parse(text, now: now)
        u?.limitsAt = now
        // O Claude Code respondeu, mas sem as linhas "Current session"/"Current week": o texto mudou (ou veio erro).
        Canaries.report("claude-usage", .usage, problem: u == nil
            ? String(localized: "Não consegui ler os limites do Claude Code: a resposta do /usage mudou ou veio com erro.") : nil)
        return u
    }

    /// Lê "Current session" (janela de 5 h) e "Current week (all models)" (semanal) do texto do /usage.
    static func parse(_ text: String, now: Date) -> AgentUsage? {
        var u = AgentUsage()
        for line in text.split(separator: "\n").map(String.init) {
            // "Current session" virou "5-hour limit" em versões novas do Claude Code (changelog 2.1.30x);
            // aceita os dois, com ou sem "Current".
            let parts = line.capturing(#"^(?:Current )?(session|5-hour limit|week[^:]*): (\d+(?:\.\d+)?)% used · resets (.+) \(([^)]+)\)"#)
            guard parts.count == 4, let pct = Double(parts[1]),
                  let reset = resetDate(parts[2], tz: TimeZone(identifier: parts[3]) ?? .current, now: now),
                  reset > now else { continue }
            let w = LimitWindow(usedPercent: pct, resetsAt: reset)
            if parts[0] == "session" || parts[0] == "5-hour limit" { u.fiveHour = w }
            else if parts[0].contains("all models") || u.weekly == nil { u.weekly = w }
        }
        return u.fiveHour == nil && u.weekly == nil ? nil : u
    }

    /// "Nov 3 at 1:09am", "Nov 3 at 1am", "Nov 3", "1:09am" ou "1am", no fuso indicado. Sem data = a próxima vez
    /// que esse horário chega; sem ano = este ano (ou o próximo, se já passou).
    static func resetDate(_ text: String, tz: TimeZone, now: Date) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let year = cal.component(.year, from: now)
        let t = text.trimmingCharacters(in: .whitespaces)
        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d"] {
            f.dateFormat = format + " yyyy"
            if var d = f.date(from: "\(t) \(year)") {
                if d < now.addingTimeInterval(-86_400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
                return d
            }
        }
        for format in ["h:mma", "ha"] {
            f.dateFormat = format
            guard let time = f.date(from: t) else { continue }
            let hm = cal.dateComponents([.hour, .minute], from: time)
            guard var d = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: now) else { continue }
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
            return d
        }
        return nil
    }

    /// LLMBO_TEST_CLAUDEUSAGE=1: textos gravados do /usage e, se o CLI existir, uma leitura de verdade.
    /// Grava claude-usage-test.log.
    static func selfTest() {
        var out: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append("\(ok ? "ok " : "ERRO") \(name) \(detail)") }
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "America/Maceio")!
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 23, minute: 50))!
        let sample = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 95% used · resets Nov 3 at 1:09am (America/Maceio)
        Current week (all models): 89% used · resets Nov 5 at 12:59am (America/Maceio)
        Current week (Opus): 40% used · resets Nov 5 at 12:59am (America/Maceio)
        """
        let u = parse(sample, now: now)
        let c = { (d: Date?) in d.map { cal.dateComponents([.month, .day, .hour, .minute], from: $0) } }
        check("5 h", u?.fiveHour?.usedPercent == 95, "\(u?.fiveHour?.usedPercent ?? -1)")
        check("reset de 5 h = 3/11 01:09", c(u?.fiveHour?.resetsAt) == DateComponents(month: 11, day: 3, hour: 1, minute: 9))
        check("semanal = all models (não Opus)", u?.weekly?.usedPercent == 89, "\(u?.weekly?.usedPercent ?? -1)")
        check("reset semanal = 5/11 00:59", c(u?.weekly?.resetsAt) == DateComponents(month: 11, day: 5, hour: 0, minute: 59))
        check("só horário: amanhã se já passou", c(resetDate("1:09am", tz: tz, now: now)) == DateComponents(month: 11, day: 3, hour: 1, minute: 9))
        check("hora cheia", c(resetDate("Nov 3 at 1am", tz: tz, now: now)) == DateComponents(month: 11, day: 3, hour: 1, minute: 0))
        check("virada de ano", cal.component(.year, from: resetDate("Jan 2 at 3:00pm", tz: tz,
              now: cal.date(from: DateComponents(year: 2026, month: 12, day: 30))!)!) == 2027)
        let renamed = parse("5-hour limit: 61% used · resets Nov 3 at 1:09am (America/Maceio)", now: now)
        check("nome novo \"5-hour limit\"", renamed?.fiveHour?.usedPercent == 61, "\(renamed?.fiveHour?.usedPercent ?? -1)")
        check("sem limites = nil", parse("You are currently using an API key", now: now) == nil)
        if MCPInstall.claudeCLI != nil {
            let live = read(now: Date())
            check("leitura de verdade", live?.fiveHour != nil,
                  "5h=\(live?.fiveHour?.usedPercent ?? -1)% semana=\(live?.weekly?.usedPercent ?? -1)%")
        }
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("claude-usage-test.log"), atomically: true, encoding: .utf8)
    }
}

private extension String {
    /// Grupos de captura da primeira ocorrência.
    func capturing(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return [] }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: self).map { String(self[$0]) } }
    }
}
