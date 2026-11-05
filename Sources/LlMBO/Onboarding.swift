import Combine
import SwiftUI

/// Assistente da primeira abertura: permissão, agentes, conexão com os agentes (hook + MCP) e preferências.
/// Abre sozinho uma vez (UserDefaults "onboardingDone"); dá para reabrir na aba Geral.
enum OnboardingStep: Int, CaseIterable {
    case welcome, permission, agents, hooks, preferences, done
}

final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    /// Para a folha de agente personalizado (o mesmo formulário da aba Agentes).
    let agentsModel = AgentsTabModel()
    var finish: () -> Void = {}

    static let doneKey = "onboardingDone"
    static var needed: Bool {
        !UserDefaults.standard.bool(forKey: doneKey) || ProcessInfo.processInfo.environment["LLMBO_ONBOARDING"] != nil
    }
}

struct OnboardingView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var model: OnboardingModel

    /// O passo de conexão só aparece se algum agente da lista aceita hook ou MCP.
    private var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .hooks || !engine.connections.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .permission: PermissionStep()
                case .agents: AgentsStep(model: model)
                case .hooks: ConnectStep()
                case .preferences: PreferencesStep()
                case .done: DoneStep()
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { s in
                        Capsule()
                            .fill(s == model.step ? Theme.bronze2 : Theme.faint)
                            .frame(width: s == model.step ? 18 : 6, height: 6)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.step)
                .accessibilityLabel(String(localized: "Passo \(index + 1) de \(steps.count)"))
                Spacer()
                if index > 0 && model.step != .done {
                    Button("Voltar") { go(-1) }.buttonStyle(.pill)
                }
                Button(primaryTitle) {
                    model.step == .done ? model.finish() : go(1)
                }
                .buttonStyle(.pill(.primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 540)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.control)
        .sheet(item: Binding(get: { model.agentsModel.draft }, set: { model.agentsModel.draft = $0 })) { draft in
            AgentEditor(draft: draft, model: model.agentsModel).environmentObject(engine)
        }
        .onReceive(model.agentsModel.objectWillChange) { _ in model.objectWillChange.send() }
    }

    private var index: Int { steps.firstIndex(of: model.step) ?? 0 }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return String(localized: "Começar")
        case .permission: return engine.helperInstalled ? String(localized: "Continuar") : String(localized: "Pular por enquanto")
        case .done: return String(localized: "Concluir")
        default: return String(localized: "Continuar")
        }
    }

    private func go(_ delta: Int) {
        let i = min(max(index + delta, 0), steps.count - 1)
        model.step = steps[i]
    }
}

// MARK: - Peças comuns

private struct StepHeader: View {
    let symbol: String?
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.bronze2)
                    .shadow(color: Theme.bronze2.opacity(0.35), radius: 14)
                    .frame(height: 44)
            }
            Text(title).font(Theme.serif(32)).foregroundStyle(Theme.text)
            Text(text)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }
}

/// Linha com um selo de estado (✓ verde ou ponto de atenção) e uma ação opcional à direita.
private struct CheckRow<Trailing: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(ok ? Theme.bronze2 : Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }
}

// MARK: - Passos

