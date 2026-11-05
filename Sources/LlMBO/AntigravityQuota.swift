import Foundation

/// Um grupo de modelos do Antigravity com limites próprios (ex.: "Gemini Models", "Claude and GPT models").
struct LimitGroup: Equatable {
    let name: String
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?

    /// A janela mais usada, para a barra da aba Uso.
    var fullest: (title: String, window: LimitWindow)? {
        let all: [(String, LimitWindow)] = [
            fiveHour.map { (String(localized: "Limite de 5 horas"), $0) },
            weekly.map { (String(localized: "Limite semanal"), $0) },
        ].compactMap { $0 }
        return all.max { $0.1.usedPercent < $1.1.usedPercent }.map { (title: $0.0, window: $0.1) }
    }
}

/// Cota do Antigravity pelo servidor local que o app e o IDE abrem (o "hub" do `agy --hub`).
/// Ele grava a porta e um token de uso local em ~/.gemini/antigravity/daemon/hub_<porta>.json; o LlMBO
/// pergunta a cota em http://127.0.0.1:<porta> (método `RetrieveUserQuotaSummary`, protocolo Connect
/// em JSON, cabeçalho `x-codeium-csrf-token`). Quem fala com o Google é o próprio Antigravity: o LlMBO
/// não sai do Mac, não lê o login da conta e não guarda o token. Endereço interno, sem documentação
/// (descoberto em 02/11/2026 no agy 2.28.2): se mudar, a leitura só volta vazia.
/// Opcional (aba Uso, `antigravityQuota`, desligado por padrão) e só com um Antigravity na lista.
enum AntigravityQuota {
    static let defaultsKey = "antigravityQuota"
    nonisolated(unsafe) static var homeOverride: URL?

    private static var daemonDirs: [URL] {
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        return ["antigravity", "antigravity-ide"].map { home.appendingPathComponent(".gemini/\($0)/daemon") }
    }

