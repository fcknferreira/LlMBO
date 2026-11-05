import AppKit
import SwiftUI

/// Idioma da interface. Usa o mecanismo do macOS (AppleLanguages só deste app): vale ao reabrir o app.
/// Textos em Resources/<idioma>.lproj/Localizable.strings; a chave é o texto em português.
/// Para acrescentar um idioma: um case aqui, o código em CFBundleLocalizations (Info.plist),
/// Design/translations/<código>.json e o código em EXTRA no Design/translations.py.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case portuguese = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case english = "en"
    case englishUK = "en-GB"
    case spanish = "es"
    case spanishLatinAmerica = "es-419"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case russian = "ru"
    case ukrainian = "uk"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case hindi = "hi"
    case indonesian = "id"
    case vietnamese = "vi"
    case arabic = "ar"
    case hebrew = "he"

    var id: String { rawValue }

    /// Cada idioma no próprio idioma, como no macOS; só "Sistema" é traduzido.
    var title: String {
        switch self {
        case .system: return String(localized: "Igual ao sistema")
        case .portuguese: return "Português (Brasil)"
        case .portuguesePortugal: return "Português (Portugal)"
        case .english: return "English (US)"
        case .englishUK: return "English (UK)"
        case .spanish: return "Español (España)"
        case .spanishLatinAmerica: return "Español (Latinoamérica)"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .russian: return "Русский"
        case .ukrainian: return "Українська"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .hindi: return "हिन्दी"
        case .indonesian: return "Bahasa Indonesia"
        case .vietnamese: return "Tiếng Việt"
        case .arabic: return "العربية"
        case .hebrew: return "עברית"
        }
    }

    private static let key = "AppleLanguages"

    /// O idioma em que o app abriu se escreve da direita para a esquerda (árabe, hebraico)?
    static var isRightToLeft: Bool {
        guard let lang = Bundle.main.preferredLocalizations.first else { return false }
        return Locale.Language(identifier: lang).characterDirection == .rightToLeft
    }

    /// Espelha a interface (AppKit e SwiftUI) em árabe e hebraico. Precisa rodar antes de a interface existir:
    /// o app não espelhava sozinho só por estar nesses idiomas.
    static func applyLayoutDirection() {
        guard isRightToLeft else { return }
        // Os mesmos dois ajustes que o Xcode passa na "Right-to-Left Pseudolanguage" (só um deles não espelha).
        // O AppKit só os lê no domínio de argumentos (register(defaults:) não funciona), então entram ali.
        let d = UserDefaults.standard
        var args = d.volatileDomain(forName: UserDefaults.argumentDomain)
        args["AppleTextDirection"] = true
        args["NSForceRightToLeftWritingDirection"] = true
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    /// O que está gravado para este app (sem misturar com o idioma global do Mac).
    static var saved: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let first = (domain[key] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    func save() {
        if self == .system { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set([rawValue], forKey: Self.key) }
    }

    /// Abre o app de novo daqui a pouco e encerra este (o idioma só troca num processo novo).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Seletor de idioma com o aviso para reabrir quando a escolha muda.
struct LanguagePicker: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            Row(title: String(localized: "Idioma")) {
                Dropdown(groups: [DropdownGroup(items: AppLanguage.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                         selection: engine.language, width: 230,
                         onSelect: { engine.language = $0 }) {
                    DropdownLabel(text: engine.language.title)
                }
            }
            if engine.language != engine.launchLanguage {
                CardDivider()
                Row(title: String(localized: "O idioma muda quando o LlMBO reabre.")) {
                    Button("Reabrir agora") { AppLanguage.relaunch() }.buttonStyle(.pill(.primary))
                }
            }
        }
    }
}
