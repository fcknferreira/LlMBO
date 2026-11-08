import SwiftUI

/// Abas da janela principal. A barra de abas é própria (pílulas, no visual do site) e a janela
/// se ajusta à altura de cada aba.
enum SettingsTab: Int, CaseIterable {
    // Valores fixos: a aba aberta é lembrada pelo número (Sistema entrou depois).
    // A ordem aqui é a da barra de abas (pedido do usuário em 02/11/2026).
    case general = 0, system = 5, sleep = 2, agents = 1, usage = 3, notifications = 6, about = 4

    var title: String {
        switch self {
        case .general: return String(localized: "Geral")
        case .agents: return String(localized: "Agentes")
        case .sleep: return String(localized: "Repouso")
        case .notifications: return String(localized: "Notificações")
        case .system: return String(localized: "Sistema")
        case .usage: return String(localized: "Uso")
        case .about: return String(localized: "Sobre")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "cpu"
        case .sleep: return "moon.zzz"
        case .notifications: return "bell"
        case .system: return "laptopcomputer"
        case .usage: return "chart.bar"
        case .about: return "info.circle"
        }
    }

    @MainActor var view: AnyView {
        switch self {
        case .general: return AnyView(GeneralTab())
        case .agents: return AnyView(AgentsTab())
        case .sleep: return AnyView(SleepTab())
        case .notifications: return AnyView(NotificationsTab())
        case .system: return AnyView(SystemTab())
        case .usage: return AnyView(UsageTab())
        case .about: return AnyView(AboutTab())
        }
    }
}

/// Aba aberta; lembrada entre aberturas.
final class MainTabModel: ObservableObject {
    static let shared = MainTabModel()
    private static let key = "settingsTab"

    @Published var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.key) }
    }

    private init() {
        tab = SettingsTab(rawValue: UserDefaults.standard.integer(forKey: Self.key)) ?? .general
    }
}

/// Conteúdo da janela principal: barra de abas em pílulas e a aba escolhida, sem rolagem.
/// O tamanho ideal vira o preferredContentSize do controlador, e o AppDelegate ajusta a janela.
struct MainWindowView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var model = MainTabModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            model.tab.view
        }
        .frame(width: TabFrame.width)
        .fixedSize(horizontal: false, vertical: true)
        // Mede a aba Sobre escondida, para as outras abas saberem a altura máxima antes de rolar.
        .background(alignment: .top) {
            if model.tab != .about {
                AboutTab().hidden().frame(height: 0, alignment: .top).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        // Abas à direita, na mesma linha dos botões da janela: sobem para a faixa da barra de título
        // (que tem a altura de uma barra de ferramentas vazia, com os botões centralizados nela).
        // O conteúdo respeita essa faixa, então o tamanho ideal já inclui ela e a janela fica exata.
        .overlay(alignment: .topTrailing) {
            // Nomes longos (alemão, russo…) não cabem com 5 abas ao lado dos botões da janela:
            // aí só a aba escolhida mostra o nome, as outras ficam no ícone (nome ao passar o mouse).
            ViewThatFits(in: .horizontal) {
                TabBar(selection: $model.tab, compact: false)
                TabBar(selection: $model.tab, compact: true)
            }
                .frame(maxWidth: TabFrame.width - 96, alignment: .trailing)
                .frame(height: AppDelegate.titlebarHeight)
                .padding(.trailing, 12)
                .offset(y: -AppDelegate.titlebarHeight)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct TabBar: View {
    @Binding var selection: SettingsTab
    let compact: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(on ? Theme.bronze2 : Theme.muted)
                        if on || !compact {
                            Text(tab.title)
                                .font(.system(size: 12, weight: on ? .medium : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.muted)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(on ? Color.white.opacity(0.07) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .handCursor()
                .help(tab.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.025)))
        .overlay(Capsule().strokeBorder(Theme.line))
    }
}

/// Largura e margens de cada aba; sem rolagem, a altura vem do conteúdo.
/// Aba mais alta que a aba Sobre (ou que a tela) rola, com a altura da Sobre; as outras continuam sem
/// rolagem, do tamanho exato do conteúdo. Assim a janela não passa da altura da Sobre ao trocar de aba.
struct TabFrame: ViewModifier {
    static let width: CGFloat = 500
    /// A aba Sobre é a referência: mede a própria altura e nunca rola por causa dela mesma.
    var reference = false
    @StateObject private var measured = TabHeight()
    @ObservedObject private var limit = TabLimit.shared

    /// Altura útil da tela menos a barra de título da janela e uma folga.
    static var screenHeight: CGFloat {
        // LLMBO_TAB_MAX=500 simula uma tela pequena para testar a rolagem.
        if let v = ProcessInfo.processInfo.environment["LLMBO_TAB_MAX"], let d = Double(v) { return d }
        return (NSScreen.main?.visibleFrame.height ?? 800) - AppDelegate.titlebarHeight - 24
    }

    func body(content: Content) -> some View {
        let inner = content
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .frame(width: Self.width, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: TabHeightKey.self, value: g.size.height) })
            .onPreferenceChange(TabHeightKey.self) { h in
                if abs(h - measured.height) > 0.5 { measured.height = h }
                if reference, abs(h - limit.aboutHeight) > 0.5 { limit.aboutHeight = h }
            }
        let cap = reference || limit.aboutHeight <= 0 ? Self.screenHeight : min(limit.aboutHeight, Self.screenHeight)
        if measured.height > cap {
            ScrollView(.vertical) { inner }.frame(width: Self.width, height: cap)
        } else {
            inner
        }
    }
}

/// Altura da aba Sobre, medida mesmo com outra aba aberta (cópia escondida no fundo da janela).
final class TabLimit: ObservableObject {
    static let shared = TabLimit()
    @Published var aboutHeight: CGFloat = 0
}

private final class TabHeight: ObservableObject {
    @Published var height: CGFloat = 0
}

private struct TabHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Geral

struct GeneralTab: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeroCard()

            CardSection(title: String(localized: "Aparência")) {
                Row(title: String(localized: "Ícone do app")) {
                    HStack(spacing: 8) {
                        ForEach(IconStyle.allCases) { style in
                            IconChoice(style: style, selected: engine.iconStyle == style, size: 26, showsTitle: false) {
                                engine.iconStyle = style
                            }
                        }
                    }
                }
                CardDivider()
                LanguagePicker()
                // Só aparece nos MacBook Pro com a maçã acesa (PROLED XDR).
                if LogoLight.shared.isSupported {
                    CardDivider()
                    LogoLightRows()
                }
            }

            // Comportamento do ícone (não é visual, por isso fora de Aparência).
            CardSection(title: String(localized: "Barra de menus")) {
                ToggleRow(title: String(localized: "Inverter os cliques do ícone"),
                          subtitle: engine.swapStatusClicks
                              ? String(localized: "Esquerdo abre o menu · direito liga/desliga")
                              : String(localized: "Esquerdo liga/desliga · direito abre o menu"),
                          info: String(localized: "Escolhe o que cada clique faz no ícone da barra de menus. Control-clique vale como clique direito."),
                          isOn: $engine.swapStatusClicks)
            }
        }
        .modifier(TabFrame())
    }
}

