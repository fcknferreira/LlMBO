import Foundation
import WidgetKit
import LlMBOWidgetModel

/// Alimenta os widgets: monta o `WidgetSnapshot` a partir do Engine e do UsageStore, grava `widget.json` em
/// Application Support/LlMBO só quando muda e pede ao macOS para redesenhar. O widget roda isolado (sandbox) e só
/// lê esse arquivo (exceção de leitura da pasta, Resources/Widget.entitlements).
@MainActor
enum WidgetFeed {
    static let file = Paths.support.appendingPathComponent(WidgetSnapshot.fileName)
    private static var last: Data?

    /// Chamado no fim de cada tick do Engine (a cada 5 s) e quando o uso é relido.
    static func update(_ engine: Engine, now: Date = Date()) {
        let snap = snapshot(engine, usage: UsageStore.shared.byAgent, now: now)
        guard let data = snap.encoded(), data != last else { return }
        last = data
        try? data.write(to: file, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func snapshot(_ e: Engine, usage: [String: AgentUsage], now: Date) -> WidgetSnapshot {
        let state: WidgetSnapshot.State = !e.armed ? .off : (e.holding ? .holding : .normal)
        let title: String
        var lines: [String] = []
        switch state {
        case .off:
            title = String(localized: "LlMBO desligado")
            lines = [String(localized: "O Mac dorme como sempre.")]
        case .holding:
            title = String(localized: "Segurando o Mac")
            lines = e.statuses.filter(\.active).map { s in [s.name, s.reason].compactMap { $0 }.joined(separator: " · ") }
            lines += e.holds.map { "\(String(localized: "Tarefa longa")) · \($0.name)" }
            if lines.isEmpty, let back = e.sleepReturnsAt, back > now {
                lines = [String(localized: "O repouso normal volta às \(UsageFormat.when(back)).")]
            }
        case .normal:
            title = String(localized: "Repouso normal")
            if let t = e.lastFinishedAt, now.timeIntervalSince(t) < 24 * 3600 {
                lines = [String(localized: "Agentes terminaram às \(UsageFormat.when(t))")]
            } else {
                lines = [String(localized: "Nenhum agente trabalhando.")]
            }
        }
        return WidgetSnapshot(state: state, title: title, lines: Array(lines.prefix(4)),
                              limitsTitle: String(localized: "Limites de uso"),
                              noLimits: String(localized: "Sem limites lidos ainda. Veja a aba Uso."),
                              limits: limits(e, usage: usage, now: now))
    }

    /// LLMBO_TEST_WIDGET=1: limites de cada agente, janela vencida, grupos do Antigravity, ida e volta do JSON e a
    /// gravação de widget.json. Grava widget-test.log.
    static func selfTest(_ e: Engine) {
        var out: [String] = []
        func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "ok " : "ERRO") \(name)") }
        let now = Date()
        func w(_ pct: Double, _ min: Double) -> LimitWindow { LimitWindow(usedPercent: pct, resetsAt: now.addingTimeInterval(min * 60)) }
        var ag = AgentUsage()
        ag.groups = [LimitGroup(name: "Gemini", fiveHour: w(30, 60), weekly: w(70, 3000)),
                     LimitGroup(name: "Claude", fiveHour: w(10, -5), weekly: nil)]
        let usage = ["claude": AgentUsage(fiveHour: w(23, 90), weekly: w(41, 5000)),
                     "codex": AgentUsage(fiveHour: w(50, -1), weekly: w(12, 2000)),
                     "antigravity": ag]
        let l = limits(e, usage: usage, now: now)
        check("Claude: 5 h e semanal, nessa ordem", l.count >= 2 && l[0].percent == 23 && l[1].percent == 41)
        check("Codex: janela vencida some, semanal fica", l.filter { $0.agent.hasPrefix("Codex") }.map(\.percent) == [12])
        check("Antigravity: um grupo por linha, a janela mais usada",
              l.filter { $0.agent.contains("Gemini") }.map(\.percent) == [70])
        check("Antigravity: grupo só com janela vencida some", !l.contains { $0.agent.contains("· Claude") })
        check("ordem da aba Uso (Claude, Codex, Antigravity)", l.map(\.agent).first == "Claude Code" && l.last?.agent.contains("Gemini") == true)
        let snap = snapshot(e, usage: usage, now: now)
        check("JSON ida e volta", snap.encoded().flatMap(WidgetSnapshot.decode) == snap)
        check("estado bate com o Engine", snap.state == (!e.armed ? .off : (e.holding ? .holding : .normal)))
        check("vazio: sem limites", limits(e, usage: [:], now: now).isEmpty)
        last = nil
        update(e, now: now)
        check("widget.json gravado e legível", (try? Data(contentsOf: file)).flatMap(WidgetSnapshot.decode) != nil)
        try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("widget-test.log"),
                                               atomically: true, encoding: .utf8)
    }

    static func limits(_ e: Engine, usage: [String: AgentUsage], now: Date) -> [WidgetSnapshot.Limit] {
        func name(_ id: String) -> String {
            (e.agents.first { $0.id == id } ?? AgentConfig.catalog.first { $0.id == id })?.name ?? id
        }
        func rows(_ agent: String, five: LimitWindow?, week: LimitWindow?) -> [WidgetSnapshot.Limit] {
            var out: [WidgetSnapshot.Limit] = []
            if let w = five, w.resetsAt > now {
                out.append(.init(agent: agent, label: String(localized: "Limite de 5 horas"),
                                 short: String(localized: "5 h", comment: "limite de 5 horas, curto"),
                                 percent: w.usedPercent, resets: UsageFormat.resets(w.resetsAt)))
            }
            if let w = week, w.resetsAt > now {
                out.append(.init(agent: agent, label: String(localized: "Limite semanal"),
                                 short: String(localized: "7 d", comment: "limite semanal, curto"),
                                 percent: w.usedPercent, resets: UsageFormat.resets(w.resetsAt)))
            }
            return out
        }
        var all: [WidgetSnapshot.Limit] = []
        for id in UsageStore.order {
            guard let u = usage[id] else { continue }
            if !u.groups.isEmpty {
                // Antigravity: um grupo de modelos por linha, com a janela mais usada.
                for g in u.groups {
                    let r = rows("\(name(id)) · \(g.name)", five: g.fiveHour, week: g.weekly)
                    if let top = r.max(by: { $0.percent < $1.percent }) { all.append(top) }
                }
            } else {
                all += rows(name(id), five: u.fiveHour, week: u.weekly)
            }
        }
        return all
    }
}
