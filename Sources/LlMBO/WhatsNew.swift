import Foundation

/// Novidades depois de uma atualização. Discretas de propósito: nada abre nem pisca sozinho; aparecem só como
/// uma linha no menu do ícone, que a pessoa abre quando quiser, e somem depois de lidas.
/// Cada versão publicada ganha de 1 a 4 frases curtas (~5 palavras: o menu tem 310 pt e o alemão é comprido).
/// O release.sh recusa publicar uma versão sem entrada aqui.
@MainActor
final class WhatsNew: ObservableObject {
    static let shared = WhatsNew()

    /// Mais nova primeiro. Texto em `String(localized:)` para entrar no update_strings.sh.
    static var entries: [(version: String, items: [String])] {
        [
            ("0.3.1", [
                String(localized: "Novidades de cada versão neste menu"),
                String(localized: "Ícone da barra alinhado com os outros"),
            ]),
        ]
    }

    private static let seenKey = "whatsNewSeen"

    /// Frases ainda não lidas (as das versões depois da última vista, no máximo 4).
    @Published private(set) var items: [String] = []
    @Published var expanded = false

    private init() { refresh() }

    /// Na abertura, antes do assistente: instalação nova não tem o que mostrar.
    static func prepare() {
        let d = UserDefaults.standard
        if d.string(forKey: seenKey) == nil && OnboardingModel.needed { d.set(Project.version, forKey: seenKey) }
        shared.refresh()
    }

    func refresh() {
        let current = Project.version
        let seen = UserDefaults.standard.string(forKey: Self.seenKey)
        // LLMBO_WHATSNEW=1: só para conferir o visual (mostra a entrada mais nova, já aberta).
        if ProcessInfo.processInfo.environment["LLMBO_WHATSNEW"] != nil {
            items = Self.entries.first?.items ?? []; expanded = true; return
        }
        let versions = Self.entries.filter { e in
            guard !Updater.isNewer(e.version, than: current) else { return false }
            // Sem registro (veio de uma versão anterior a esta tela): só as da versão atual.
            guard let seen else { return e.version == current }
            return Updater.isNewer(e.version, than: seen)
        }
        items = Array(versions.flatMap(\.items).prefix(4))
        expanded = false
    }

    /// Lidas ao abrir a lista; continuam na tela até o menu fechar.
    func open() {
        expanded = true
        UserDefaults.standard.set(Project.version, forKey: Self.seenKey)
    }

    /// Menu fechado: o que já foi lido sai.
    func menuClosed() {
        if expanded { refresh() }
    }
}
