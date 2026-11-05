import SwiftUI
import CoreText

/// Identidade visual do LlMBO, a mesma do site (website/index.html): fundo quase preto, linhas finas,
/// bronze como cor de destaque e Instrument Serif nos títulos. O app é sempre escuro, como o site.
enum Theme {
    static let bg = Color(hex: 0x08080A)
    static let bg2 = Color(hex: 0x0E0E12)
    static let card = Color.white.opacity(0.03)
    static let cardHover = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.08)
    static let text = Color(hex: 0xECEBE8)
    static let muted = Color(hex: 0x8D8A85)
    static let faint = Color(hex: 0x55534F)
    static let bronze1 = Color(hex: 0xC8B49A)
    static let bronze2 = Color(hex: 0xF6C58C)
    static let bronze3 = Color(hex: 0xB8763A)
    /// Interruptores e controles ligados: um bronze mais fechado, para o botão branco aparecer.
    static let control = Color(hex: 0xC4874A)
    static let danger = Color(hex: 0xE5786D)
    static let bronze = LinearGradient(stops: [.init(color: bronze1, location: 0), .init(color: bronze2, location: 0.55),
                                               .init(color: bronze3, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
    static let nsBackground = NSColor(srgbRed: 8 / 255, green: 8 / 255, blue: 10 / 255, alpha: 1)
    static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }

    /// Instrument Serif vem em Resources/Fonts (os mesmos .woff2 do site; o CoreText lê woff2).
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }

    /// Janela no visual do site: escura, fundo próprio e barra de título transparente.
    @MainActor static func style(_ w: NSWindow) {
        w.appearance = appearance
        w.backgroundColor = nsBackground
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Peças

/// Bloco de borda fina e cantos arredondados, como os cartões do site.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16)
    }
}

/// Título de seção em versalete bronze, como os "kickers" do site; ⓘ opcional ao lado.
struct Kicker: View {
    let text: String
    var info: String? = nil

    init(_ text: String, info: String? = nil) {
        self.text = text
        self.info = info
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased(with: Locale.current))
                .font(.system(size: 10.5, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.bronze2)
            if let info { InfoButton(text: info) }
        }
        .padding(.leading, 4)
        .padding(.bottom, 8)
    }
}

/// Kicker + cartão: a unidade das abas.
struct CardSection<Content: View>: View {
    let title: String?
    var info: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { Kicker(title, info: info) }
            Card { content }
        }
    }
}

/// Linha "título ······ controle" dentro de um cartão.
struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil
    /// O ⓘ vira um triângulo de atenção (bronze): o texto avisa de uma limitação, não só explica.
    var warning = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).foregroundStyle(Theme.text)
                    if let info { InfoButton(text: info, warning: warning) }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, subtitle: subtitle, info: info) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .handCursor()
                .labelsHidden()
                .tint(Theme.control)
        }
    }
}

/// Ponto de estado: bronze com brilho quando trabalhando (como no site), cinza quando parado.
struct StatusDot: View {
    let active: Bool
    var running = false

    var body: some View {
        Circle()
            .fill(active ? Theme.bronze2 : (running ? Theme.muted : Theme.faint))
            .frame(width: 7, height: 7)
            .shadow(color: active ? Theme.bronze2.opacity(0.9) : .clear, radius: 5)
    }
}

/// Botões em pílula, como os do site: claro (principal), contorno (secundário) e de remoção.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, kind: kind)
    }

    private struct PillLabel: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .foregroundStyle(foreground)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(kind == .primary ? Color.clear : Theme.line))
                .contentShape(Capsule())
                .handCursor()
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Color(hex: 0x0A0A0C)
            case .secondary: return Theme.text
            case .destructive: return Theme.danger
            }
        }

        private var fill: Color {
            kind == .primary ? Theme.text : Color.white.opacity(0.04)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ kind: PillButtonStyle.Kind) -> PillButtonStyle { PillButtonStyle(kind: kind) }
}

/// Título com botão ⓘ ao lado: a explicação fica num balão em vez de texto fixo na aba.
struct InfoTitle: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(text: info)
        }
    }
}

struct InfoButton: View {
    let text: String
    var warning = false
    @StateObject private var popover = PopoverState()

    var body: some View {
        Button { popover.shown.toggle() } label: {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(warning || popover.shown ? Theme.bronze2 : Theme.muted)
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(String(localized: "Mais informações"))
        .popover(isPresented: $popover.shown, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(16)
                .preferredColorScheme(.dark)
        }
    }
}

/// Estado do balão fora de @State (no SDK do macOS 27 @State é macro; ver CLAUDE.md).
final class PopoverState: ObservableObject {
    @Published var shown = false
}

/// Controle deslizante no visual do app: trilho fino, parte preenchida em bronze e botão redondo claro.
/// `onEnd` roda ao soltar (ex.: tocar uma amostra do som no volume escolhido).
struct ThemedSlider: View {
    @Binding var value: Double
    let title: String
    var range: ClosedRange<Double> = 0...1
    /// Passo entre os valores (nil = contínuo); também é o passo do VoiceOver.
    var step: Double? = nil
    var onEnd: () -> Void = {}

    private func fit(_ v: Double) -> Double {
        var v = min(max(v, range.lowerBound), range.upperBound)
        if let step { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { g in
            let knob: CGFloat = 14
            let span = range.upperBound - range.lowerBound
            let x = CGFloat((fit(value) - range.lowerBound) / span) * (g.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 4)
                Capsule().fill(Theme.bronze).frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(Theme.text)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let f = Double((v.location.x - knob / 2) / (g.size.width - knob))
                    let new = fit(range.lowerBound + f * span)
                    if new != value { value = new }
                }
                .onEnded { _ in onEnd() })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: "\(Int((value * 100).rounded())) %"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = fit(value + (step ?? 0.1))
            case .decrement: value = fit(value - (step ?? 0.1))
            @unknown default: break
            }
            onEnd()
        }
    }
}

// MARK: - Cursor

/// Mão de link sobre o que é clicável: botões, interruptores e listas do SwiftUI no macOS não trocam o cursor
/// sozinhos. Uma NSView transparente por cima (não recebe cliques) segue o mouse com uma área de rastreio
/// `.activeAlways` — vale também no popover da barra, que abre sem ativar o app. Some com o controle apagado.
struct HandCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.overlay(enabled ? HandCursorArea() : nil)
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursor()) }
}

private struct HandCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> HandCursorNSView { HandCursorNSView() }
    func updateNSView(_ view: HandCursorNSView, context: Context) {}
    static func dismantleNSView(_ view: HandCursorNSView, coordinator: ()) { view.leave() }
}

final class HandCursorNSView: NSView {
    private var inside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { inside = true; NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { if inside { NSCursor.pointingHand.set() } }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { leave() }

    /// Sai da área (ou o controle some debaixo do mouse, como ao trocar de aba): volta a seta.
    func leave() {
        if inside { NSCursor.arrow.set() }
        inside = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { leave() }
        super.viewWillMove(toWindow: newWindow)
    }
}


/// Selo pequeno "BETA" em bronze ao lado da versão; a dica explica o porquê.
struct BetaBadge: View {
    var body: some View {
        Text(verbatim: "BETA")
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.bronze2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bronze2.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.bronze2.opacity(0.55), lineWidth: 0.8))
            .help(String(localized: "Versão de testes: por enquanto o LlMBO foi testado em poucos Macs e com poucos agentes. Se algo der errado, use Relatar problema."))
    }
}