    /// Hubs abertos agora: (porta, token). Arquivo de processo que já terminou é ignorado.
    static func hubs() -> [(port: Int, token: String)] {
        let fm = FileManager.default
        var out: [(Int, String)] = []
        for dir in daemonDirs {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix("hub_") && url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0,
                      let port = (obj["httpPort"] as? NSNumber)?.intValue, (1...65535).contains(port),
                      let token = obj["csrfToken"] as? String, !token.isEmpty else { continue }
                out.append((port, token))
            }
        }
        return out
    }

    /// Lê a cota do primeiro hub que responder. nil = nenhum Antigravity aberto ou resposta inesperada.
    static func read(now: Date) -> [LimitGroup]? {
        for hub in hubs() {
            // Sempre 127.0.0.1: nunca outro endereço, mesmo que o arquivo diga outra coisa.
            guard let url = URL(string: "http://127.0.0.1:\(hub.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
            else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            req.setValue(hub.token, forHTTPHeaderField: "x-codeium-csrf-token")
            req.httpBody = Data("{}".utf8)
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]   // sem proxy: é só a própria máquina
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let done = DispatchSemaphore(value: 0)
            var body: Data?
            var answered = false
            session.dataTask(with: req) { data, resp, _ in
                answered = resp != nil
                if (resp as? HTTPURLResponse)?.statusCode == 200 { body = data }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 6)
            if let body, let groups = parse(body, now: now) {
                Canaries.report("antigravity-quota", .usage, problem: nil)
                return groups
            }
            // O hub está vivo e respondeu, mas não como esperado: o endereço interno ou o formato mudou.
            if answered {
                Canaries.report("antigravity-quota", .usage, problem: String(localized: "O Antigravity respondeu, mas não consegui ler a cota: o formato mudou numa versão nova dele."))
            }
        }
        return nil
    }

    /// {"response":{"groups":[{"displayName", "buckets":[{"window":"5h"|"weekly", "remainingFraction", "resetTime"}]}]}}
    /// `remainingFraction` some quando é 0 (JSON do protobuf omite o zero). Janela que já voltou some.
    static func parse(_ data: Data, now: Date) -> [LimitGroup]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = (root["response"] as? [String: Any])?["groups"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [LimitGroup] = []
        for g in groups {
            var group = LimitGroup(name: g["displayName"] as? String ?? "Antigravity")
            for b in g["buckets"] as? [[String: Any]] ?? [] {
                guard let s = b["resetTime"] as? String,
                      let reset = iso.date(from: s) ?? isoFrac.date(from: s), reset > now else { continue }
                let remaining = (b["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
                let w = LimitWindow(usedPercent: min(max((1 - remaining) * 100, 0), 100), resetsAt: reset)
                switch b["window"] as? String {
                case "5h": group.fiveHour = w
                case "weekly": group.weekly = w
                default: break
                }
            }
            if group.fiveHour != nil || group.weekly != nil { out.append(group) }
        }
        return out
    }

    /// Hora em que o Antigravity pode voltar depois do limite em `hitAt`. Cada grupo cheio (≥ 99 %) fica
    /// travado até a última janela cheia dele voltar; vale o grupo que volta primeiro (não se sabe qual
    /// modelo parou; acordar cedo demais só faz o Mac dormir de novo). Sem grupo cheio, nil.
    static func reset(_ groups: [LimitGroup], hitAt: Date) -> Date? {
        groups.compactMap { g in
            [g.fiveHour, g.weekly].compactMap { $0 }
                .filter { $0.usedPercent >= 99 && $0.resetsAt > hitAt }
                .map(\.resetsAt).max()
        }.min()
    }

    /// LLMBO_TEST_AGQUOTA=1: resposta gravada, hub falso (servidor local de teste) e regra do reset.
    /// Grava antigravity-quota-test.log.
    static func selfTest() {
        var out: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append("\(ok ? "ok " : "ERRO") \(name) \(detail)") }
        let now = Date()
        let iso = ISO8601DateFormatter()
        let r1 = iso.string(from: now.addingTimeInterval(2 * 3600))
        let r2 = iso.string(from: now.addingTimeInterval(4 * 86400))
        let r3 = iso.string(from: now.addingTimeInterval(30 * 3600))
        let past = iso.string(from: now.addingTimeInterval(-60))
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.69,"resetTime":"\(r2)"},
            {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9365,"resetTime":"\(r1)"}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"window":"weekly","remainingFraction":1,"resetTime":"\(r2)"},
            {"window":"5h","remainingFraction":1,"resetTime":"\(past)"}]},
          {"displayName":"Gemini 4 Argon","buckets":[{"window":"weekly","resetTime":"\(r3)"}]}]}}
        """
        let g = parse(Data(json.utf8), now: now) ?? []
        check("grupos", g.map(\.name) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"], "\(g.map(\.name))")
        check("5h usado", abs((g.first?.fiveHour?.usedPercent ?? -1) - 6.35) < 0.01, "\(g.first?.fiveHour?.usedPercent ?? -1)")
        check("janela vencida some", g.count > 1 && g[1].fiveHour == nil)
        check("remainingFraction ausente = 100 %", g.last?.weekly?.usedPercent == 100)
        check("reset = grupo cheio", reset(g, hitAt: now) == g.last?.weekly?.resetsAt)
        check("sem grupo cheio, sem reset", reset(Array(g.prefix(2)), hitAt: now) == nil)
        check("lixo não quebra", parse(Data("{\"code\":\"unauthenticated\"}".utf8), now: now) == nil)

        // Hub falso: pasta temporária com hub_*.json do próprio pid e um servidor de teste em 127.0.0.1.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("llmbo-agquota-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base); homeOverride = nil }
        homeOverride = base
        let dir = base.appendingPathComponent(".gemini/antigravity/daemon")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        check("sem hub, nil", read(now: now) == nil)
        try? #"{"pid":999999,"httpPort":1,"csrfToken":"x"}"#.write(to: dir.appendingPathComponent("hub_1.json"), atomically: true, encoding: .utf8)
        check("hub de processo morto ignorado", hubs().isEmpty)
        if let server = TestServer(token: "tok", body: json) {
            try? #"{"pid":\#(getpid()),"httpPort":\#(server.port),"csrfToken":"tok"}"#
                .write(to: dir.appendingPathComponent("hub_\(server.port).json"), atomically: true, encoding: .utf8)
            let live = read(now: now)
            check("hub falso responde", live?.count == 3, "\(live?.count ?? -1) grupos, porta \(server.port)")
            check("token enviado no cabeçalho", server.sawToken)
            server.stop()
        } else {
            check("servidor de teste", false, "não abriu a porta")
        }
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("antigravity-quota-test.log"), atomically: true, encoding: .utf8)
    }
}

/// Servidor HTTP mínimo em 127.0.0.1 só para o teste: responde 200 com `body` se o token vier no cabeçalho.
private final class TestServer {
    let port: Int
    private let fd: Int32
    private(set) var sawToken = false

    init?(token: String, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { close(fd); return nil }
        self.fd = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(c, &buf, buf.count)
                let req = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).lowercased() : ""
                let ok = req.contains("x-codeium-csrf-token: \(token.lowercased())")
                if ok { self?.sawToken = true }
                let payload = ok ? body : #"{"code":"unauthenticated"}"#
                let resp = "HTTP/1.1 \(ok ? "200 OK" : "401 Unauthorized")\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
                _ = resp.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { close(fd) }
}
