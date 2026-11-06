import SwiftUI
import WidgetKit
import CoreText

let now = Date()
func L(_ a: String, _ l: String, _ s: String, _ p: Double, _ r: String) -> WidgetSnapshot.Limit { .init(agent: a, label: l, short: s, percent: p, resets: r) }
let lim = [L("Claude Code", "Limite de 5 horas", "5 h", 23, "Volta às 18:40"), L("Claude Code", "Limite semanal", "7 d", 41, "Volta qua. 09:00"),
           L("Antigravity · Gemini 3 Pro", "Limite de 5 horas", "5 h", 92, "Volta às 17:10")]
let cases: [(String, WidgetSnapshot)] = [
  ("holding", WidgetSnapshot(state: .holding, title: "Segurando o Mac", lines: ["Claude Code · hook", "Codex · tarefa em segundo plano"], limitsTitle: "Limites de uso", noLimits: "Sem limites lidos ainda. Veja a aba Uso.", limits: lim)),
  ("normal", WidgetSnapshot(state: .normal, title: "Repouso normal", lines: ["Agentes terminaram às 05:06"], limitsTitle: "Limites de uso", noLimits: "Sem limites lidos ainda. Veja a aba Uso.", limits: [])),
  ("off", WidgetSnapshot(state: .off, title: "LlMBO desligado", lines: ["O Mac dorme como sempre."], limitsTitle: "Limites de uso", noLimits: "Sem limites lidos ainda. Veja a aba Uso.", limits: lim)),
]
@MainActor func save<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat, _ name: String) {
  // Moldura do widget no macOS: canto ~22. Sem margem do sistema (o pior caso, como na mesa do macOS 27): a margem vem do próprio widget.
  let framed = v.frame(width: w, height: h).background(W.bg)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .padding(14).background(Color(red: 0.32, green: 0.36, blue: 0.42))
    .environment(\.colorScheme, .dark)
  let r = ImageRenderer(content: framed); r.scale = 2
  guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:]) else { return }
  try? png.write(to: URL(fileURLWithPath: name))
}
@main struct Main { @MainActor static func main() {
  for f in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "Fonts"), includingPropertiesForKeys: nil)) ?? [] { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
  let tag = CommandLine.arguments.dropFirst().first ?? "antes"
  for (n, s) in cases {
    let e = Entry(date: now, snap: s)
    save(StatusView(family: .systemSmall, entry: e), 170, 170, "\(tag)-status-s-\(n).png")
    save(StatusView(family: .systemMedium, entry: e), 364, 170, "\(tag)-status-m-\(n).png")
  }
  let e = Entry(date: now, snap: cases[0].1)
  save(LimitsView(family: .systemSmall, entry: e), 170, 170, "\(tag)-limits-s.png")
  save(LimitsView(family: .systemMedium, entry: e), 364, 170, "\(tag)-limits-m.png")
  save(LimitsView(family: .systemSmall, entry: Entry(date: now, snap: cases[1].1)), 170, 170, "\(tag)-limits-s-empty.png")
  save(StatusView(family: .systemSmall, entry: Entry(date: now, snap: nil)), 170, 170, "\(tag)-openapp.png")
  print("ok")
}}
