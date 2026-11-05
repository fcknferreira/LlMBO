import Foundation
import SQLite3

/// Uma janela de limite de uso (5 horas ou semanal): quanto já foi usado e quando volta.
struct LimitWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date
}

/// Sessão do Codex que parou no limite de uso.
struct CodexStop: Equatable {
    let sessionID: String
    let cwd: String
    let stoppedAt: Date
    /// Identifica esta parada (a mesma sessão pode parar de novo mais tarde).
    var key: String { "\(sessionID)@\(Int(stoppedAt.timeIntervalSince1970))" }
}

/// Limites e tokens de um agente, lidos só de arquivos locais (nada vai pela internet).
struct AgentUsage: Equatable {
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    /// Quando os limites foram lidos (última resposta do agente).
    var limitsAt: Date?
    var tokens5h = 0
    var tokensToday = 0
    var tokens7d = 0
    /// Antigravity: limites por grupo de modelos (AntigravityQuota), no lugar de fiveHour/weekly.
    var groups: [LimitGroup] = []
    var hasData: Bool { fiveHour != nil || weekly != nil || tokens7d > 0 || !groups.isEmpty }

    /// Hora em que o agente pode voltar depois de bater no limite em `hitAt`: a janela cheia (≥ 99 %)
    /// que volta mais tarde; sem ela, a de 5 horas. nil se não se sabe ou se já passou.
    func resetAfterLimit(hitAt: Date) -> Date? {
        if !groups.isEmpty { return AntigravityQuota.reset(groups, hitAt: hitAt) }
        let windows = [fiveHour, weekly].compactMap { $0 }.filter { $0.resetsAt > hitAt }
        if let full = windows.filter({ $0.usedPercent >= 99 }).map(\.resetsAt).max() { return full }
        return fiveHour.flatMap { $0.resetsAt > hitAt ? $0.resetsAt : nil }
    }
}