// MARK: - Notificações

/// Aviso de quando o Mac vai dormir e os sons (Horizonte, Supernova, Glass), com volume da tampa fechada.
struct NotificationsTab: View {
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CardSection(title: String(localized: "Notificações")) {
                // O subtítulo diz por onde saem: sem assinatura paga, o macOS pode mandar pelo Editor de Scripts.
                ToggleRow(title: String(localized: "Receber notificações"),
                          subtitle: !notifier.enabled ? nil
                              : notifier.status == .allowed ? String(localized: "Pelo LlMBO")
                                                            : String(localized: "Pelo Editor de Scripts"),
                          info: String(localized: "Todos os avisos do LlMBO na Central de Notificações: agentes terminaram, limite de tempo, bateria, temperatura e a retomada do Codex. Desligado, o LlMBO não avisa nada e fica mudo."),
                          isOn: $notifier.enabled)
                // Sem a permissão do macOS os avisos saem pelo Editor de Scripts: oferece permitir ou os Ajustes.
                if notifier.enabled && (notifier.status == .notAsked || notifier.status == .denied) {
                    CardDivider()
                    Row(title: String(localized: "Permissão do macOS"),
                        info: String(localized: "Sem a permissão, os avisos chegam pelo Editor de Scripts, com o nome e o ícone dele. Libere o LlMBO em Ajustes do Sistema › Notificações."),
                        warning: true) {
                        if notifier.status == .denied || notifier.asked {
                            Button(String(localized: "Abrir Ajustes…")) { notifier.openSystemSettings() }
                                .buttonStyle(.pill)
                        } else {
                            Button(String(localized: "Permitir")) { notifier.requestPermission() }
                                .buttonStyle(.pill(.primary))
                        }
                    }
                }
            }
            .onAppear { notifier.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in notifier.refresh() }

