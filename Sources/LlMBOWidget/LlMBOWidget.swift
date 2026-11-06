import WidgetKit
import SwiftUI
import CoreText
import LlMBOWidgetModel

// Widgets do LlMBO. Extensão à parte (Contents/PlugIns/LlMBOWidget.appex), isolada (sandbox) e com leitura só de
// ~/Library/Application Support/LlMBO/, onde o app grava widget.json. Ligada com `-e _NSExtensionMain`
// (Package.swift): sem isso o WidgetBundle.main() quebra com SIGTRAP em _EXRunningExtension._shared.

// MARK: - Dados

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snap: Sample.snapshot) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snap: Self.read() ?? (context.isPreview ? Sample.snapshot : nil)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // O app pede para redesenhar a cada mudança; isto é só a rede de segurança.
        completion(Timeline(entries: [Entry(date: .now, snap: Self.read())], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    /// Dentro do sandbox o HOME aponta para o contêiner: a pasta de verdade vem do getpwuid.
    static func read() -> WidgetSnapshot? {
        guard let pw = getpwuid(getuid()) else { return nil }
        let path = String(cString: pw.pointee.pw_dir) + "/Library/Application Support/LlMBO/" + WidgetSnapshot.fileName
        return FileManager.default.contents(atPath: path).flatMap(WidgetSnapshot.decode)
    }
}

/// Mostrado na galeria antes de haver dados.
enum Sample {
    static let snapshot = WidgetSnapshot(
        state: .holding, title: String(localized: "Segurando o Mac"), lines: ["Claude Code · hook"],
        limitsTitle: String(localized: "Limites de uso"), noLimits: "",
        limits: [.init(agent: "Claude Code", label: String(localized: "Limite de 5 horas"), short: "5 h", percent: 23, resets: ""),
                 .init(agent: "Claude Code", label: String(localized: "Limite semanal"), short: "7 d", percent: 41, resets: "")])
}

// MARK: - Visual: o do app (Theme.swift). Fundo de tinta, um bronze só, Instrument Serif nos títulos.

enum W {
    static let bg = Color(red: 8 / 255, green: 8 / 255, blue: 10 / 255)
    static let text = Color(red: 0xEC / 255, green: 0xEB / 255, blue: 0xE8 / 255)
    static let muted = Color(red: 0x8D / 255, green: 0x8A / 255, blue: 0x85 / 255)
    static let faint = Color(red: 0x55 / 255, green: 0x53 / 255, blue: 0x4F / 255)
    static let bronze2 = Color(red: 0xF6 / 255, green: 0xC5 / 255, blue: 0x8C / 255)
    static let line = Color.white.opacity(0.08)
    /// Texto das linhas: um passo acima do caption2 do sistema, como as linhas do app.
    static let body = Font.system(size: 11)

    static let fontsRegistered: Bool = {
        let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        for f in (dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }) ?? [] {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
        return true
    }()
    static func serif(_ size: CGFloat) -> Font { _ = fontsRegistered; return .custom("InstrumentSerif-Regular", size: size) }
}

/// Fundo de tinta e margem interna, por versão do macOS (cada solução só onde ela foi vista e conferida):
/// - macOS 27+: a margem automática vinha zerada ou encolhia na mesa (conteúdo colado na borda, visto em
///   06/11/2026 no 27.2); completar pelo `widgetContentMargins` não resolveu. Desliga a margem do sistema
///   (`llmboMargins()`) e põe 16 pt fixos. Conferido na mesa.
/// - macOS 14 a 26: margem automática do WidgetKit, como a Apple documenta (o sistema ajusta por contexto).
/// - macOS 13: não há margem automática nem containerBackground: 16 pt próprios e fundo comum.
struct Background: ViewModifier {
    static let margin: CGFloat = 16
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content.padding(Self.margin).containerBackground(W.bg, for: .widget)
        } else if #available(macOS 14.0, *) {
            content.containerBackground(W.bg, for: .widget)
        } else {
            content.padding(Self.margin).background(W.bg)
        }
    }
}

