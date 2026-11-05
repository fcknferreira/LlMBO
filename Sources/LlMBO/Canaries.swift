import SwiftUI

/// Canários: avisos de que uma integração parou de funcionar em silêncio. Quase tudo que o LlMBO lê é formato de
/// outros apps (hooks, texto do /usage, endereço do hub do Antigravity, transcritos, chaves do IOKit); quando um
/// deles muda, nada dá erro, o sinal só some. Cada canário aparece numa linha discreta na aba do assunto enquanto
/// o problema durar e vai uma vez para o app.log (que o "Relatar problema…" leva junto).
@MainActor final class Canaries: ObservableObject {
    static let shared = Canaries()

    enum Area { case agents, usage, system }

    struct Issue: Identifiable, Equatable {
        let id: String
        let area: Area
        let text: String
    }

    @Published private(set) var issues: [String: Issue] = [:]

    func raise(_ id: String, _ area: Area, _ text: String) {
        guard issues[id]?.text != text else { return }
        issues[id] = Issue(id: id, area: area, text: text)
        AppLog.write("canário \(id): \(text)")
    }

    func clear(_ id: String) {
        guard issues.removeValue(forKey: id) != nil else { return }
        AppLog.write("canário \(id): voltou ao normal")
    }

    func list(_ area: Area) -> [Issue] {
        issues.values.filter { $0.area == area }.sorted { $0.id < $1.id }
    }

    /// Para as filas de leitura (UsageStore, GPU): o resultado vai para o canário na fila principal.
    nonisolated static func report(_ id: String, _ area: Area, problem: String?) {
        Task { @MainActor in
            if let problem { shared.raise(id, area, problem) } else { shared.clear(id) }
        }
    }
}

/// Linhas de aviso dos canários de uma área, no topo da aba. Some quando não há nada.
struct CanaryNotes: View {
    @ObservedObject private var canaries = Canaries.shared
    let area: Canaries.Area

    var body: some View {
        let list = canaries.list(area)
        if !list.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Theme.bronze)
                            Text(issue.text)
                                .font(.callout)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