            // Sem notificação não há aviso nem som: o cartão fica apagado.
            CardSection(title: String(localized: "Sons")) {
                ToggleRow(title: String(localized: "Tocar som"),
                          info: String(localized: "Desligado, o LlMBO fica mudo: os avisos chegam em silêncio, com a tampa aberta ou fechada."),
                          isOn: $notifier.soundEnabled)
                // Com o som desligado, o resto do cartão fica apagado e sem clique (nada de amostras).
                Group {
                CardDivider()
                Row(title: String(localized: "Quando tocar"),
                    info: String(localized: "Com a tampa fechada, o LlMBO espera o som terminar antes de pôr o Mac para dormir. Fora da escolha, o aviso chega em silêncio.")) {
                    Dropdown(groups: [DropdownGroup(items: SoundWhen.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                             selection: notifier.soundWhen, width: 240,
                             onSelect: { notifier.soundWhen = $0 }) {
                        DropdownLabel(text: notifier.soundWhen.title)
                    }
                }
                CardDivider()
                Row(title: String(localized: "Som do aviso"),
                    info: String(localized: "Horizonte e Supernova são do próprio LlMBO: um grave de buraco negro que ganha força e some, e uma estrela que explode abafada e deixa um zumbido grave. Vale com a tampa fechada e aberta. Escolher toca uma amostra. No alto-falante do MacBook o grave aparece menos que num fone ou numa caixa de som. A Voyage, também do LlMBO, são três bipes suaves de uma mensagem chegando de longe: é a que mais se ouve no alto-falante do MacBook. A Espaçonave chega flutuando com um zumbido ondulante, passa por cima e vai embora. Saturno é um gongo grave cujos anéis ecoam devagar, e Nebulosa, um acorde quente e distante que cresce e some.")) {
                    Dropdown(groups: [DropdownGroup(items: NotifySound.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                             selection: notifier.soundChoice, width: 200,
                             onSelect: { notifier.soundChoice = $0; notifier.playSound() }) {   // amostra
                        DropdownLabel(text: notifier.soundChoice.title)
                    }
                }
                CardDivider()
                Row(title: String(localized: "Volume"),
                    info: String(localized: "Volume do som do aviso, com a tampa aberta ou fechada. Com a tampa fechada ele toca 25 % mais alto (até 100 %), porque a tampa abafa o som. Soltar o controle toca uma amostra.")) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        ThemedSlider(value: $notifier.lidVolume, title: String(localized: "Volume"),
                                     range: Notifier.lidVolumeRange, step: 0.1) {
                            notifier.playSound()   // amostra ao soltar
                        }
                        .frame(width: 150)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        Text(verbatim: "\(Int((notifier.lidVolume * 100).rounded())) %")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                CardDivider()
                Row(title: String(localized: "Volume do aviso"),
                    info: OtherAppsVolume.supported
                        ? String(localized: "Junto com o Mac: o volume escolhido é uma parte do volume do Mac, e no mudo não toca. Independente: o som sai no volume escolhido mesmo com o Mac baixo ou no mudo; se for mais alto que o do Mac, o LlMBO sobe o volume de saída só enquanto o som toca (cerca de 2 s) e devolve como estava, e nesses segundos música e chamadas também sobem. Sem mexer nos outros apps: igual ao Independente, mas os outros apps continuam no volume de antes; precisa da permissão de Gravação de Áudio do Sistema, e nada é gravado nem sai do seu Mac. O som vai para a saída em uso (um fone Bluetooth, por exemplo).")
                        : String(localized: "Junto com o Mac: o volume escolhido é uma parte do volume do Mac, e no mudo não toca. Independente: o som sai no volume escolhido mesmo com o Mac baixo ou no mudo; se for mais alto que o do Mac, o LlMBO sobe o volume de saída só enquanto o som toca (cerca de 2 s) e devolve como estava, e nesses segundos música e chamadas também sobem. O som vai para a saída em uso (um fone Bluetooth, por exemplo).")) {
                    Dropdown(groups: [DropdownGroup(items: VolumeMode.available.map { DropdownItem(id: $0, title: $0.title) })],
                             selection: notifier.volumeMode, width: 290,
                             onSelect: { notifier.volumeMode = $0 }) {
                        DropdownLabel(text: notifier.volumeMode.shortTitle)
                    }
                }
                if notifier.volumeMode == .keepOthers && notifier.othersPermission != .allowed {
                    Row(title: String(localized: "Permissão de áudio do sistema"),
                        info: String(localized: "Ligue o LlMBO em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema (na parte de áudio do sistema). Enquanto isso, o volume dos outros apps sobe junto durante o aviso."),
                        warning: true) {
                        HStack(spacing: 6) {
                            if notifier.othersPermission == .unknown {
                                Button(String(localized: "Permitir")) {
                                    OtherAppsVolume.request { _ in notifier.refreshOthersPermission() }
                                }
                                .buttonStyle(.pill(.primary))
                            }
                            Button(String(localized: "Abrir Ajustes…")) { notifier.openAudioCaptureSettings() }
                                .buttonStyle(.pill)
                        }
                    }
                }
                }
                .disabled(!notifier.soundEnabled)
                .opacity(notifier.soundEnabled ? 1 : 0.45)
            }
            .disabled(!notifier.enabled)
            .opacity(notifier.enabled ? 1 : 0.45)
        }
        .modifier(TabFrame())
    }
}

// MARK: - Sistema

/// Como o LlMBO roda no Mac (abrir ao iniciar, ligar sozinho, assistente, permissão) e quem mais segura o sono.
struct SystemTab: View {
    @EnvironmentObject var engine: Engine
    /// "Quem mais segura o Mac" (SleepBlockers.swift), relido só com a aba aberta.
    @StateObject private var blockers = SleepBlockersModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CanaryNotes(area: .system)
            CardSection(title: String(localized: "Funcionamento")) {
                ToggleRow(title: String(localized: "Abrir ao iniciar sessão"), isOn: $engine.launchAtLogin)
                CardDivider()
                ToggleRow(title: String(localized: "Religar ao abrir a tampa"),
                          info: String(localized: "Se o LlMBO foi desligado, por você ou por bateria, tempo ou temperatura, volta a ligar quando a tampa é aberta."),
                          isOn: $engine.armOnLidOpen)
                CardDivider()
                ToggleRow(title: String(localized: "Apagar a tela com a tampa fechada"),
                          info: String(localized: "Com a tampa fechada e o repouso desligado, a tela interna pode continuar acesa por trás da tampa, gastando bateria, esquentando e podendo marcar a tela. O LlMBO apaga a tela sem pôr o Mac para dormir e confere de novo a cada minuto. Com um monitor externo ligado, nada muda. Ao abrir a tampa, a tela volta normalmente."),
                          isOn: $engine.darkenLidClosed)
                CardDivider()
                Row(title: String(localized: "Assistente de configuração")) {
                    Button("Abrir…") { AppDelegate.shared.showOnboarding() }.buttonStyle(.pill)
                }
                if engine.helperInstalled {
                    CardDivider()
                    Row(title: String(localized: "Permissão de administrador")) {
                        Button("Remover…") { engine.uninstallHelper() }.buttonStyle(.pill(.destructive))
                    }
                }
            }

            BlockersSection(model: blockers)
        }
        .modifier(TabFrame())
        .onAppear { blockers.start() }
        .onDisappear { blockers.stop() }
    }
}