extension WidgetConfiguration {
    /// Desliga a margem automática só no macOS 27+, junto com os 16 pt fixos do `Background`.
    func llmboMargins() -> some WidgetConfiguration {
        if #available(macOS 27.0, *) {
            return contentMarginsDisabled()
        } else {
            return self
        }
    }
}

/// O buraco negro do ícone (BlackHoleIcon.swift), em vetor: horizonte, arcos de lente e, segurando o Mac,
/// o disco reto passando na frente. Bronze aceso segurando, cinza no repouso normal, apagado desligado.
struct Mark: View {
    let state: WidgetSnapshot.State?
    var size: CGFloat = 32

    var body: some View {
        let ink: Color = state == .holding ? W.bronze2 : (state == .normal ? W.muted : W.faint)
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let s = sz.width / 20                      // o desenho original tem 20 pt
            let lw = 1.3 * s
            // Meia elipse em volta do horizonte: a de cima sobe, a de baixo desce (y cresce para baixo aqui).
            func lens(_ ry: CGFloat, top: Bool) -> Path {
                var p = Path()
                for i in 0...32 {
                    let t = Double.pi * Double(i) / 32
                    let pt = CGPoint(x: c.x + 6.2 * s * cos(t), y: c.y + (top ? -1 : 1) * ry * s * sin(t))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            ctx.stroke(lens(7.6, top: true), with: .color(ink), lineWidth: lw)
            ctx.stroke(lens(6.0, top: false), with: .color(ink.opacity(0.55)), lineWidth: lw)
            let r = 3.4 * s
            let hole = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(hole, with: .color(W.bg))
            ctx.stroke(hole, with: .color(ink), lineWidth: lw * 0.8)
            if state == .holding {
                var disk = Path()
                disk.move(to: CGPoint(x: c.x - 9.2 * s, y: c.y))
                disk.addLine(to: CGPoint(x: c.x + 9.2 * s, y: c.y))
                ctx.stroke(disk, with: .color(W.bg), style: StrokeStyle(lineWidth: 3.6 * s, lineCap: .round))
                ctx.stroke(disk, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: state == .holding ? W.bronze2.opacity(0.35) : .clear, radius: 6)
    }
}

/// O ponto de estado do app (StatusDot): bronze aceso em quem trabalha.
struct Dot: View {
    var on: Bool
    var body: some View {
        Circle().fill(on ? W.bronze2 : W.faint).frame(width: 6, height: 6)
            .shadow(color: on ? W.bronze2.opacity(0.6) : .clear, radius: 3)
    }
}

/// "Claude Code · hook": o nome em texto claro, o motivo em cinza (como a lista de agentes do menu).
/// Linha sem " · " (ex.: "Agentes terminaram às 05:06") fica toda em cinza, sem ponto.
struct StatusLine: View {
    let text: String
    let lit: Bool
    var body: some View {
        let parts = text.components(separatedBy: " · ")
        HStack(spacing: 8) {
            if parts.count > 1 { Dot(on: lit) }
            HStack(spacing: 0) {
                if parts.count > 1 {
                    Text(verbatim: parts[0]).foregroundStyle(W.text).layoutPriority(1)
                    Text(verbatim: " · " + parts.dropFirst().joined(separator: " · ")).foregroundStyle(W.muted)
                } else {
                    Text(verbatim: text).foregroundStyle(W.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .lineLimit(parts.count > 1 ? 1 : 2)
        }
        .font(W.body)
    }
}

/// Barra da aba Uso: trilho cinza, bronze sólido.
struct Bar: View {
    let percent: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(W.line)
                Capsule().fill(W.bronze2).frame(width: max(3, g.size.width * min(max(percent, 0), 100) / 100))
            }
        }
        .frame(height: 5)
    }
}

/// Limites agrupados por agente, na ordem da aba Uso.
struct LimitGroup: Identifiable {
    let agent: String
    let rows: [WidgetSnapshot.Limit]
    var id: String { agent }

    static func make(_ limits: [WidgetSnapshot.Limit], max: Int) -> [LimitGroup] {
        var out: [LimitGroup] = []
        for l in limits.prefix(max) {
            if let last = out.last, last.agent == l.agent {
                out[out.count - 1] = LimitGroup(agent: l.agent, rows: last.rows + [l])
            } else {
                out.append(LimitGroup(agent: l.agent, rows: [l]))
            }
        }
        return out
    }
}

/// "5 h  ━━━━━━──────  23 %  Volta às 18:40". O número fica bronze a partir de 90 %, como no app.
struct LimitRow: View {
    let limit: WidgetSnapshot.Limit
    var showResets: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: limit.short).foregroundStyle(W.muted).frame(width: 28, alignment: .leading)
            Bar(percent: limit.percent)
            Text(verbatim: "\(Int(limit.percent.rounded())) %").monospacedDigit()
                .foregroundStyle(limit.percent >= 90 ? W.bronze2 : W.text)
                .frame(width: 36, alignment: .trailing)
            if showResets, !limit.resets.isEmpty {
                Text(verbatim: limit.resets).foregroundStyle(W.faint).lineLimit(1)
                    .frame(width: 92, alignment: .leading)
            }
        }
        .font(W.body)
    }
}

