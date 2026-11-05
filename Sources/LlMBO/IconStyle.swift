import SwiftUI

/// As duas versões do ícone do app (cores invertidas), geradas por Design/render_icon.swift.
enum IconStyle: String, CaseIterable, Identifiable {
    case dark, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return String(localized: "Escuro")
        case .light: return String(localized: "Claro")
        }
    }

    var image: NSImage {
        let name = self == .dark ? "AppIcon" : "AppIconLight"
        return Bundle.main.image(forResource: name) ?? NSApp.applicationIconImage
    }

    /// Troca o ícone usado pelo app em tempo de execução (janelas, alertas, popover).
    func apply() {
        NSApp.applicationIconImage = image
    }
}

/// Miniatura clicável do ícone, como o seletor de Aparência dos Ajustes do Sistema.
struct IconChoice: View {
    let style: IconStyle
    let selected: Bool
    var size: CGFloat = 56
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: style.image)
                    .resizable()
                    .frame(width: size, height: size)
                    .padding(size * 0.06)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .strokeBorder(selected ? Theme.bronze2 : Color.clear, lineWidth: size > 30 ? 3 : 2)
                    )
                if showsTitle {
                    Text(style.title)
                        .font(.system(size: 11, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Ícone \(style.title.lowercased())"))
        .accessibilityLabel(String(localized: "Ícone \(style.title.lowercased())"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