/// Lê o uso dos agentes a cada minuto, fora da thread principal, só de arquivos locais.
/// Claude Code: limites pela barra de status (`llmbo-signal statusline` grava usage/claude-statusline.json);
/// tokens pelos transcritos em ~/.claude/projects. Codex: eventos token_count dos arquivos de sessão
/// (~/.codex/sessions), que trazem tokens e rate_limits. Antigravity: steps com step_type 15 em
/// ~/.gemini/antigravity{,-ide}/conversations/*.db. Gemini CLI e Qwen Code: sessões em
/// ~/.<agente>/tmp/<projeto>/chats. OpenCode: ~/.local/share/opencode/storage/message.
/// Sem dados locais de uso: Copilot, Cursor e a IA local (Ollama e LM Studio não gravam tokens).
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// Uso por id de agente (ids do catálogo).
    @Published private(set) var byAgent: [String: AgentUsage] = [:]
    var claude: AgentUsage { byAgent["claude"] ?? AgentUsage() }
    var codex: AgentUsage { byAgent["codex"] ?? AgentUsage() }
    /// Sessões do Codex paradas no limite (para "Retomar o Codex depois do limite").
    @Published private(set) var codexStops: [CodexStop] = []
    /// Ordem na aba Uso.
    static let order = ["claude", "codex", "antigravity", "gemini", "qwen", "opencode"]

    nonisolated static let claudeStatusFile = Paths.support.appendingPathComponent("usage/claude-statusline.json")
    private let scanner = TokenScanner()
    private let queue = DispatchQueue(label: "llmbo.usage", qos: .utility)
    private var timer: Timer?
    private var running = false
    /// Pedido de leitura enquanto outra rodava: lê de novo ao terminar.
    private var again = false
    /// Ligado pelo Engine: opção "Ler limites pelo Claude Code" e o Claude Code na lista.
    var readClaudeUsage = false {
        didSet { if readClaudeUsage && !oldValue { claudeCLI = nil; refresh() } }
    }
    /// Última leitura do /usage (o comando roda a cada 5 min, não a cada minuto).
    private var claudeCLI: (at: Date, usage: AgentUsage?)?
    /// Ligado pelo Engine: opção "Ler a cota pelo Antigravity aberto" e um Antigravity na lista.
    var readAntigravityQuota = false {
        didSet { if readAntigravityQuota && !oldValue { refresh() } }
    }

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in UsageStore.shared.refresh() }
        }
    }

    func refresh() {
        guard !running else { again = true; return }
        running = true
        let scanner = scanner
        let agQuota = readAntigravityQuota
        // A cada 5 min, ou logo que uma janela guardada voltar (o reset passou: o percentual novo já é outro).
        let windowExpired = [claudeCLI?.usage?.fiveHour, claudeCLI?.usage?.weekly].compactMap { $0 }.contains { $0.resetsAt <= Date() }
        let claudeCLIDue = readClaudeUsage
            && (claudeCLI.map { Date().timeIntervalSince($0.at) >= ClaudeUsageCLI.interval || windowExpired } ?? true)
        let claudeCLICached = readClaudeUsage ? claudeCLI?.usage : nil
        queue.async {
            let now = Date()
            let home = FileManager.default.homeDirectoryForCurrentUser
            var all: [String: AgentUsage] = [:]
            var claude = Self.claudeLimits(now: now)
            // Pelo /usage do Claude Code (a cada 5 min); vale a leitura mais nova entre ele e a barra de status.
            let fromCLI = claudeCLIDue ? ClaudeUsageCLI.read(now: now) : claudeCLICached
            if let c = fromCLI, (c.limitsAt ?? .distantPast) > (claude.limitsAt ?? .distantPast) {
                claude.fiveHour = c.fiveHour.flatMap { $0.resetsAt > now ? $0 : nil }
                claude.weekly = c.weekly.flatMap { $0.resetsAt > now ? $0 : nil }
                claude.limitsAt = c.limitsAt
            }
            (claude.tokens5h, claude.tokensToday, claude.tokens7d) =
                scanner.claudeTokens(root: home.appendingPathComponent(".claude/projects"), now: now)
            all["claude"] = claude
            all["codex"] = scanner.codex(root: home.appendingPathComponent(".codex/sessions"), now: now)
            let stops = scanner.codexStops(now: now)
            for agent in ["gemini", "qwen"] {
                var u = AgentUsage()
                (u.tokens5h, u.tokensToday, u.tokens7d) =
                    scanner.geminiChats(root: home.appendingPathComponent(".\(agent)/tmp"), now: now)
                all[agent] = u
            }
            var oc = AgentUsage()
            (oc.tokens5h, oc.tokensToday, oc.tokens7d) =
                scanner.opencode(root: home.appendingPathComponent(".local/share/opencode/storage/message"), now: now)
            all["opencode"] = oc
            var ag = AgentUsage()
            (ag.tokens5h, ag.tokensToday, ag.tokens7d) =
                scanner.antigravity(roots: [
                    home.appendingPathComponent(".gemini/antigravity/conversations"),
                    home.appendingPathComponent(".gemini/antigravity-ide/conversations")
                ], now: now)
            if agQuota, let groups = AntigravityQuota.read(now: now) {
                ag.groups = groups
                ag.limitsAt = now
            }
            all["antigravity"] = ag
            scanner.prune(now)
            let found = all.filter { $0.key == "claude" || $0.value.hasData }
            Task { @MainActor in
                let store = UsageStore.shared
                if store.byAgent != found { store.byAgent = found }
                if store.codexStops != stops { store.codexStops = stops }
                if claudeCLIDue { store.claudeCLI = (now, fromCLI) }
                store.running = false
                if store.again { store.again = false; store.refresh() }
            }
        }
    }

    /// Limites do Claude Code pelo último JSON da barra de status. Janelas que já voltaram somem
    /// (o próprio Claude Code faz o mesmo).
    nonisolated static func claudeLimits(now: Date) -> AgentUsage {
        var u = AgentUsage()
        guard let data = try? Data(contentsOf: claudeStatusFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return u }
        func window(_ key: String) -> LimitWindow? {
            guard let w = limits[key] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let at = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            let reset = Date(timeIntervalSince1970: at)
            return reset > now ? LimitWindow(usedPercent: pct, resetsAt: reset) : nil
        }
        u.fiveHour = window("five_hour")
        u.weekly = window("seven_day")
        u.limitsAt = (try? FileManager.default.attributesOfItem(atPath: claudeStatusFile.path)[.modificationDate]) as? Date
        return u
    }
}