private struct WelcomeStep: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: engine.iconStyle.image)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: Theme.bronze2.opacity(0.28), radius: 26, y: 8)
                .padding(.bottom, 8)
            StepHeader(symbol: nil, title: String(localized: "Bem-vindo ao LlMBO"),
                       text: String(localized: "Feche a tampa do MacBook enquanto seus agentes de IA trabalham. Quando todos terminarem, o LlMBO põe o Mac para dormir sozinho."))
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "laptopcomputer", text: String(localized: "Mantém o Mac acordado com a tampa fechada, só enquanto precisa."))
                Feature(symbol: "waveform.path.ecg", text: String(localized: "Percebe quando cada agente trabalha: hooks, arquivos de sessão e CPU."))
                Feature(symbol: "battery.25", text: String(localized: "Travas de segurança: bateria mínima e tempo máximo acordado."))
            }
            .frame(maxWidth: 400)
            Card { LanguagePicker() }
                .frame(maxWidth: 400)
                .padding(.top, 22)
        }
    }

    private struct Feature: View {
        let symbol: String
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Theme.bronze2).frame(width: 22)
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionStep: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "lock.shield", title: String(localized: "Permissão de administrador"),
                       text: String(localized: "Para manter o Mac acordado com a tampa fechada, o LlMBO usa o comando do sistema pmset, que exige administrador. Você digita a senha uma vez só."))
            CheckRow(ok: engine.helperInstalled,
                     title: engine.helperInstalled ? String(localized: "Permissão instalada") : String(localized: "Permissão ainda não instalada"),
                     detail: String(localized: "Uma regra do sudo libera só dois comandos: desligar e religar o repouso. Nada mais roda como administrador.")) {
                if !engine.helperInstalled {
                    Button("Instalar…") { engine.installHelper() }.buttonStyle(.pill(.primary))
                }
            }
            Text("Sem ela, o LlMBO só mostra os agentes; não consegue manter o Mac acordado. Dá para instalar depois na janela do app.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Spacer(minLength: 20)
            PrivacyNote()
            Spacer(minLength: 20)
        }
    }
}

