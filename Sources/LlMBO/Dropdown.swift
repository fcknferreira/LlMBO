import SwiftUI

/// Lista suspensa no visual do LlMBO (no lugar do menu nativo, que só vem com o destaque azul do sistema):
/// botão em pílula e, ao clicar, um balão escuro com grupos em versalete bronze, destaque ao passar o mouse
/// e o item escolhido marcado em bronze. Esc ou um clique fora fecha.
struct DropdownItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

struct DropdownGroup<ID: Hashable>: Identifiable {
    var title: String? = nil
    let items: [DropdownItem<ID>]
    var id: String { title ?? "_" }
}

/// Ação extra no fim da lista (ex.: "Outro agente (personalizado)…").
struct DropdownFooter {
    let title: String
    let symbol: String
    let action: () -> Void
}

struct Dropdown<ID: Hashable, Label: View>: View {
    let groups: [DropdownGroup<ID>]
    var selection: ID? = nil
    var width: CGFloat = 240
    var footer: DropdownFooter? = nil
    let onSelect: (ID) -> Void
    @ViewBuilder var label: Label
    @StateObject private var state = PopoverState()

    var body: some View {
        Button { state.shown.toggle() } label: { label }
            .buttonStyle(.plain)
            .popover(isPresented: $state.shown, arrowEdge: .bottom) {
                DropdownList(groups: groups, selection: selection, width: width, footer: footer.map { f in
                    DropdownFooter(title: f.title, symbol: f.symbol) { close(then: f.action) }
                }) { id in
                    close { onSelect(id) }
                }
            }
    }

    /// Fecha o balão antes da ação: abrir uma folha com o balão ainda na tela atrapalha a apresentação.
    private func close(then action: @escaping () -> Void) {
        state.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
    }
}

/// Rótulo em pílula para o Dropdown: texto (e ícone opcional) com a setinha dupla em bronze.
struct DropdownLabel: View {
    let text: String
    var symbol: String? = nil
    var prominent = false
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            }
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(prominent ? Color(hex: 0x0A0A0C).opacity(0.6) : Theme.bronze2)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(prominent ? Color(hex: 0x0A0A0C) : Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(prominent ? Theme.text : Color.white.opacity(hover.on ? 0.08 : 0.04)))
        .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.line))
        .contentShape(Capsule())
        .fixedSize()
        .onHover { hover.on = $0 }
    }
}

struct DropdownList<ID: Hashable>: View {
    let groups: [DropdownGroup<ID>]
    let selection: ID?
    let width: CGFloat
    let footer: DropdownFooter?
    let onSelect: (ID) -> Void

    private static var rowHeight: CGFloat { 28 }
    private static var headerHeight: CGFloat { 28 }
    private static var maxHeight: CGFloat { 340 }

    /// Altura do conteúdo (o ScrollView não informa a própria): linhas + títulos de grupo + margens.
    private var contentHeight: CGFloat {
        let rows = CGFloat(groups.reduce(0) { $0 + $1.items.count }) * Self.rowHeight
        let headers = CGFloat(groups.filter { $0.title != nil }.count) * Self.headerHeight
        return rows + headers + 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { g in
                            if let t = g.title {
                                Text(t.uppercased(with: Locale.current))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .tracking(1.4)
                                    .foregroundStyle(Theme.bronze2)
                                    .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 0)
                            }
                            ForEach(g.items) { item in
                                DropdownRow(title: item.title, symbol: nil, selected: item.id == selection) {
                                    onSelect(item.id)
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(contentHeight, Self.maxHeight))
                .onAppear {
                    if let selection, contentHeight > Self.maxHeight { proxy.scrollTo(selection, anchor: .center) }
                }
            }
            if let footer {
                Rectangle().fill(Theme.line).frame(height: 1)
                DropdownRow(title: footer.title, symbol: footer.symbol, selected: false, action: footer.action)
                    .padding(6)
            }
        }
        .frame(width: width)
        .background(Theme.bg2)
        .preferredColorScheme(.dark)
    }
}

private struct DropdownRow: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(Theme.bronze2)
                    } else {
                        Image(systemName: "checkmark").foregroundStyle(Theme.bronze2).opacity(selected ? 1 : 0)
                    }
                }
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 14)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.bronze2 : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.on ? Theme.cardHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// Estado de "mouse em cima" fora de @State (no SDK do macOS 27 @State é macro; ver CLAUDE.md).
final class HoverFlag: ObservableObject {
    @Published var on = false
}
