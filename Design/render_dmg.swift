// Fundo da janela do DMG (660 × 440 pt, em 1× e 2×), no visual do site: fundo escuro, um arco bronze do app para
// Aplicativos e, embaixo, o aviso do "Abrir Mesmo Assim" em inglês (primeiro) e português — o app não abre antes
// desse passo, então o aviso tem que estar aqui fora.
// Uso: swift Design/render_dmg.swift <pasta>   → dmg-background.png e dmg-background@2x.png
//
// Passada do unslop (06/11/2026): o ícone do app é o único ponto de cor; o bronze só aparece no arco (a órbita do
// buraco negro). Sem brilho, sem itálico, vermelho só na frase que avisa, tudo na grade de 4 pt.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
// Cores do site (Theme.swift).
let bg = color(0x08080A), text = color(0xECEBE8), muted = color(0x8D8A85), bronze = color(0xB8763A)
let hairline = color(0xECEBE8, 0.08), warn = color(0xFF7A6B)
// O Finder escreve o nome dos ícones em preto sobre qualquer imagem de fundo (também no modo escuro) e não deixa
// mudar essa cor, então cada nome ganha uma faixa clara atrás dele, no cinza claro da paleta.
let plate = color(0xD9D6D0)

// Faixas: (centro x, largura, altura), topo comum. Medidas com o DMG montado no Finder (06/11/2026, macOS 27.2):
// ícone de 96 pt centrado em y 140, nome em 12 pt de y 199 a 211 (o do Read me quebra e vai até 227), e cada
// faixa tem 8 pt de folga dos lados.
let plateTop: CGFloat = 194
let plates: [(CGFloat, CGFloat, CGFloat)] = [(149, 56, 20), (390, 88, 20), (559, 152, 36)]

let W: CGFloat = 660, H: CGFloat = 440
let left: CGFloat = 40, textX: CGFloat = 64, textW: CGFloat = W - 64 - 40

// Passos: inglês, português e, no passo 2, o trecho que vai em vermelho em cada idioma.
let steps: [(en: String, pt: String, warnEN: String?, warnPT: String?)] = [
    ("Drag LlMBO to Applications and open it", "Arraste o LlMBO para Aplicativos e abra", nil, nil),
    ("Don\u{2019}t click \u{201C}Move to Trash\u{201D}. Click \u{201C}Done\u{201D}: macOS only warns because LlMBO is free and doesn\u{2019}t pay Apple",
     "Não clique em \u{201C}Mover para o Lixo\u{201D}. Clique em \u{201C}Concluído\u{201D}: o aviso só aparece porque o LlMBO é grátis e não paga a Apple",
     "Don\u{2019}t click \u{201C}Move to Trash\u{201D}", "Não clique em \u{201C}Mover para o Lixo\u{201D}"),
    ("System Settings › Privacy & Security › Open Anyway (shown ~1 h), then your password",
     "Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim (aparece por ~1 h) e a senha", nil, nil),
]

func styled(_ s: String, size: CGFloat, color c: NSColor, warning: String?, warnColor: NSColor) -> NSAttributedString {
    let para = NSMutableParagraphStyle(); para.lineSpacing = 2
    let a = NSMutableAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size), .foregroundColor: c, .paragraphStyle: para])
    if let w = warning, let r = s.range(of: w) {
        a.addAttributes([.foregroundColor: warnColor, .font: NSFont.systemFont(ofSize: size, weight: .medium)],
                        range: NSRange(r, in: s))
    }
    return a
}

func height(_ a: NSAttributedString) -> CGFloat {
    ceil(a.boundingRect(with: NSSize(width: textW, height: 400), options: [.usesLineFragmentOrigin]).height)
}

func up4(_ v: CGFloat) -> CGFloat { ceil(v / 4) * 4 }

func render(scale: CGFloat, to file: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    // Contexto virado: origem no topo, como o Finder usa para as posições dos ícones.
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    bg.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Arco do app (x 150) para Aplicativos (x 390), passando por cima dos ícones (y 140).
    bronze.setStroke()
    let arc = NSBezierPath()
    arc.move(to: NSPoint(x: 212, y: 136))
    arc.curve(to: NSPoint(x: 328, y: 136), controlPoint1: NSPoint(x: 244, y: 108), controlPoint2: NSPoint(x: 296, y: 108))
    arc.lineWidth = 1.5; arc.lineCapStyle = .round; arc.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 318, y: 124)); head.line(to: NSPoint(x: 328, y: 136)); head.line(to: NSPoint(x: 313, y: 139))
    head.lineWidth = 1.5; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()

    plate.setFill()
    for (x, w, h) in plates {
        NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: plateTop, width: w, height: h), xRadius: 6, yRadius: 6).fill()
    }

    // Uma divisória só, entre os ícones e o aviso.
    hairline.setFill(); NSRect(x: left, y: 244, width: W - 2 * left, height: 1).fill()

    var top: CGFloat = 264
    for (i, s) in steps.enumerated() {
        let en = styled(s.en, size: 12, color: text, warning: s.warnEN, warnColor: warn)
        let pt = styled(s.pt, size: 11, color: muted, warning: s.warnPT, warnColor: warn.withAlphaComponent(0.8))
        NSAttributedString(string: "\(i + 1)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: muted,
        ]).draw(at: NSPoint(x: left, y: top))
        let hEN = height(en)
        en.draw(with: NSRect(x: textX, y: top, width: textW, height: hEN), options: [.usesLineFragmentOrigin])
        let ptTop = top + up4(hEN) + 4
        let hPT = height(pt)
        pt.draw(with: NSRect(x: textX, y: ptTop, width: textW, height: hPT), options: [.usesLineFragmentOrigin])
        top = ptTop + up4(hPT) + 8
    }
    if scale == 1 { print("fim do texto em y \(Int(top - 8)) de \(Int(H))") }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}

render(scale: 1, to: "\(out)/dmg-background.png")
render(scale: 2, to: "\(out)/dmg-background@2x.png")
print("ok: \(out)/dmg-background{,@2x}.png")