/// Destaque de privacidade junto do pedido de senha: é ali que a pessoa decide se confia no app.
private struct PrivacyNote: View {
    var body: some View {
        VStack(spacing: 10) {
            // Selo entre duas linhas, no estilo dos kickers do site: lê como aviso, não como mais um item.
            HStack(spacing: 10) {
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9.5, weight: .semibold))
                    Text(String(localized: "Seus dados ficam no seu Mac").uppercased(with: Locale.current))
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(1.6)
                }
                .foregroundStyle(Theme.bronze2)
                .fixedSize()
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            Text("O LlMBO não coleta dados pessoais. Ele só lê os processos e as pastas dos agentes; a única conexão é a consulta ao GitHub por versões novas, que dá para desligar.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentsStep: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var model: OnboardingModel

    /// Encontrados no Mac + o que já está na lista (inclusive personalizados).
    private var candidates: [AgentConfig] {
        var list = engine.agents
        for c in AgentConfig.catalog where c.isPresentOnMac && !list.contains(where: { $0.id == c.id }) {
            list.append(c)
        }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "cpu", title: String(localized: "Seus agentes"),
                       text: String(localized: "Estes foram encontrados neste Mac. Marque os que o LlMBO deve acompanhar."))
            ScrollView {
                VStack(spacing: 0) {
                    if candidates.isEmpty {
                        Text("Nenhum agente encontrado. Adicione um da lista abaixo.")
                            .foregroundStyle(Theme.muted)
                            .padding(16)
                    }
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 40) }
                        Toggle(isOn: Binding(get: { engine.agents.contains { $0.id == a.id } },
                                             set: { $0 ? engine.saveAgent(a) : engine.removeAgent(a.id) })) {
                            HStack {
                                Text(a.name).foregroundStyle(Theme.text)
                                Spacer()
                                Text(a.isLocalAI ? String(localized: "IA local")
                                     : a.isIDEExtension ? String(localized: "Extensão") : String(localized: "Código"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .handCursor()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
            }
            .frame(maxHeight: 210)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))

            HStack {
                AddAgentMenu(model: model.agentsModel)
                Spacer()
                Text("Dá para mudar depois na aba Agentes.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 12)
        }
    }
}

private struct ConnectStep: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let list = engine.connections
        let pending = list.filter { !engine.isConnected($0) }
        VStack(spacing: 0) {
            StepHeader(symbol: "bolt.badge.clock", title: String(localized: "Conectar os agentes"),
                       text: String(localized: "O hook avisa na hora quando o agente começa e termina, e o Mac dorme logo depois do fim. O MCP deixa o agente pedir para segurar o Mac quando algo continua rodando depois da resposta, como um build."))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(list) { c in
                        CheckRow(ok: engine.isConnected(c), title: c.name, detail: detail(c)) {
                            if !engine.isConnected(c) {
                                Button(String(localized: "Conectar")) { engine.connect(c) }.buttonStyle(.pill(.primary))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
            HStack {
                Text("Só acrescenta entradas do LlMBO nos arquivos de configuração (com backup); as suas ficam intactas.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if pending.count > 1 {
                    Button(String(localized: "Conectar todos")) { engine.connect(pending) }.buttonStyle(.pill)
                }
            }
            .padding(.top, 12)
        }
    }

    private func detail(_ c: AgentConnection) -> String {
        if engine.isConnected(c) {
            let ok = String(localized: "Conectado")
            return c.hookAgent.flatMap(Hooks.note).map { "\(ok) · \($0)" } ?? ok
        }
        let pieces = [c.hookAgent != nil ? "hook" : nil, engine.mcpAvailable(c) ? "MCP" : nil].compactMap { $0 }
        return String(localized: "Ainda não conectado (\(pieces.joined(separator: " + ")))")
    }
}

private struct PreferencesStep: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var notifier = Notifier.shared
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var notificationDetail: String {
        let why = String(localized: "Para avisar por que o Mac foi dormir (útil com a tampa fechada).")
        guard notifier.enabled else { return why }
        switch notifier.status {
        case .allowed: return why
        case .denied: return String(localized: "Negadas nos Ajustes do Sistema. Até liberar, os avisos chegam pelo Editor de Scripts.")
        case .notAsked, .unknown:
            return notifier.asked
                ? String(localized: "O macOS não perguntou. Libere nos Ajustes do Sistema; até lá, os avisos chegam pelo Editor de Scripts.")
                : why + " " + String(localized: "O macOS vai pedir sua permissão.")
        }
    }

    private var othersDetail: String {
        let why = String(localized: "Opcional. Quando o aviso precisa sair mais alto que o volume do Mac, música e chamadas continuam no volume de antes. O macOS pede a permissão de Gravação de Áudio do Sistema; nada é gravado nem sai do seu Mac.")
        guard notifier.keepOthersVolume else { return why }
        switch notifier.othersPermission {
        case .allowed: return why
        case .denied: return String(localized: "Negada nos Ajustes do Sistema. Até liberar, o volume dos outros apps sobe junto durante o aviso.")
        case .unknown: return String(localized: "Falta a permissão. Até lá, o volume dos outros apps sobe junto durante o aviso.")
        }
    }

    /// Ligar aqui também liga o "Volume independente do Mac", sem o qual a opção não tem efeito.
    private var keepOthers: Binding<Bool> {
        Binding(get: { notifier.keepOthersVolume && notifier.lidVolumeIndependent },
                set: { on in
                    if on { notifier.lidVolumeIndependent = true }
                    notifier.keepOthersVolume = on
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "slider.horizontal.3", title: String(localized: "Preferências"),
                       text: String(localized: "Os ajustes de quando dormir ficam na aba Repouso; estes são os do dia a dia."))
            VStack(spacing: 8) {
                CheckRow(ok: engine.launchAtLogin && !engine.loginItemNeedsApproval,
                         title: String(localized: "Abrir ao iniciar sessão"),
                         detail: engine.loginItemNeedsApproval
                            ? String(localized: "O macOS pede sua aprovação em Ajustes do Sistema › Itens de Início.")
                            : String(localized: "O LlMBO fica na barra de menus desde o login.")) {
                    if engine.loginItemNeedsApproval {
                        Button("Abrir Ajustes…") { engine.openLoginItemsSettings() }.buttonStyle(.pill)
                    } else {
                        Toggle(String(localized: "Abrir ao iniciar sessão"), isOn: $engine.launchAtLogin)
                            .toggleStyle(.switch)
                            .handCursor()
                            .labelsHidden()
                    }
                }
                CheckRow(ok: notifier.status == .allowed,
                         title: String(localized: "Notificações"),
                         detail: notificationDetail) {
                    HStack(spacing: 10) {
                        if notifier.enabled && notifier.status != .allowed {
                            if notifier.status == .denied || notifier.asked {
                                Button("Abrir Ajustes…") { notifier.openSystemSettings() }.buttonStyle(.pill)
                            } else {
                                Button("Permitir") { notifier.requestPermission() }.buttonStyle(.pill(.primary))
                            }
                        }
                        Toggle(String(localized: "Receber notificações"), isOn: $notifier.enabled)
                            .toggleStyle(.switch)
                            .handCursor()
                            .labelsHidden()
                            .tint(Theme.control)
                    }
                }
                if OtherAppsVolume.supported {
                    CheckRow(ok: keepOthers.wrappedValue && notifier.othersPermission == .allowed,
                             title: String(localized: "Não mudar o volume de outros apps"),
                             detail: othersDetail) {
                        HStack(spacing: 10) {
                            if keepOthers.wrappedValue && notifier.othersPermission != .allowed {
                                if notifier.othersPermission == .denied {
                                    Button("Abrir Ajustes…") { notifier.openAudioCaptureSettings() }.buttonStyle(.pill)
                                } else {
                                    Button("Permitir") {
                                        OtherAppsVolume.request { _ in notifier.refreshOthersPermission() }
                                    }
                                    .buttonStyle(.pill(.primary))
                                }
                            }
                            Toggle(String(localized: "Não mudar o volume de outros apps"), isOn: keepOthers)
                                .toggleStyle(.switch)
                                .handCursor()
                                .labelsHidden()
                                .tint(Theme.control)
                        }
                    }
                    .disabled(!notifier.enabled)
                    .opacity(notifier.enabled ? 1 : 0.45)
                }
                HStack {
                    Text("Ícone do app").foregroundStyle(Theme.text)
                    Spacer()
                    HStack(spacing: 16) {
                        ForEach(IconStyle.allCases) { style in
                            IconChoice(style: style, selected: engine.iconStyle == style, size: 44) {
                                engine.iconStyle = style
                            }
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            }
        }
        .onReceive(poll) { _ in notifier.refresh(); notifier.refreshOthersPermission() }
        // Passou sem clicar em "Permitir" com o aviso ligado: pede ao sair do passo.
        .onDisappear {
            if notifier.enabled && notifier.status == .notAsked && !notifier.asked { notifier.requestPermission() }
        }
    }
}

private struct DoneStep: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "checkmark.seal", title: String(localized: "Tudo pronto"),
                       text: String(localized: "O LlMBO fica na barra de menus. Clique no buraco negro para ligar ou desligar a tampa fechada antes de sair de perto do Mac; clique com o botão direito para abrir o menu."))
            HStack(spacing: 14) {
                Image(nsImage: BlackHoleIcon.image(active: false))
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(Theme.text)
                    .frame(width: 30, height: 27)
                    .frame(width: 52, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                Image(systemName: "arrow.forward").foregroundStyle(Theme.bronze2)
                Image(nsImage: BlackHoleIcon.image(active: true))
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(Theme.text)
                    .frame(width: 30, height: 27)
                    .frame(width: 52, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            }
            .padding(.bottom, 6)
            Text("Parado  →  Mac acordado esperando os agentes")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 18)
            Text("Não achou o ícone? Em Macs com notch a barra pode estar cheia, e apps como o Bartender escondem ícones novos. Abrir o LlMBO de novo pelo Finder ou pelo Spotlight sempre mostra a janela.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if !engine.helperInstalled {
                Text("Lembrete: falta a permissão de administrador para manter o Mac acordado.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.bronze2)
                    .padding(.top, 10)
            }
        }
    }
}