/// Soma tokens lendo só o que foi acrescentado a cada arquivo desde a última leitura (os transcritos só crescem).
/// Usado só pela fila do UsageStore.
final class TokenScanner: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        var entries: [(Date, Int)] = []
        var seen = Set<String>()
        /// Codex: último rate_limits visto neste arquivo.
        var limits: (Date, [String: Any])?
        /// Gemini CLI / Qwen: tokens por id de mensagem (a mensagem é regravada; vale a última versão).
        var byID: [String: (Date, Int)] = [:]
        /// Arquivos lidos inteiros (.json): só relê se a data mudar.
        var mtime: Date?
        /// Pasta/arquivo ainda visto nesta leitura (os outros saem do cache).
        var touched = false
        /// Codex: sessão do arquivo (session_meta), última parada por limite e último começo de turno.
        var codexSession: (id: String, cwd: String)?
        var lastLimitStop: Date?
        var lastTaskStart: Date?
        /// Antigravity: maior idx da tabela steps já processado neste banco.
        var lastStepIdx: Int64 = -1
    }
    private var files: [String: FileState] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    private func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Arquivos .jsonl mexidos nos últimos 7 dias, em qualquer subpasta.
    private func recentFiles(_ root: URL, now: Date) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(m) < 7 * 86400 { out.append(url) }
        }
        return out
    }

    /// Lê as linhas novas (completas) de um arquivo.
    private func newLines(_ url: URL, _ state: inout FileState) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }   // arquivo trocado
        try? h.seek(toOffset: state.offset)
        guard let data = try? h.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return [] }
        let chunk = data[data.startIndex...last]
        state.offset += UInt64(chunk.count)
        return String(decoding: chunk, as: UTF8.self).split(separator: "\n")
    }

    private func totals(_ now: Date, _ keys: [String]) -> (Int, Int, Int) {
        let start = Calendar.current.startOfDay(for: now)
        var t = (0, 0, 0)
        for k in keys {
            for (d, n) in (files[k]?.entries ?? []) + Array((files[k]?.byID ?? [:]).values) {
                let age = now.timeIntervalSince(d)
                if age < 5 * 3600 { t.0 += n }
                if d >= start { t.1 += n }
                if age < 7 * 86400 { t.2 += n }
            }
        }
        return t
    }

    /// Tira do cache os arquivos que não apareceram nesta leitura e as entradas com mais de 7 dias.
    func prune(_ now: Date) {
        files = files.filter { $0.value.touched }
        for k in files.keys {
            files[k]!.touched = false
            files[k]!.entries.removeAll { now.timeIntervalSince($0.0) > 7 * 86400 }
            files[k]!.byID = files[k]!.byID.filter { now.timeIntervalSince($0.value.0) <= 7 * 86400 }
        }
    }

    private func state(_ url: URL) -> FileState {
        var st = files[url.path] ?? FileState()
        st.touched = true
        return st
    }

    /// Claude Code: cada resposta grava message.usage (entrada, cache e saída). Uma resposta com vários blocos
    /// aparece em várias linhas com o mesmo message.id, então conta uma vez só.
    func claudeTokens(root: URL, now: Date) -> (Int, Int, Int) {
        let urls = recentFiles(root, now: now)
        for url in urls {
            var st = state(url)
            for line in newLines(url, &st) where line.contains("\"usage\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let when = date(obj["timestamp"] as? String) else { continue }
                let id = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
                guard st.seen.insert(id).inserted else { continue }
                let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                st.entries.append((when, n))
            }
            files[url.path] = st
        }
        return totals(now, urls.map(\.path))
    }

    /// Codex: eventos {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{...}},
    /// "rate_limits":{"primary":{used_percent, window_minutes, resets_at|resets_in_seconds},"secondary":{...}}}}.
    /// Formato tirado do código aberto do Codex; não calibrado com o Codex rodando neste Mac.
    func codex(root: URL, now: Date) -> AgentUsage {
        let urls = recentFiles(root, now: now)
        var latest: (Date, [String: Any])?
        for url in urls {
            var st = state(url)
            for line in newLines(url, &st)
            where line.contains("token_count") || line.contains("session_meta") || line.contains("task_started")
                || line.contains("usage_limit_exceeded") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let when = date(obj["timestamp"] as? String) else { continue }
                // Retomada depois do limite (CodexResume): de que sessão é o arquivo, quando parou por limite
                // (task_complete com error.codex_error_info = usage_limit_exceeded) e quando um turno recomeçou.
                // session_meta tem o tipo no nível de cima ({"type":"session_meta","payload":{id, cwd…}});
                // os outros são event_msg com o tipo dentro do payload.
                switch obj["type"] as? String == "session_meta" ? "session_meta" : payload["type"] as? String {
                case "session_meta":
                    if let id = payload["id"] as? String { st.codexSession = (id, payload["cwd"] as? String ?? "") }
                    continue
                case "task_started":
                    st.lastTaskStart = when
                    continue
                case "token_count":
                    break
                default:
                    if line.contains("usage_limit_exceeded") { st.lastLimitStop = when }
                    continue
                }
                if let info = payload["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any],
                   let n = (last["total_tokens"] as? NSNumber)?.intValue {
                    st.entries.append((when, n))
                }
                if let rl = (payload["rate_limits"] ?? payload["rateLimits"]) as? [String: Any] { st.limits = (when, rl) }
            }
            files[url.path] = st
            if let l = st.limits, l.0 > (latest?.0 ?? .distantPast) { latest = l }
        }
        var u = AgentUsage()
        (u.tokens5h, u.tokensToday, u.tokens7d) = totals(now, urls.map(\.path))
        if let (when, rl) = latest {
            func window(_ key: String) -> LimitWindow? {
                guard let w = rl[key] as? [String: Any],
                      let pct = ((w["used_percent"] ?? w["usedPercent"]) as? NSNumber)?.doubleValue else { return nil }
                let reset: Date
                if let at = ((w["resets_at"] ?? w["resetsAt"]) as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: at) }
                else if let s = ((w["resets_in_seconds"] ?? w["resetsInSeconds"]) as? NSNumber)?.doubleValue { reset = when.addingTimeInterval(s) }
                else { return nil }
                return reset > now ? LimitWindow(usedPercent: pct, resetsAt: reset) : nil
            }
            u.fiveHour = window("primary")
            u.weekly = window("secondary")
            u.limitsAt = when
        }
        return u
    }

    /// Sessões do Codex paradas no limite de uso e não retomadas depois (o último evento é a parada).
    func codexStops(now: Date) -> [CodexStop] {
        files.values.compactMap { st in
            guard let s = st.codexSession, let stop = st.lastLimitStop,
                  stop > (st.lastTaskStart ?? .distantPast), now.timeIntervalSince(stop) < 24 * 3600 else { return nil }
            return CodexStop(sessionID: s.id, cwd: s.cwd, stoppedAt: stop)
        }
    }

    /// Gemini CLI e Qwen Code: ~/.<agente>/tmp/<projeto>/chats/session-*.jsonl (uma mensagem por linha; versões
    /// antigas: session-*.json com "messages"). Mensagens "gemini" trazem tokens {input, output, cached, thoughts,
    /// tool, total}; a mesma mensagem pode ser regravada, então vale a última por id. Usa `total` (ou a soma).
    /// Formato de leitores da comunidade (agent-top, sidecar); não calibrado com o agente rodando neste Mac.
    func geminiChats(root: URL, now: Date) -> (Int, Int, Int) {
        let fm = FileManager.default
        var urls: [URL] = []
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let chats = project.appendingPathComponent("chats")
            for f in (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.lastPathComponent.hasPrefix("session-") && ["json", "jsonl"].contains(f.pathExtension) {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(m) < 7 * 86400 { urls.append(f) }
            }
        }
        func record(_ msg: [String: Any], _ st: inout FileState) {
            guard msg["type"] as? String == "gemini", let tokens = msg["tokens"] as? [String: Any],
                  let when = date(msg["timestamp"] as? String) else { return }
            let n = (tokens["total"] as? NSNumber)?.intValue
                ?? ["input", "output", "thoughts", "tool"].reduce(0) { $0 + ((tokens[$1] as? NSNumber)?.intValue ?? 0) }
            st.byID[(msg["id"] as? String) ?? UUID().uuidString] = (when, n)
        }
        for url in urls {
            var st = state(url)
            if url.pathExtension == "jsonl" {
                for line in newLines(url, &st) where line.contains("\"tokens\"") {
                    if let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { record(msg, &st) }
                }
            } else {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if m != st.mtime, let data = try? Data(contentsOf: url),
                   let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    st.byID = [:]
                    for msg in doc["messages"] as? [[String: Any]] ?? [] { record(msg, &st) }
                    st.mtime = m
                }
            }
            files[url.path] = st
        }
        return totals(now, urls.map(\.path))
    }

    /// OpenCode: storage/message/<sessão>/<mensagem>.json com tokens {input, output, reasoning, cache {read, write}}
    /// e time.created (ms). Cada arquivo é uma mensagem; relê só os que mudaram. Versões que guardam tudo num
    /// banco SQLite não têm essa pasta e ficam sem números. Não calibrado com o OpenCode rodando neste Mac.
    func opencode(root: URL, now: Date) -> (Int, Int, Int) {
        let fm = FileManager.default
        var urls: [URL] = []
        for session in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let sm = (try? session.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(sm) < 7 * 86400 else { continue }
            for f in (try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.pathExtension == "json" {
                var st = state(f)
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if m != st.mtime {
                    st.entries = []
                    if let data = try? Data(contentsOf: f),
                       let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let t = msg["tokens"] as? [String: Any],
                       let created = ((msg["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue {
                        let cache = t["cache"] as? [String: Any] ?? [:]
                        let n = ["input", "output", "reasoning"].reduce(0) { $0 + ((t[$1] as? NSNumber)?.intValue ?? 0) }
                            + ((cache["read"] as? NSNumber)?.intValue ?? 0) + ((cache["write"] as? NSNumber)?.intValue ?? 0)
                        if n > 0 { st.entries = [(Date(timeIntervalSince1970: created / 1000), n)] }
                    }
                    st.mtime = m
                }
                files[f.path] = st
                urls.append(f)
            }
        }
        return totals(now, urls.map(\.path))
    }

    /// Decodifica o blob protobuf de `steps.metadata`:
    /// Campo 1: google.protobuf.Timestamp (subcampo 1: seconds varint)
    /// Campo 9: UsageMetadata (subcampos 2: input, 3: output, 5: cache)
    /// Devolve (data, total_de_tokens) ou nil se não houver dados válidos. Nunca lê campos de texto.
    private func parseStepMetadata(_ bytes: UnsafeRawBufferPointer) -> (Date, Int)? {
        var p = 0
        let count = bytes.count

        func readVarint() -> UInt64? {
            var v: UInt64 = 0
            var shift = 0
            while p < count {
                let b = bytes[p]
                p += 1
                v |= UInt64(b & 0x7F) << shift
                shift += 7
                if (b & 0x80) == 0 { return v }
                if shift >= 64 { return nil }
            }
            return nil
        }

        var seconds: Int64 = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheTokens = 0

        while p < count {
            guard let key = readVarint() else { break }
            let fn = key >> 3
            let wt = key & 7
            switch wt {
            case 0: // varint
                _ = readVarint()
            case 2: // length-delimited
                guard let len = readVarint().map({ Int(clamping: $0) }) else { break }
                let end = p &+ len
                if len < 0 || len > count - p { p = count; break }
                if fn == 1 { // Timestamp
                    let subBytes = UnsafeRawBufferPointer(rebasing: bytes[p..<end])
                    var sp = 0
                    while sp < subBytes.count {
                        var sv: UInt64 = 0; var ss = 0
                        while sp < subBytes.count {
                            let sb = subBytes[sp]; sp += 1
                            sv |= UInt64(sb & 0x7F) << ss; ss += 7
                            if (sb & 0x80) == 0 { break }
                        }
                        let sfn = sv >> 3; let swt = sv & 7
                        if swt == 0 {
                            var v: UInt64 = 0; var s = 0
                            while sp < subBytes.count {
                                let sb = subBytes[sp]; sp += 1
                                v |= UInt64(sb & 0x7F) << s; s += 7
                                if (sb & 0x80) == 0 { break }
                            }
                            if sfn == 1 { seconds = Int64(v) }
                        } else if swt == 2 {
                            var l: UInt64 = 0; var s = 0
                            while sp < subBytes.count {
                                let sb = subBytes[sp]; sp += 1
                                l |= UInt64(sb & 0x7F) << s; s += 7
                                if (sb & 0x80) == 0 { break }
                            }
                            sp += Int(clamping: l)
                        } else if swt == 1 { sp += 8 }
                        else if swt == 5 { sp += 4 }
                    }
                } else if fn == 9 { // Usage
                    let subBytes = UnsafeRawBufferPointer(rebasing: bytes[p..<end])
                    var sp = 0
                    while sp < subBytes.count {
                        var sv: UInt64 = 0; var ss = 0
                        while sp < subBytes.count {
                            let sb = subBytes[sp]; sp += 1
                            sv |= UInt64(sb & 0x7F) << ss; ss += 7
                            if (sb & 0x80) == 0 { break }
                        }
                        let sfn = sv >> 3; let swt = sv & 7
                        if swt == 0 {
                            var v: UInt64 = 0; var s = 0
                            while sp < subBytes.count {
                                let sb = subBytes[sp]; sp += 1
                                v |= UInt64(sb & 0x7F) << s; s += 7
                                if (sb & 0x80) == 0 { break }
                            }
                            if sfn == 2 { inputTokens = Int(clamping: v) }
                            else if sfn == 3 { outputTokens = Int(clamping: v) }
                            else if sfn == 5 { cacheTokens = Int(clamping: v) }
                        } else if swt == 2 {
                            var l: UInt64 = 0; var s = 0
                            while sp < subBytes.count {
                                let sb = subBytes[sp]; sp += 1
                                l |= UInt64(sb & 0x7F) << s; s += 7
                                if (sb & 0x80) == 0 { break }
                            }
                            sp += Int(clamping: l)
                        } else if swt == 1 { sp += 8 }
                        else if swt == 5 { sp += 4 }
                    }
                }
                p = end
            case 1: p += 8
            case 5: p += 4
            default: break
            }
        }
        let total = inputTokens + outputTokens + cacheTokens
        guard total > 0, seconds > 0 else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(seconds)), total)
    }

    /// Arquivos .db mexidos nos últimos 7 dias em qualquer uma das pastas.
    private func recentDBFiles(_ roots: [URL], now: Date) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var seenNames = Set<String>()
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsSubdirectoryDescendants]) else { continue }
            for case let url as URL in e where url.pathExtension == "db" {
                let name = url.lastPathComponent
                guard seenNames.insert(name).inserted else { continue }
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(m) < 7 * 86400 { out.append(url) }
            }
        }
        return out
    }

    /// Antigravity: lê o uso de tokens da tabela `steps` dos bancos SQLite em
    /// ~/.gemini/antigravity/conversations/*.db e ~/.gemini/antigravity-ide/conversations/*.db.
    /// Abre em modo somente leitura (?immutable=1). Lê apenas idx e o blob protobuf de `metadata`,
    /// de onde extrai apenas o timestamp (campo 1) e as contagens de tokens (campo 9: input, output, cache).
    /// Nunca lê ou armazena o texto das mensagens.
    func antigravity(roots: [URL], now: Date) -> (Int, Int, Int) {
        let urls = recentDBFiles(roots, now: now)
        for url in urls {
            var st = state(url)
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if m != st.mtime {
                var db: OpaquePointer?
                let uri = "file:\(url.path)?immutable=1"
                if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                    defer { sqlite3_close(db) }
                    var stmt: OpaquePointer?
                    let sql = "SELECT idx, metadata FROM steps WHERE step_type = 15 AND idx > ? ORDER BY idx"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, st.lastStepIdx)
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            let idx = sqlite3_column_int64(stmt, 0)
                            if idx > st.lastStepIdx { st.lastStepIdx = idx }
                            if let blob = sqlite3_column_blob(stmt, 1) {
                                let len = Int(sqlite3_column_bytes(stmt, 1))
                                let buf = UnsafeRawBufferPointer(start: blob, count: len)
                                if let (when, total) = parseStepMetadata(buf) {
                                    st.entries.append((when, total))
                                }
                            }
                        }
                    }
                }
                st.mtime = m
            }
            files[url.path] = st
        }
        return totals(now, urls.map(\.path))
    }
}

