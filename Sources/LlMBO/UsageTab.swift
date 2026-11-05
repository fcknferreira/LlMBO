import SwiftUI

/// Aba Uso: limites (5 horas e semanal) e tokens do Claude Code e do Codex, e o que fazer quando o limite
/// estoura. Tudo lido de arquivos locais (UsageStore).
struct UsageTab: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var usage = UsageStore.shared
    @ObservedObject private var codexResume = Engine.shared.codexResume

    private var tokensInfo: String {
        String(localized: "Contados dos arquivos de conversa no seu Mac (entrada, cache e saída). Nada é enviado pela internet.")
    }

    /// Por que os limites do Claude Code ainda não aparecem.
    private var claudeLimitsHint: String {
        if engine.claudeLimits {
            return engine.claudeCLIFound ? String(localized: "Os limites aparecem em até 1 minuto.")
                                         : String(localized: "Não achei o Claude Code de terminal neste Mac.")
        }
        return String(localized: "Ligue a leitura abaixo para ver os limites.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CanaryNotes(area: .usage)
            // Primeiro o que fazer no limite, uma escolha por agente; depois o uso de cada um.
            CardSection(title: String(localized: "Ao bater no limite"),
                        info: String(localized: "Cada agente tem a sua escolha, porque nem todos continuam sozinhos quando o limite volta: o Claude Code continua; o Antigravity e o Codex não. As travas de segurança da aba Repouso continuam valendo: bateria no mínimo, tempo máximo e temperatura soltam o Mac e cancelam o despertar agendado. Com a bateria no mínimo, o Mac quente ou o LlMBO desligado, ele também não agenda despertar nem retoma o Codex.")) {
                Row(title: "Claude Code",
                    subtitle: engine.quotaMode == .wake && !engine.claudeLimits
                        ? String(localized: "Precisa da leitura dos limites.") : nil,
                    info: String(localized: "O Claude Code espera o limite voltar e continua a tarefa sozinho, mas só se o Mac não estiver dormindo há mais de ~30 min na hora do reset. “Acordar no reset” deixa o Mac dormir e o acorda 2 min antes do reset para ele continuar; precisa da leitura dos limites no cartão do Claude Code. “Ficar acordado” segura o Mac até o reset. Limites que voltam em mais de 24 h não são esperados.")) {
                    QuotaModePicker(selection: engine.quotaMode, recommendWake: true) { engine.quotaMode = $0 }
                }
                // Antigravity: não continua sozinho; a hora do reset vem da cota lida pelo Antigravity aberto.
                if engine.antigravityListed {
                    CardDivider()
                    Row(title: "Antigravity",
                        subtitle: engine.antigravityQuotaMode == .wake && !engine.antigravityQuota
                            ? String(localized: "Precisa da leitura da cota pelo Antigravity aberto.") : nil,
                        info: String(localized: "O Antigravity não continua sozinho quando o limite volta: acordar ou ficar acordado só ajuda se você for retomar a conversa (por exemplo, à distância). “Acordar no reset” deixa o Mac dormir e o acorda 2 min antes do reset; “Ficar acordado” segura o Mac até lá. “Acordar no reset” precisa da leitura da cota no cartão do Antigravity, que diz a hora do reset; sem ela, “Ficar acordado” segura por até 5 horas."),
                        warning: true) {   // ele não continua sozinho depois do limite
                        QuotaModePicker(selection: engine.antigravityQuotaMode, recommendWake: false) { engine.antigravityQuotaMode = $0 }
                    }
                }
                // Codex: não continua sozinho; o LlMBO pode retomar a sessão (opcional, desligado por padrão).
                if engine.codexAutoResume || engine.agents.contains(where: { $0.id == "codex" }) {
                    CardDivider()
                    ToggleRow(title: String(localized: "Retomar o Codex depois do limite"),
                              info: String(localized: "O Codex não continua sozinho quando o limite de uso volta. Ligado, quando uma sessão do Codex para no limite, o LlMBO avisa, acorda o Mac no reset e retoma a sessão em segundo plano com “codex exec resume”, com permissão para editar só a pasta da sessão. O trabalho continua na mesma sessão, mas fora da janela que estava aberta: abra a sessão no Codex para ver o resultado. Você recebe um aviso ao agendar, ao retomar e ao terminar. Com o LlMBO desligado, a bateria no mínimo ou o Mac quente, espera isso passar para retomar. Desligado, o LlMBO não faz nada com o Codex."),
                              isOn: $engine.codexAutoResume)
                    ForEach(codexResume.pending, id: \.stop.key) { p in
                        CardDivider()
                        Row(title: String(localized: "Retomada do Codex agendada"), subtitle: p.folder) {
                            Text(UsageFormat.when(p.at)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                if engine.quotaMode == .wake || (engine.antigravityListed && engine.antigravityQuotaMode == .wake) || engine.codexAutoResume, engine.helperInstalled, !engine.canScheduleWake {
                    CardDivider()
                    Row(title: String(localized: "Permissão"),
                        subtitle: String(localized: "Para acordar o Mac, a permissão precisa ser atualizada (pede a senha uma vez).")) {
                        Button(String(localized: "Atualizar permissão")) { engine.installHelper() }
                            .buttonStyle(.pill(.primary))
                    }
                }
                if let w = engine.scheduledWake {
                    CardDivider()
                    Row(title: String(localized: "Despertar agendado")) {
                        Text(UsageFormat.when(w)).foregroundStyle(Theme.muted)
                    }
                }
            }

            CardSection(title: "Claude Code", info: tokensInfo) {
                if usage.claude.fiveHour == nil && usage.claude.weekly == nil {
                    Row(title: String(localized: "Limites de uso"), subtitle: claudeLimitsHint) { EmptyView() }
                } else {
                    LimitRows(usage: usage.claude)
                }
                CardDivider()
                ToggleRow(title: String(localized: "Ler limites de uso"),
                          info: String(localized: "Ligado, o LlMBO lê os limites de 5 horas e da semana de dois jeitos. A cada 5 minutos, roda o comando /usage do Claude Code de terminal, que vem junto com o app Claude: funciona mesmo se você usa o Claude Code só pelo app Claude, não gasta tokens, não grava sessão nem dispara hooks. E vira a barra de status no rodapé do Claude Code de terminal, que recebe os limites a cada resposta: continua mostrando a barra que você já tinha (sem uma, mostra uma linha curta com os limites), e desligar devolve a anterior. Vale a leitura mais nova. Quem consulta a Anthropic é o Claude Code, com o login dele; o LlMBO não se conecta à internet e só lê o percentual e a hora em que cada limite volta."),
                          isOn: Binding(get: { engine.claudeLimits }, set: { engine.setClaudeLimits($0) }))
                CardDivider()
                TokenRows(usage: usage.claude)
            }

            // Os outros agentes com uso gravado no Mac (Codex, Antigravity, Gemini CLI, Qwen Code, OpenCode), cada um
            // no seu cartão. O do Antigravity aparece também sem tokens, para a opção da cota.
            ForEach(UsageStore.order.filter { id in
                id != "claude" && (usage.byAgent[id] != nil || (id == "antigravity" && engine.antigravityListed))
            }, id: \.self) { id in
                let u = usage.byAgent[id] ?? AgentUsage()
                CardSection(title: AgentConfig.catalog.first { $0.id == id }?.name ?? id, info: tokensInfo) {
                    if id == "antigravity" && engine.antigravityListed {
                        AntigravityQuotaRows(usage: u, enabled: engine.antigravityQuota)
                        ToggleRow(title: String(localized: "Ler a cota pelo Antigravity aberto"),
                                  info: String(localized: "O Antigravity não grava a cota no disco: ele a consulta no Google. Ligado, o LlMBO pergunta a cota ao servidor que o app e o IDE do Antigravity abrem dentro do próprio Mac (127.0.0.1), uma vez por minuto e só com ele aberto. Quem fala com o Google é o Antigravity, com o login dele; o LlMBO não se conecta à internet e não lê a sua conta. Com a cota, o LlMBO sabe a hora em que o limite volta e pode acordar o Mac nessa hora. Usa um endereço interno do Antigravity: se uma atualização mudar, a cota só deixa de aparecer."),
                                  isOn: $engine.antigravityQuota)
                        CardDivider()
                    } else if u.fiveHour != nil || u.weekly != nil {
                        LimitRows(usage: u)
                        CardDivider()
                    }
                    TokenRows(usage: u)
                }
            }

        }
        .modifier(TabFrame())

    }
}

/// Lista do que fazer no limite. "(recomendado)" só onde o agente continua sozinho depois do reset (Claude Code).
private struct QuotaModePicker: View {
    let selection: QuotaMode
    let recommendWake: Bool
    let onSelect: (QuotaMode) -> Void

    private func title(_ m: QuotaMode) -> String {
        m == .wake && !recommendWake ? String(localized: "Acordar no reset") : m.title
    }

    var body: some View {
        Dropdown(groups: [DropdownGroup(items: QuotaMode.allCases.map { DropdownItem(id: $0, title: title($0)) })],
                 selection: selection, width: 250, onSelect: onSelect) {
            DropdownLabel(text: title(selection))
        }
    }
}

private struct LimitRows: View {
    let usage: AgentUsage

    var body: some View {
        if let w = usage.fiveHour {
            LimitRow(title: String(localized: "Limite de 5 horas"), window: w)
        }
        if usage.fiveHour != nil && usage.weekly != nil { CardDivider() }
        if let w = usage.weekly {
            LimitRow(title: String(localized: "Limite semanal"), window: w)
        }
    }
}

/// Antigravity: uma linha por grupo de modelos, com a janela mais usada (5 horas ou semanal).
private struct AntigravityQuotaRows: View {
    let usage: AgentUsage
    let enabled: Bool

    var body: some View {
        if enabled && usage.groups.isEmpty {
            Row(title: String(localized: "Limites de uso"),
                subtitle: String(localized: "Abra o app ou o IDE do Antigravity para ver a cota.")) { EmptyView() }
            CardDivider()
        }
        if enabled {
            ForEach(usage.groups, id: \.name) { g in
                if let f = g.fullest {
                    LimitRow(title: g.name, window: f.window, detail: f.title)
                    CardDivider()
                }
            }
        }
    }
}

private struct LimitRow: View {
    let title: String
    let window: LimitWindow
    var detail: String?

    var body: some View {
        Row(title: title, subtitle: [detail, UsageFormat.resets(window.resetsAt)].compactMap { $0 }.joined(separator: " · ")) {
            HStack(spacing: 10) {
                UsageBar(fraction: window.usedPercent / 100)
                Text("\(Int(window.usedPercent.rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(window.usedPercent >= 90 ? Theme.bronze2 : Theme.text)
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
    }
}

/// Barra fina no visual do tema: trilho cinza, preenchimento bronze.
private struct UsageBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.08))
            Capsule().fill(Theme.bronze2)
                .frame(width: max(3, 110 * min(max(fraction, 0), 1)))
        }
        .frame(width: 110, height: 5)
    }
}

private struct TokenRows: View {
    let usage: AgentUsage

    var body: some View {
        TokenRow(title: String(localized: "Tokens nas últimas 5 horas"), value: usage.tokens5h)
        CardDivider()
        TokenRow(title: String(localized: "Tokens hoje"), value: usage.tokensToday)
        CardDivider()
        TokenRow(title: String(localized: "Tokens em 7 dias"), value: usage.tokens7d)
    }
}

private struct TokenRow: View {
    let title: String
    let value: Int

    var body: some View {
        Row(title: title) {
            Text(value.formatted(.number.notation(.compactName)))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
    }
}

enum UsageFormat {
    /// "15:45" hoje; "seg. 09:00" em outro dia.
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jmm" : "EEEjmm")
        return f.string(from: d)
    }

    static func resets(_ d: Date) -> String {
        let t = when(d)
        return Calendar.current.isDateInToday(d) ? String(localized: "Volta às \(t)") : String(localized: "Volta \(t)")
    }
}

/// Quem mais impede o Mac de dormir: asserções de energia de outros processos (`pmset -g assertions`) e o
/// repouso desligado sem ser pelo LlMBO. `caffeinate` esquecido dá para encerrar daqui.
struct BlockersSection: View {
    @ObservedObject var model: SleepBlockersModel

    var body: some View {
        CardSection(title: String(localized: "Quem mais segura o Mac"),
                    info: String(localized: "Processos que impedem o Mac de dormir sozinho por inatividade, com a tampa aberta. O caffeinate é o caso comum: agentes e scripts às vezes o deixam rodando. Com a tampa fechada, o que segura o Mac é o repouso desligado (pmset disablesleep), que só o LlMBO deveria ligar.")) {
            if model.disabledOutside {
                Row(title: String(localized: "Repouso desligado por fora do LlMBO"),
                    subtitle: String(localized: "Com a tampa fechada, o Mac não vai dormir.")) {
                    Button(String(localized: "Religar o repouso")) {
                        Power.setSleepDisabled(false)
                        model.refresh()
                    }
                    .buttonStyle(.pill(.primary))
                }
                if !model.blockers.isEmpty { CardDivider() }
            }
            if model.blockers.isEmpty && !model.disabledOutside {
                Row(title: String(localized: "Nenhum outro processo segura o Mac.")) { EmptyView() }
            }
            // No fim da aba Geral: no máximo 3, para a aba caber sem rolar; primeiro os que dá para encerrar e os mais antigos.
            let shown = Array(model.blockers.sorted { ($0.canStop ? 1 : 0, $0.seconds) > ($1.canStop ? 1 : 0, $1.seconds) }.prefix(3))
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, b in
                if i > 0 { CardDivider() }
                Row(title: b.name, subtitle: "\(b.detail.count > 60 ? b.detail.prefix(59) + "…" : b.detail) · \(Self.duration(b.seconds))") {
                    if b.canStop {
                        Button(String(localized: "Encerrar")) {
                            SleepBlockers.stop(b)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.refresh() }
                        }
                        .buttonStyle(.pill)
                    }
                }
            }
            if model.blockers.count > shown.count {
                CardDivider()
                Row(title: String(localized: "E mais \(model.blockers.count - shown.count).")) { EmptyView() }
            }
        }
    }

    private static func duration(_ s: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: TimeInterval(s)) ?? ""
    }
}