struct LimitList: View {
    let snap: WidgetSnapshot
    let max: Int
    var showResets = false
    var body: some View {
        if snap.limits.isEmpty {
            Text(verbatim: snap.noLimits).font(W.body).foregroundStyle(W.muted).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LimitGroup.make(snap.limits, max: max)) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: g.agent).font(W.body).foregroundStyle(W.text).lineLimit(1)
                        ForEach(Array(g.rows.enumerated()), id: \.offset) { _, l in LimitRow(limit: l, showResets: showResets) }
                    }
                }
            }
        }
    }
}

/// O bloco de estado: o buraco negro em cima, o título e as linhas embaixo (o topo e a base do widget).
struct StatusBlock: View {
    let snap: WidgetSnapshot
    let lines: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mark(state: snap.state)
            Spacer(minLength: 8)
            Text(verbatim: snap.title).font(W.serif(22)).foregroundStyle(snap.state == .off ? W.muted : W.text)
                .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(snap.lines.prefix(lines).enumerated()), id: \.offset) { _, line in
                    StatusLine(text: line, lit: snap.state == .holding)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// App nunca aberto (ou widget.json ainda não gravado): o mesmo desenho, apagado.
struct OpenApp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mark(state: nil)
            Spacer(minLength: 8)
            Text(verbatim: "LlMBO").font(W.serif(22)).foregroundStyle(W.muted)
            Text("Abra o LlMBO para ver os dados aqui.").font(W.body).foregroundStyle(W.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Widget de estado

struct StatusView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        Group {
            if let s = entry.snap {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 16) {
                        StatusBlock(snap: s, lines: 3)
                        Rectangle().fill(W.line).frame(width: 1)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: s.limitsTitle).font(W.body).foregroundStyle(W.muted)
                            LimitList(snap: s, max: 3)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    StatusBlock(snap: s, lines: 2)
                }
            } else {
                OpenApp()
            }
        }
        .modifier(Background())
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.statusKind, provider: Provider()) { StatusView(entry: $0) }
            .configurationDisplayName("LlMBO")
            .description(String(localized: "Se o LlMBO está segurando o Mac, por quê, e quando os agentes terminaram."))
            .supportedFamilies([.systemSmall, .systemMedium])
            .llmboMargins()
    }
}

// MARK: - Widget de limites de uso

struct LimitsView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        Group {
            if let s = entry.snap {
                let big = family == .systemMedium
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: s.limitsTitle).font(W.serif(20)).foregroundStyle(W.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Dot(on: s.state == .holding)
                    }
                    LimitList(snap: s, max: big ? 3 : 2, showResets: big)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                OpenApp()
            }
        }
        .modifier(Background())
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.limitsKind, provider: Provider()) { LimitsView(entry: $0) }
            .configurationDisplayName(String(localized: "Limites de uso"))
            .description(String(localized: "Quanto dos limites do Claude Code, do Codex e do Antigravity já foi usado, e quando eles voltam."))
            .supportedFamilies([.systemSmall, .systemMedium])
            .llmboMargins()
    }
}

@main
struct LlMBOWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        LimitsWidget()
    }
}
