import SwiftUI

/// Popover da barra de menus, no estilo dos menus da Central de Controle.
struct MenuView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StatusGlyph(armed: engine.armed)
                    .shadow(color: Theme.bronze2.opacity(engine.armed ? 0.3 : 0), radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LlMBO").font(Theme.serif(19)).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        StatusDot(active: engine.armed && (engine.statuses.contains(where: \.active) || !engine.holds.isEmpty), running: engine.armed)
                        Text(engine.statusLine)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Toggle("Liberar tampa fechada", isOn: engine.armedBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.control)
                    .disabled(!engine.helperInstalled)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if !engine.helperInstalled {
                PermissionCallout().padding(.horizontal, 10).padding(.bottom, 8)
            }

            MenuDivider()

            SectionLabel(String(localized: "Agentes"))
            // Só os abertos: com muitos agentes cadastrados, o popover continua curto.
            let open = engine.statuses.filter { $0.running || $0.active }
            if open.isEmpty {
                Text("Nenhum agente aberto")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
            }
            ForEach(open) { s in
                AgentRow(status: s, compact: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
            }

            if !engine.holds.isEmpty {
                SectionLabel(String(localized: "Tarefas longas"))
                ForEach(engine.holds) { t in
                    HoldRow(task: t)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                }
            }

            if let m = engine.message {
                Text(m)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            MenuDivider().padding(.top, 6)

            HStack {
                Text("Ícone do app").font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                ForEach(IconStyle.allCases) { style in
                    IconChoice(style: style, selected: engine.iconStyle == style, size: 22, showsTitle: false) {
                        engine.iconStyle = style
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)

            MenuDivider()

            VStack(spacing: 0) {
                if let r = updater.available {
                    MenuRow(String(localized: "Atualizar para a versão \(r.version)…")) {
                        MainTabModel.shared.tab = .about
                        AppDelegate.shared.showMainWindow()
                    }
                }
                MenuRow(String(localized: "Abrir LlMBO…")) { AppDelegate.shared.showMainWindow() }
                MenuRow(String(localized: "Configurar agentes…")) {
                    AppDelegate.shared.closeMenu()
                    engine.openConfig()
                }
                MenuDivider()
                MenuRow(String(localized: "Sair do LlMBO"), shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 5)
        }
        .frame(width: 310)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Peças

/// Ícone do app: apagado em repouso, em cores quando o Mac está acordado esperando os agentes.
struct StatusGlyph: View {
    @EnvironmentObject var engine: Engine
    let armed: Bool
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: engine.iconStyle.image)
            .resizable()
            .frame(width: size, height: size)
            .saturation(armed ? 1 : 0)
            .opacity(armed ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.2), value: armed)
    }
}

struct AgentRow: View {
    let status: AgentStatus
    /// No popover o ponto verde já diz "trabalhando": mostra só o motivo, para caber numa linha.
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(active: status.active, running: status.running)
            Text(status.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            Text(compact ? status.shortLabel : status.label)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(status.active ? Theme.bronze2 : Theme.muted)
                .monospacedDigit()
        }
    }
}

/// Tarefa longa no popover: nome e até quando segura (processo ou hora).
struct HoldRow: View {
    let task: HoldTask

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(active: true, running: true)
            Text(task.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(Theme.bronze2)
                .monospacedDigit()
        }
    }

    private var detail: String {
        if let until = task.until, task.pid == nil {
            return String(localized: "até \(UsageFormat.when(until))")
        }
        return task.source == "mcp" ? String(localized: "pedido pelo agente") : String(localized: "enquanto roda")
    }
}

struct PermissionCallout: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.bronze2)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 8) {
                Text("Para mexer no repouso, o LlMBO precisa de uma permissão de administrador (uma vez só).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Instalar permissão…") { engine.installHelper() }
                    .buttonStyle(.pill(.primary))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bronze2.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.bronze2.opacity(0.18)))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased(with: Locale.current))
            .font(.system(size: 10, weight: .medium))
            .tracking(1.4)
            .foregroundStyle(Theme.bronze2)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 5)
    }
}

/// Linha clicável com destaque ao passar o mouse, como um item de menu.
private struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    // @State virou macro no SDK do macOS 27 e as Command Line Tools não trazem o plugin; @StateObject funciona.
    @StateObject private var hoverState = HoverState()
    private var hover: Bool { hoverState.on }

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Theme.cardHover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hoverState.on = $0 }
    }
}

private final class HoverState: ObservableObject {
    @Published var on = false
}

// MARK: - Textos

extension AgentStatus {
    var shortLabel: String {
        guard active, let r = reason else { return label }
        return r.prefix(1).uppercased() + r.dropFirst()
    }

    var label: String {
        if waitingApproval { return String(localized: "Aguardando aprovação") }
        if waitingQuota {
            guard let r = quotaReset else { return String(localized: "Aguardando o limite") }
            return String(localized: "Aguardando o limite · volta às \(UsageFormat.when(r))")
        }
        if active { return reason.map { String(localized: "Trabalhando · \($0)") } ?? String(localized: "Trabalhando") }
        if waitingHook { return String(localized: "Aberto · aguardando o hook") }
        if ignoredNoHook { return String(localized: "Aberto · sem hook, não conta") }
        return running ? String(localized: "Ocioso") : String(localized: "Fechado")
    }
}

extension Engine {
    var armedBinding: Binding<Bool> {
        Binding(get: { self.armed }, set: { $0 ? self.arm() : self.disarm() })
    }

    var statusLine: String {
        if !helperInstalled { return String(localized: "Permissão necessária") }
        guard armed else { return String(localized: "Desligado · repouso normal") }
        let n = statuses.filter(\.active).count
        switch n {
        case 0: return String(localized: "Ligado · nenhum agente ativo")
        case 1: return String(localized: "Ligado · 1 agente trabalhando")
        default: return String(localized: "Ligado · \(n) agentes trabalhando")
        }
    }
}
