import Foundation

/// O que o app mostra nos widgets. O app grava `widget.json` em Application Support/LlMBO a cada mudança e o
/// widget (sandbox, com exceção de leitura só dessa pasta) lê. Os textos já vêm traduzidos pelo app, no idioma
/// escolhido em Geral; o widget só desenha.
public struct WidgetSnapshot: Codable, Equatable {
    public enum State: String, Codable { case holding, normal, off }

    public struct Limit: Codable, Equatable {
        /// "Claude Code", "Antigravity · Gemini 3 Pro"…
        public var agent: String
        /// "Limite de 5 horas" / "Limite semanal".
        public var label: String
        /// Rótulo curto para o widget pequeno: "5 h" / "7 d".
        public var short: String
        public var percent: Double
        /// "Volta às 16:00".
        public var resets: String
        public init(agent: String, label: String, short: String, percent: Double, resets: String) {
            self.agent = agent; self.label = label; self.short = short; self.percent = percent; self.resets = resets
        }
    }

    public var state: State
    /// "Segurando o Mac" / "Repouso normal" / "LlMBO desligado".
    public var title: String
    /// Quem segura e por quê ("Claude Code · hook"), ou o fim da última leva ("Agentes terminaram às 05:06").
    public var lines: [String]
    public var limitsTitle: String
    /// Sem nenhum limite lido: o que dizer no lugar ("Sem dados de uso").
    public var noLimits: String
    public var limits: [Limit]

    public init(state: State, title: String, lines: [String], limitsTitle: String, noLimits: String, limits: [Limit]) {
        self.state = state; self.title = title; self.lines = lines
        self.limitsTitle = limitsTitle; self.noLimits = noLimits; self.limits = limits
    }

    public static let fileName = "widget.json"
    /// Tipos (kind) dos widgets: o app pede para recarregar por eles.
    public static let statusKind = "com.llmbo.widget.status"
    public static let limitsKind = "com.llmbo.widget.limits"

    public func encoded() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(self)
    }

    public static func decode(_ data: Data) -> WidgetSnapshot? {
        try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