/// Topo do Geral: marca, frase do site e o interruptor principal.
private struct HeroCard: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let working = engine.statuses.contains(where: \.active) || !engine.holds.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                StatusGlyph(armed: engine.armed, size: 60)
                    .shadow(color: Theme.bronze2.opacity(engine.armed ? 0.30 : 0), radius: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LlMBO").font(Theme.serif(30)).foregroundStyle(Theme.text)
                    Text("Feche a tampa enquanto os agentes trabalham. Quando todos terminarem, o Mac dorme sozinho.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            CardDivider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Liberar tampa fechada").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    HStack(spacing: 7) {
                        StatusDot(active: engine.armed && working, running: engine.armed)
                        Text(engine.statusLine).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Toggle("Liberar tampa fechada", isOn: engine.armedBinding)
                    .toggleStyle(.switch)
                    .handCursor()
                    .labelsHidden()
                    .tint(Theme.control)
                    .disabled(!engine.helperInstalled)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            if !engine.helperInstalled {
                PermissionCallout().padding([.horizontal, .bottom], 12)
            }
            if let m = engine.message {
                CardDivider()
                Text(m)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

// MARK: - Agentes

struct AgentsTab: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var model = AgentsTabModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CanaryNotes(area: .agents)
            if engine.agents.isEmpty {
                Card {
                    Text("Nenhum agente. Use “Adicionar agente” para escolher um da lista ou cadastrar o seu.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            }
            AgentSection(title: String(localized: "Agentes de código"),
                         agents: engine.agents.filter { !$0.isLocalAI && !$0.isIDEExtension }, model: model)
            AgentSection(title: String(localized: "Extensões de IDE"), agents: engine.agents.filter(\.isIDEExtension), model: model)
            AgentSection(title: String(localized: "IA local"), agents: engine.agents.filter(\.isLocalAI), model: model)

            ConnectionsSection()

            LongTasksSection()

            HStack {
                AddAgentMenu(model: model)
                Spacer()
                Button("Editar JSON…") { engine.openConfig() }.buttonStyle(.pill)
            }
        }
        .modifier(TabFrame())
        .sheet(item: $model.draft) { draft in
            AgentEditor(draft: draft, model: model)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.control)
        }
    }
}

/// Tarefas longas: o comando `llmbo-signal hold` para o terminal e o servidor MCP para os agentes pedirem sozinhos.
private struct LongTasksSection: View {

    var body: some View {
        CardSection(title: String(localized: "Tarefas longas"),
                    info: String(localized: "Builds, testes, renders e downloads longos podem segurar o Mac acordado mesmo sem agente trabalhando: no terminal, ponha o comando depois de “llmbo-signal hold --”. Os agentes conectados pedem sozinhos pelo MCP. O Mac é solto quando o processo termina ou o prazo vence.")) {
            Row(title: String(localized: "Comando no terminal"), subtitle: "llmbo-signal hold -- npm run build") {
                Button(String(localized: "Copiar")) { copy("\"\(Paths.signalScript.path)\" hold -- ") }
                    .buttonStyle(.pill)
            }
            CardDivider()
            Row(title: String(localized: "MCP em outros agentes"),
                subtitle: String(localized: "Para agentes fora da lista: configuração em JSON para colar no agente.")) {
                Button(String(localized: "Copiar")) { copy(MCPInstall.json) }.buttonStyle(.pill)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Estado da aba fora de @State (no SDK do macOS 27 @State é macro; ver CLAUDE.md).
final class AgentsTabModel: ObservableObject {
    @Published var draft: AgentDraft?
}

/// Botão "Adicionar agente": os pré-cadastrados que ainda não estão na lista (primeiro os encontrados
/// neste Mac) e, no fim, um agente personalizado.
struct AddAgentMenu: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        let groups = AddAgentMenu.groups(available: engine.availableCatalog)
        let catalog = engine.availableCatalog
        Dropdown(groups: groups.map { g in
                    DropdownGroup(title: g.title, items: g.agents.map { DropdownItem(id: $0.id, title: $0.name) })
                 },
                 width: 270,
                 footer: DropdownFooter(title: String(localized: "Outro agente (personalizado)…"), symbol: "plus") {
                     model.draft = AgentDraft()
                 },
                 onSelect: { id in
                     if let a = catalog.first(where: { $0.id == id }) { engine.saveAgent(a) }
                 }) {
            DropdownLabel(text: String(localized: "Adicionar agente"), symbol: "plus", prominent: true)
        }
    }

    static func groups(available: [AgentConfig]) -> [(title: String, agents: [AgentConfig])] {
        let here = available.filter(\.isPresentOnMac)
        let rest = available.filter { !$0.isPresentOnMac }
        let byName: (AgentConfig, AgentConfig) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [
            (String(localized: "Encontrados neste Mac"), here.sorted(by: byName)),
            (String(localized: "Agentes de código"), rest.filter { !$0.isLocalAI && !$0.isIDEExtension }.sorted(by: byName)),
            (String(localized: "Extensões de IDE"), rest.filter(\.isIDEExtension).sorted(by: byName)),
            (String(localized: "IA local"), rest.filter(\.isLocalAI).sorted(by: byName)),
        ].filter { !$0.1.isEmpty }
    }
}

private struct AgentSection: View {
    @EnvironmentObject var engine: Engine
    let title: String
    let agents: [AgentConfig]
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        if !agents.isEmpty {
            CardSection(title: title) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { CardDivider() }
                    AgentListRow(agent: a, status: engine.statuses.first { $0.id == a.id }) {
                        model.draft = AgentDraft(a)
                    }
                }
            }
        }
    }

    private var sorted: [AgentConfig] {
        agents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct AgentListRow: View {
    @EnvironmentObject var engine: Engine
    let agent: AgentConfig
    let status: AgentStatus?
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(active: agent.isEnabled && status?.active == true,
                      running: agent.isEnabled && status?.running == true)
            Text(agent.name)
                .font(.system(size: 13))
                .foregroundStyle(agent.isEnabled ? Theme.text : Theme.muted)
            Spacer()
            Text(agent.isEnabled ? (status?.label ?? String(localized: "Fechado")) : String(localized: "Desativado"))
                .font(.system(size: 11))
                .foregroundStyle(status?.active == true ? Theme.bronze2 : Theme.muted)
                .monospacedDigit()
            Button(action: edit) {
                Image(systemName: "pencil.circle").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .handCursor()
            .help(String(localized: "Editar \(agent.name)"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Editar…", action: edit)
            Button(agent.isEnabled ? String(localized: "Desativar") : String(localized: "Ativar")) { engine.setEnabled(agent.id, !agent.isEnabled) }
            Divider()
            Button("Remover da lista", role: .destructive) { engine.removeAgent(agent.id) }
        }
    }
}

/// Conexão com os agentes: hook (avisa na hora quando o agente começa e termina) e servidor MCP (o agente pede para
/// segurar o Mac em tarefas que continuam depois da resposta). Um botão liga os dois.
private struct ConnectionsSection: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let list = engine.connections
        if !list.isEmpty {
            let pending = list.filter { !engine.isConnected($0) }
            VStack(alignment: .leading, spacing: 8) {
                CardSection(title: String(localized: "Conexão com os agentes"),
                            info: String(localized: "O LlMBO se conecta a cada agente de dois jeitos, e um completa o outro. O hook avisa na hora quando o agente começa e termina: é o sinal mais confiável para segurar o Mac e soltar logo depois do fim. O MCP dá ao agente a ferramenta keep_mac_awake, para ele pedir que o Mac fique acordado enquanto algo continua rodando depois da resposta (um build ou um download, por exemplo). Só são acrescentadas entradas do LlMBO nos arquivos de configuração, com backup. Agentes sem conexão são detectados pelos arquivos de sessão e pela CPU.")) {
                    if pending.count > 1 {
                        Row(title: String(localized: "Conectar todos os agentes da lista")) {
                            Button(String(localized: "Conectar todos")) { engine.connect(pending) }
                                .buttonStyle(.pill(.primary))
                        }
                        CardDivider()
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { CardDivider() }
                        ConnectionRow(connection: c)
                    }
                }
                if let m = engine.agentMessage {
                    Text(m)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

private struct ConnectionRow: View {
    @EnvironmentObject var engine: Engine
    let connection: AgentConnection

    var body: some View {
        Row(title: connection.name, subtitle: ConnectionRow.detail(connection, engine)) {
            if engine.isConnected(connection) {
                if engine.anyPieceOn(connection) {
                    Button(String(localized: "Desconectar")) { engine.disconnect(connection) }.buttonStyle(.pill)
                }
            } else {
                Button(String(localized: "Conectar")) { engine.connect(connection) }.buttonStyle(.pill(.primary))
            }
        }
    }

    /// "Hook ✓ · MCP ✓", o que falta, observações do agente e se avisa pedidos de aprovação.
    static func detail(_ c: AgentConnection, _ engine: Engine) -> String {
        var parts: [String] = []
        let hook = engine.hookState(c)
        switch hook {
        case .installed: parts.append(String(localized: "Hook ✓"))
        case .notInstalled: parts.append(String(localized: "Hook não instalado"))
        case .conflict(let why): parts.append(why)
        case .unsupported: parts.append(String(localized: "sem hook"))
        }
        if engine.mcpAvailable(c) {
            parts.append(engine.mcpOn(c) ? "MCP ✓" : String(localized: "MCP não instalado"))
        } else if c.mcp?.id == "claude" {
            parts.append(String(localized: "MCP precisa do Claude Code no Mac"))
        } else {
            parts.append(String(localized: "sem MCP"))
        }
        var lines = [parts.joined(separator: " · ")]
        if hook == .installed {
            var extra: [String] = []
            if let h = c.hookAgent, let note = Hooks.note(h) { extra.append(note) }
            if let h = c.hookAgent { extra.append(approvalText(h)) }
            lines.append(extra.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// Se o hook avisa pedidos de aprovação ("Esperar acordado por aprovações").
    static func approvalText(_ agent: String) -> String {
        switch Hooks.approvalSupport(agent) {
        case .yes: return String(localized: "Avisa pedidos de aprovação")
        case .partial: return String(localized: "Avisa só pedidos de acesso, não a aprovação de comandos")
        case .no: return String(localized: "Não avisa pedidos de aprovação")
        }
    }
}

// MARK: - Repouso

struct SleepTab: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CardSection(title: String(localized: "Travas de segurança"),
                        info: String(localized: "Ao atingir a bateria mínima ou o tempo máximo, o LlMBO desliga, religa o repouso e, se a tampa estiver fechada, põe o Mac para dormir.")) {
                ValueStepper(title: String(localized: "Dormir com bateria em"), value: $engine.minBattery,
                             range: 5...50, step: 5, unit: "%")
                CardDivider()
                ValueStepper(title: String(localized: "Tempo máximo na bateria"), value: $engine.maxHours,
                             range: 1...24, unit: String(localized: "h", comment: "horas"))
                CardDivider()
                ValueStepper(title: String(localized: "Tempo máximo na tomada"), value: $engine.maxHoursAC,
                             range: 0...48, unit: String(localized: "h", comment: "horas"),
                             zeroLabel: String(localized: "Sem limite"))
                CardDivider()
                Row(title: String(localized: "Proteção de temperatura"),
                    info: String(localized: "Proteção de temperatura: ao atingir o nível escolhido com a tampa fechada, o LlMBO religa o repouso e põe o Mac para dormir na hora. Em “Quente”, o próprio macOS já está reduzindo o desempenho para esfriar.")) {
                    Dropdown(groups: [DropdownGroup(items: ThermalLimit.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                             selection: engine.thermalLimit, width: 220,
                             onSelect: { engine.thermalLimit = $0 }) {
                        DropdownLabel(text: engine.thermalLimit.title)
                    }
                }
                CardDivider()
                Row(title: String(localized: "Vigia contra travamento"),
                    info: String(localized: "Um processo do próprio LlMBO, separado da janela (aparece como LlMBO no Monitor de Atividade), confere a cada 10 s se o app continua respondendo. Se o LlMBO travar ou for fechado à força com o repouso desligado, o vigia religa o repouso em cerca de 1 minuto e, com a tampa fechada, põe o Mac para dormir.")) {
                    switch engine.watchdogStatus {
                    case .active:
                        Text("Ativo").foregroundStyle(Theme.muted)
                    case .needsApproval:
                        Button(String(localized: "Abrir Ajustes…")) { engine.openLoginItemsSettings() }
                            .buttonStyle(.pill)
                    case .off:
                        Text("Desligado").foregroundStyle(Theme.muted)
                    }
                }
            }

            CardSection(title: String(localized: "Detecção")) {
                ToggleRow(title: String(localized: "Priorizar hooks"),
                          info: String(localized: "Com hook, só ele conta; sem hook, só os arquivos de sessão. A CPU nunca conta.")
                            + "\n\n"
                            + String(localized: "Ordem de confiança: hook, depois arquivos de sessão, por último a CPU. A CPU pode acusar trabalho que não existe (uma IDE indexando, por exemplo). Desligado, agentes sem hook também contam pela CPU sustentada."),
                          isOn: $engine.strictHooks)
                CardDivider()
                ValueStepper(title: String(localized: "Espera para arquivos e CPU"), value: $engine.graceMinutes,
                             range: 1...30, unit: String(localized: "min", comment: "minutos"),
                             info: String(localized: "Agentes sem hook não avisam quando terminam: o LlMBO espera esse tempo sem arquivos de sessão nem CPU. Com hook, o fim vale na hora."))
                CardDivider()
                PresetStepper(title: String(localized: "Esperar acordado por aprovações"), value: $engine.approvalWaitMinutes,
                              options: Engine.approvalWaitOptions, zeroLabel: String(localized: "Não esperar"),
                              format: { Self.duration($0 * 60) },
                              info: String(localized: "Quando um agente para pedindo sua aprovação, o Mac fica acordado por esse tempo, mesmo de tampa fechada, para você aprovar à distância (por exemplo, pelo controle remoto no celular) e o trabalho continuar. Se ninguém responder, ele dorme normalmente.")
                                + "\n\n"
                                + String(localized: "Avisam: Claude Code, Codex, Qwen Code, Gemini CLI e OpenCode. Antigravity: só quando pede acesso a recursos. Copilot CLI, Cursor, Crush, Aider e agentes sem hook não avisam; um pedido de aprovação deles conta como parado. Cada linha da seção Hooks, na aba Agentes, mostra o que vale para aquele agente."))
                CardDivider()
                PresetStepper(title: String(localized: "Esperar tarefas em segundo plano"), value: $engine.backgroundTaskMinutes,
                              options: Engine.backgroundTaskOptions, zeroLabel: String(localized: "Não esperar"),
                              format: { Self.duration($0 * 60) },
                              info: String(localized: "O Claude Code pode terminar a resposta e deixar um comando rodando em segundo plano (um build, um teste, uma espera). Enquanto esse comando roda, o Mac fica acordado, até esse tempo contado desde que ele começou. O limite existe para um servidor esquecido aberto não segurar o Mac para sempre."))
                CardDivider()
                PresetStepper(title: String(localized: "Atrasar o repouso"), value: $engine.sleepDelaySeconds,
                              options: Engine.sleepDelayOptions, zeroLabel: String(localized: "Sem atraso"),
                              format: Self.duration,
                              info: String(localized: "Depois que os agentes terminam, o Mac fica acordado por esse tempo, mesmo de tampa fechada, e então volta ao repouso normal do macOS. Se um agente voltar a trabalhar antes disso, a espera recomeça."))
            }
        }
        .modifier(TabFrame())
    }

    /// "45 s", "2 min", "1 min 30 s".
    static func duration(_ seconds: Int) -> String {
        let sec = String(localized: "s", comment: "segundos"), min = String(localized: "min", comment: "minutos")
        if seconds < 60 { return "\(seconds) \(sec)" }
        let m = seconds / 60, r = seconds % 60
        return r == 0 ? "\(m) \(min)" : "\(m) \(min) \(r) \(sec)"
    }
}

/// Como o ValueStepper, mas andando por uma lista de valores (ex.: segundos e depois minutos).
private struct PresetStepper: View {
    let title: String
    @Binding var value: Int
    let options: [Int]
    var zeroLabel: String? = nil
    let format: (Int) -> String
    var info: String? = nil

    var body: some View {
        Row(title: title, info: info) {
            StepperPill(title: title,
                        text: value == 0 && zeroLabel != nil ? zeroLabel! : format(value),
                        canDecrease: options.contains { $0 < value },
                        canIncrease: options.contains { $0 > value },
                        decrease: { if let v = options.last(where: { $0 < value }) { value = v } },
                        increase: { if let v = options.first(where: { $0 > value }) { value = v } })
        }
    }
}

private struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String
    /// Texto para o valor 0 (ex.: "Sem limite"), quando 0 tem significado próprio.
    var zeroLabel: String? = nil
    /// Explicação no botão ⓘ ao lado do título.
    var info: String? = nil

    var body: some View {
        Row(title: title, info: info) {
            StepperPill(title: title,
                        text: value == 0 && zeroLabel != nil ? zeroLabel! : "\(value) \(unit)",
                        canDecrease: value > range.lowerBound,
                        canIncrease: value < range.upperBound,
                        decrease: { value = max(range.lowerBound, value - step) },
                        increase: { value = min(range.upperBound, value + step) })
        }
    }
}

/// Pílula "− valor +" no lugar das setinhas do Stepper do sistema.
private struct StepperPill: View {
    let title: String
    let text: String
    let canDecrease: Bool
    let canIncrease: Bool
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StepButton(symbol: "minus", enabled: canDecrease, action: decrease)
            Text(text)
                .monospacedDigit()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(minWidth: 52)
                .padding(.horizontal, 2)
            StepButton(symbol: "plus", enabled: canIncrease, action: increase)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.line))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrease { increase() }
            case .decrement: if canDecrease { decrease() }
            @unknown default: break
            }
        }
    }
}

/// Botão redondo de − ou + da pílula do ValueStepper: bronze ao passar o mouse, apagado no limite.
private struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(hover.on && enabled ? Theme.bronze2 : Theme.muted)
                .frame(width: 24, height: 22)
                .background(Circle().fill(hover.on && enabled ? Theme.cardHover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover.on = $0 }
    }
}

// MARK: - Sobre

struct AboutTab: View {
    @EnvironmentObject var engine: Engine

    /// Só a versão pública ("0.2.1"); o número de build vai no "Relatar problema…", não na tela.
    private var version: String { Project.version }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 8) {
                Image(nsImage: engine.iconStyle.image)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .shadow(color: Theme.bronze2.opacity(0.25), radius: 22, y: 8)
                Text("LlMBO").font(Theme.serif(36)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Text("Versão \(version)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .textSelection(.enabled)
                    if Project.beta { BetaBadge() }
                }
                Text("Deixa o MacBook trabalhar de tampa fechada enquanto seus agentes de IA rodam, e põe o Mac para dormir quando todos terminam.")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            UpdatesCard()

            // Num cartão só dele, logo abaixo de "Encontrou um problema?": tira tudo do Mac.
            Card {
                Row(title: String(localized: "Desinstalar o LlMBO")) {
                    Button("Desinstalar…") { Uninstaller.confirmAndRun(Engine.shared) }.buttonStyle(.pill(.destructive))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Card {
                    Row(title: String(localized: "Compatível com")) {
                        Text(String(localized: "macOS 13 ou posterior")).foregroundStyle(Theme.muted)
                    }
                    CardDivider()
                    Row(title: String(localized: "Pasta de dados")) {
                        Button("Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Paths.support])
                        }
                        .buttonStyle(.pill)
                    }
                    CardDivider()
                    Row(title: String(localized: "Redes sociais")) {
                        HStack(spacing: 14) {
                            SocialIconButton(name: "llmbo.app", icon: "globe", url: "https://llmbo.app")
                            SocialIconButton(name: "GitHub", icon: "github", url: Project.repoURL.absoluteString)
                            SocialIconButton(name: "Instagram", icon: "instagram",
                                             url: "https://www.instagram.com/llmbo.app/")
                            SocialIconButton(name: "Threads", icon: "threads",
                                             url: "https://www.threads.com/@llmbo.app")
                        }
                    }
                }
                Text("Tudo roda neste Mac: o LlMBO não coleta nem envia dados. Ele só lê os processos e as pastas dos agentes e, com a sua permissão, liga e desliga o repouso. A única conexão é a consulta ao GitHub por versões novas, que dá para desligar acima.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .modifier(TabFrame(reference: true))
    }
}

/// Atualizações pelo GitHub (Updater.swift) e "Relatar problema…".
private struct UpdatesCard: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        CardSection(title: String(localized: "Atualizações")) {
            Row(title: title, subtitle: subtitle) {
                HStack(spacing: 8) {
                    if let r = updater.available {
                        Button("Novidades") { NSWorkspace.shared.open(r.page) }.buttonStyle(.pill)
                        Button("Atualizar") { Task { await updater.install() } }.buttonStyle(.pill(.primary))
                    } else if updater.state == .checking || updater.state == .downloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Procurar atualizações…") { Task { await updater.check() } }.buttonStyle(.pill)
                    }
                }
            }
            CardDivider()
            ToggleRow(title: String(localized: "Atualização automática"),
                      info: String(localized: "Uma vez por dia o LlMBO pergunta ao GitHub se há versão nova. Se houver, baixa, confere se ela tem a mesma assinatura desta e instala sozinho assim que nenhum agente estiver trabalhando, sem abrir janela; você recebe um aviso. Só a pergunta sai do Mac: nenhum dado seu vai junto. Desligado, ele não procura; use Procurar atualizações."),
                      isOn: $updater.autoCheck)
            CardDivider()
            Row(title: String(localized: "Encontrou um problema?"),
                info: String(localized: "Abre uma issue nova no GitHub já com a versão do LlMBO, do macOS, o modelo do Mac e o fim do registro de erros (com o seu nome de usuário escondido). Você revisa e edita tudo antes de enviar.")) {
                Button("Relatar problema…") { ProblemReport.open() }.buttonStyle(.pill)
            }
        }
    }

    private var title: String {
        if let r = updater.available { return String(localized: "Versão \(r.version) disponível") }
        return String(localized: "Versão \(Project.version)")
    }

    private var subtitle: String? {
        switch updater.state {
        case .checking: return String(localized: "Procurando…")
        case .downloading: return String(localized: "Baixando e conferindo a assinatura…")
        case .upToDate: return String(localized: "Você está na versão mais nova.")
        case .failed(let m): return m
        default: return nil
        }
    }
}

/// Ícone de rede social (SVG solto em Contents/Resources, desenhado como template).
/// Sem o SVG (o NSImage só lê SVG em versões novas do macOS), mostra o nome numa pílula.
struct SocialIconButton: View {
    let name: String
    let icon: String
    let url: String
    @StateObject private var hover = HoverFlag()

    private var image: NSImage? {
        guard let path = Bundle.main.path(forResource: icon, ofType: "svg"),
              let img = NSImage(contentsOfFile: path) else { return nil }
        img.isTemplate = true
        return img
    }

    var body: some View {
        if let image {
            Button { open() } label: {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(hover.on ? Theme.text : Theme.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .onHover { hover.on = $0 }
            .help(name)
            .accessibilityLabel(name)
        } else {
            Button(name) { open() }.buttonStyle(.pill)
        }
    }

    private func open() {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
