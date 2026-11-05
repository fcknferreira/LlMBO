import AppKit
import SwiftUI

/// Rascunho editável de um agente (texto livre nos campos; vira AgentConfig ao salvar).
final class AgentDraft: ObservableObject, Identifiable {
    let id = UUID()
    /// Id do agente sendo editado; nil = agente novo.
    let originalID: String?
    private let original: AgentConfig?

    @Published var name: String
    /// "codigo", "ide" (extensão de IDE) ou "local" (IA local).
    @Published var kind: String
    @Published var executables: String
    @Published var argsContains: String
    @Published var folders: String
    @Published var cpuThreshold: Double
    /// 0 = a GPU não conta.
    @Published var gpuThreshold: Double
    @Published var probe: String?

    init(_ a: AgentConfig? = nil) {
        original = a
        originalID = a?.id
        name = a?.name ?? ""
        kind = a?.kind ?? "codigo"
        executables = (a?.executables ?? []).joined(separator: ", ")
        argsContains = (a?.argsContains ?? []).joined(separator: ", ")
        folders = (a?.activityPaths ?? []).joined(separator: ", ")
        cpuThreshold = a?.cpuThreshold ?? 5
        gpuThreshold = a?.gpuLimit ?? 0
    }

    var isNew: Bool { originalID == nil }

    private static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func config(usedIDs: Set<String>) -> AgentConfig {
        var c = original ?? AgentConfig(id: "", name: "", executables: [], argsContains: [], cpuThreshold: 5)
        c.id = originalID ?? AgentConfig.slug(name, avoiding: usedIDs)
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.executables = Self.list(executables)
        c.argsContains = Self.list(argsContains)
        c.cpuThreshold = cpuThreshold
        // Igual ao padrão do tipo = nil (segue o padrão se ele mudar); diferente = valor próprio (0 = não conta).
        var plain = c
        plain.gpuThreshold = nil
        plain.kind = kind
        c.gpuThreshold = plain.gpuLimit ?? 0 == gpuThreshold ? nil : gpuThreshold
        c.activityPaths = Self.list(folders)
        c.kind = kind
        // Extensão roda dentro da IDE: a CPU é da IDE inteira, então não conta.
        if kind == "ide" { c.useCPU = false } else if original?.kind == "ide" { c.useCPU = nil }
        return c
    }
}

struct AgentEditor: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var draft: AgentDraft
    @ObservedObject var model: AgentsTabModel

    private var usedIDs: Set<String> { Set(engine.agents.map(\.id)) }
    private var config: AgentConfig { draft.config(usedIDs: usedIDs) }
    private var valid: Bool { !config.name.isEmpty && config.hasRule }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nome", text: $draft.name, prompt: Text("ex.: Meu Agente"))
                    Picker("Tipo", selection: $draft.kind) {
                        Text("Agente de código").tag("codigo")
                        Text("Extensão de IDE").tag("ide")
                        Text("IA local").tag("local")
                    }
                }

                Section {
                    TextField("Executável", text: $draft.executables, prompt: Text("ex.: ollama, llama-server"))
                    TextField("Trecho do comando", text: $draft.argsContains, prompt: Text("ex.: MeuApp.app/Contents/MacOS/"))
                    LabeledContent("Trabalhando acima de") {
                        HStack(spacing: 6) {
                            Text("\(Int(draft.cpuThreshold)) % CPU").monospacedDigit()
                            Stepper("CPU", value: $draft.cpuThreshold, in: 1...200, step: 1).labelsHidden()
                        }
                    }
                    LabeledContent("Ou GPU acima de") {
                        HStack(spacing: 6) {
                            Text(draft.gpuThreshold > 0 ? "\(Int(draft.gpuThreshold)) % GPU" : String(localized: "Não conta"))
                                .monospacedDigit()
                            Stepper("GPU", value: $draft.gpuThreshold, in: 0...100, step: 5).labelsHidden()
                        }
                    }
                    HStack {
                        Button("Testar agora") { runProbe() }.handCursor()
                        if let p = draft.probe {
                            Text(p).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Como reconhecer o processo")
                } footer: {
                    note(String(localized: "Nome do executável (como aparece no Monitor de Atividade) ou um trecho da linha de comando. Separe vários com vírgula. A CPU soma o processo e todos os filhos."))
                    note(String(localized: "A GPU também soma o processo e os filhos. Serve para IA local (Ollama, LM Studio, MLX), que trabalha na GPU com a CPU quase parada."))
                }

                Section {
                    HStack {
                        TextField("Pastas", text: $draft.folders, prompt: Text("opcional"))
                        Button("Escolher…") { chooseFolder() }.handCursor()
                    }
                } header: {
                    Text("Arquivos de sessão")
                } footer: {
                    note(String(localized: "Se o agente grava a conversa ou o log em uma pasta, escrita recente conta como trabalho, mesmo com a CPU parada esperando o modelo."))
                }

                Section {
                    Text(hookCommands)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copiar comandos") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hookCommands, forType: .string)
                    }
                    .handCursor()
                } header: {
                    Text("Avisar na hora (opcional)")
                } footer: {
                    note(String(localized: "Se o agente aceita hooks ou scripts, chame o primeiro ao começar e o segundo ao terminar. É o sinal mais confiável."))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                if !draft.isNew, let id = draft.originalID {
                    Button("Remover agente", role: .destructive) {
                        engine.removeAgent(id)
                        model.draft = nil
                    }
                    .handCursor()
                }
                Spacer()
                Button("Cancelar") { model.draft = nil }
                    .keyboardShortcut(.cancelAction)
                    .handCursor()
                Button(draft.isNew ? String(localized: "Adicionar") : String(localized: "Salvar")) {
                    engine.saveAgent(config)
                    model.draft = nil
                }
                .keyboardShortcut(.defaultAction)
                .handCursor()
                .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hookCommands: String {
        let script = "\"\(Paths.signalScript.path)\""
        return "\(script) \(config.id) busy\n\(script) \(config.id) idle"
    }

    private func runProbe() {
        let c = config
        guard !c.executables.isEmpty || !c.argsContains.isEmpty else {
            draft.probe = String(localized: "Preencha o executável ou um trecho do comando.")
            return
        }
        let r = engine.probe(c)
        draft.probe = r.processes == 0
            ? String(localized: "Nenhum processo encontrado agora.")
            : r.processes == 1
                ? String(localized: "1 processo · \(Int(r.cpu)) % CPU agora")
                : String(localized: "\(r.processes) processos · \(Int(r.cpu)) % CPU agora")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Escolher"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        let current = draft.folders.trimmingCharacters(in: .whitespaces)
        draft.folders = current.isEmpty ? path : current + ", " + path
    }
}