// MARK: - Teste

extension TokenScanner {
    /// LLMBO_TEST_USAGE=1: arquivos sintéticos numa pasta temporária para cada leitor. Grava usage-test.log.
    static func selfTest() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("llmbo-usage-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        func put(_ path: String, _ text: String) {
            let u = base.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        let now = Date()
        let iso = ISO8601DateFormatter()
        let t1 = iso.string(from: now.addingTimeInterval(-3600))        // 1 h atrás
        let t2 = iso.string(from: now.addingTimeInterval(-3 * 86400))   // 3 dias atrás
        var out: [String] = []
        func check(_ name: String, _ got: (Int, Int, Int), _ want5h: Int, _ want7d: Int) {
            out.append("\(got.0 == want5h && got.2 == want7d ? "ok " : "ERRO") \(name): 5h=\(got.0) (esperado \(want5h)) 7d=\(got.2) (esperado \(want7d))")
        }
        // Gemini .jsonl: a mensagem m1 é regravada (vale a última, 150); m2 tem 3 dias; usuário não conta.
        put("gemini/proj/chats/session-2026-11-02T10-00-aaaa.jsonl", [
            #"{"id":"m0","type":"user","timestamp":"\#(t1)","content":"oi"}"#,
            #"{"id":"m1","type":"gemini","timestamp":"\#(t1)","tokens":{"input":80,"output":20,"total":100}}"#,
            #"{"id":"m1","type":"gemini","timestamp":"\#(t1)","tokens":{"input":100,"output":50,"total":150}}"#,
            #"{"id":"m2","type":"gemini","timestamp":"\#(t2)","tokens":{"input":5,"output":5,"thoughts":10}}"#,
        ].joined(separator: "\n") + "\n")
        // Gemini .json antigo.
        put("gemini/proj2/chats/session-old.json",
            #"{"sessionId":"s","messages":[{"id":"x","type":"gemini","timestamp":"\#(t1)","tokens":{"total":7}}]}"#)
        let scanner = TokenScanner()
        check("gemini", scanner.geminiChats(root: base.appendingPathComponent("gemini"), now: now), 157, 177)
        check("gemini (2ª leitura, sem duplicar)", scanner.geminiChats(root: base.appendingPathComponent("gemini"), now: now), 157, 177)
        // OpenCode: duas mensagens, uma com cache.
        let ms = Int(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        put("opencode/ses_1/msg_1.json", #"{"id":"msg_1","role":"assistant","time":{"created":\#(ms)},"tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":100,"write":15}}}"#)
        put("opencode/ses_1/msg_2.json", #"{"id":"msg_2","role":"user","time":{"created":\#(ms)}}"#)
        check("opencode", scanner.opencode(root: base.appendingPathComponent("opencode"), now: now), 150, 150)
        // Codex: rate_limits em snake_case e depois em camelCase (a mais nova vale).
        let reset = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        put("codex/2026/11/02/rollout-a.jsonl", [
            #"{"timestamp":"\#(t1)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":40}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":\#(reset)}}}}"#,
            #"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-60)))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":60}},"rateLimits":{"primary":{"usedPercent":42,"resetsAt":\#(reset)},"secondary":{"usedPercent":7,"resetsInSeconds":86400}}}}"#,
        ].joined(separator: "\n") + "\n")
        let cx = scanner.codex(root: base.appendingPathComponent("codex"), now: now)
        check("codex tokens", (cx.tokens5h, cx.tokensToday, cx.tokens7d), 100, 100)
        out.append("\(cx.fiveHour?.usedPercent == 42 && cx.weekly?.usedPercent == 7 ? "ok " : "ERRO") codex limites: 5h=\(cx.fiveHour?.usedPercent ?? -1) semana=\(cx.weekly?.usedPercent ?? -1)")
        // Codex: sessão A parou no limite (sem turno depois); sessão B parou e foi retomada.
        let tA = iso.string(from: now.addingTimeInterval(-300)), tB = iso.string(from: now.addingTimeInterval(-200))
        put("codex/2026/11/02/rollout-b.jsonl", [
            #"{"timestamp":"\#(tA)","type":"session_meta","payload":{"id":"sess-A","cwd":"/tmp/projA"}}"#,
            #"{"timestamp":"\#(tA)","type":"event_msg","payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded"}}}"#,
        ].joined(separator: "\n") + "\n")
        put("codex/2026/11/02/rollout-c.jsonl", [
            #"{"timestamp":"\#(tA)","type":"session_meta","payload":{"id":"sess-B","cwd":"/tmp/projB"}}"#,
            #"{"timestamp":"\#(tA)","type":"event_msg","payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded"}}}"#,
            #"{"timestamp":"\#(tB)","type":"event_msg","payload":{"type":"task_started"}}"#,
        ].joined(separator: "\n") + "\n")
        _ = scanner.codex(root: base.appendingPathComponent("codex"), now: now)
        let stops = scanner.codexStops(now: now)
        out.append("\(stops.map(\.sessionID) == ["sess-A"] && stops.first?.cwd == "/tmp/projA" ? "ok " : "ERRO") codex paradas por limite: \(stops.map(\.sessionID))")
        // Antigravity: banco SQLite com steps tipo 15 e blob protobuf de metadata.
        let agDir = base.appendingPathComponent("antigravity/conversations")
        try? fm.createDirectory(at: agDir, withIntermediateDirectories: true)
        let dbFile = agDir.appendingPathComponent("test-conv.db")
        func makeVarint(_ value: UInt64) -> [UInt8] {
            var v = value; var b: [UInt8] = []
            while true {
                let byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { b.append(byte | 0x80) }
                else { b.append(byte); break }
            }
            return b
        }
        func makeMeta(ts: Int64, inp: Int, out: Int, cache: Int) -> [UInt8] {
            let tsBytes = makeVarint(1 << 3 | 0) + makeVarint(UInt64(ts))
            let f1 = makeVarint(1 << 3 | 2) + makeVarint(UInt64(tsBytes.count)) + tsBytes
            var usage: [UInt8] = []
            if inp > 0 { usage += makeVarint(2 << 3 | 0) + makeVarint(UInt64(inp)) }
            if out > 0 { usage += makeVarint(3 << 3 | 0) + makeVarint(UInt64(out)) }
            if cache > 0 { usage += makeVarint(5 << 3 | 0) + makeVarint(UInt64(cache)) }
            let f9 = makeVarint(9 << 3 | 2) + makeVarint(UInt64(usage.count)) + usage
            return f1 + f9
        }
        var testDB: OpaquePointer?
        if sqlite3_open(dbFile.path, &testDB) == SQLITE_OK {
            sqlite3_exec(testDB, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB)", nil, nil, nil)
            func insertStep(idx: Int, type: Int, meta: [UInt8]) {
                var s: OpaquePointer?
                if sqlite3_prepare_v2(testDB, "INSERT INTO steps (idx, step_type, metadata) VALUES (?, ?, ?)", -1, &s, nil) == SQLITE_OK {
                    sqlite3_bind_int(s, 1, Int32(idx))
                    sqlite3_bind_int(s, 2, Int32(type))
                    _ = meta.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32($0.count), nil) }
                    sqlite3_step(s)
                    sqlite3_finalize(s)
                }
            }
            // Step 1: 1h atrás, 100 inp, 50 out, 20 cache = 170 tokens
            insertStep(idx: 1, type: 15, meta: makeMeta(ts: Int64(now.addingTimeInterval(-3600).timeIntervalSince1970), inp: 100, out: 50, cache: 20))
            // Step 2: user step (type 14) -> não conta
            insertStep(idx: 2, type: 14, meta: makeMeta(ts: Int64(now.addingTimeInterval(-3600).timeIntervalSince1970), inp: 50, out: 0, cache: 0))
            // Step 3: 3 dias atrás, 200 inp, 100 out = 300 tokens
            insertStep(idx: 3, type: 15, meta: makeMeta(ts: Int64(now.addingTimeInterval(-3 * 86400).timeIntervalSince1970), inp: 200, out: 100, cache: 0))
            // Step 4: 10 dias atrás -> expirado (> 7 dias)
            insertStep(idx: 4, type: 15, meta: makeMeta(ts: Int64(now.addingTimeInterval(-10 * 86400).timeIntervalSince1970), inp: 1000, out: 500, cache: 0))
            sqlite3_close(testDB)
        }
        check("antigravity", scanner.antigravity(roots: [agDir], now: now), 170, 470)
        check("antigravity (2ª leitura, sem duplicar)", scanner.antigravity(roots: [agDir], now: now), 170, 470)

        // Antigravity: teste com banco .db real copiado para temporário se existir
        let realDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/conversations")
        if let firstReal = (try? fm.contentsOfDirectory(at: realDir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "db" }) {
            let realCopyDir = base.appendingPathComponent("antigravity-real")
            try? fm.createDirectory(at: realCopyDir, withIntermediateDirectories: true)
            let copyTarget = realCopyDir.appendingPathComponent(firstReal.lastPathComponent)
            try? fm.copyItem(at: firstReal, to: copyTarget)
            let realScanner = TokenScanner()
            let realTokens = realScanner.antigravity(roots: [realCopyDir], now: now)
            out.append("ok antigravity banco real: 5h=\(realTokens.0) hoje=\(realTokens.1) 7d=\(realTokens.2)")
        }
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("usage-test.log"), atomically: true, encoding: .utf8)
    }
}
