// Fundo da janela do DMG (660 × 440 pt, em 1× e 2×), no visual do site: fundo escuro, seta bronze do app para
// Aplicativos e, embaixo, o aviso do "Abrir Mesmo Assim" em português e inglês — o app não abre antes desse
// passo, então o aviso tem que estar aqui fora.
// Uso: swift Design/render_dmg.swift <pasta>   → dmg-background.png e dmg-background@2x.png
import AppKit
import CoreText

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for name in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
    CTFontManagerRegisterFontsForURL(here.appendingPathComponent("Resources/Fonts/\(name).woff2") as CFURL, .process, nil)
}

func color(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
let bg = color(0xF5F2EC), text = color(0x1D1B18), muted = color(0x6E6860), faint = color(0x9A948A)
// Claro, como o ícone claro: o Finder escreve o nome dos ícones em preto sobre qualquer imagem de fundo
// (também no modo escuro), então fundo escuro deixava "LlMBO" e "Applications" ilegíveis.
let bronze1 = color(0x8A5A2B), bronze2 = color(0xB8763A), bronze3 = color(0xD9A066)

func serif(_ size: CGFloat, italic: Bool = false) -> NSFont {
    NSFont(name: italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size) ?? .systemFont(ofSize: size)
}

func draw(_ s: String, at p: CGPoint, font: NSFont, color: NSColor, width: CGFloat = 0, center: Bool = false) {
    let para = NSMutableParagraphStyle()
    para.alignment = center ? .center : .left
    para.lineSpacing = 2
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    if width > 0 {
        let h = attr.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin]).height
        attr.draw(with: NSRect(x: p.x, y: p.y - h, width: width, height: h), options: [.usesLineFragmentOrigin])
    } else {
        attr.draw(at: p)
    }
}

func render(scale: CGFloat, to file: String) {
    let W: CGFloat = 660, H: CGFloat = 440
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Coordenadas com origem no topo, como o Finder usa para as posições dos ícones.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    let flip = NSAffineTransform(); _ = flip

    bg.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    // Brilho bronze bem leve atrás dos ícones.
    let glow = NSGradient(colors: [bronze3.withAlphaComponent(0.18), bronze3.withAlphaComponent(0)])!
    glow.draw(fromCenter: NSPoint(x: 270, y: 140), radius: 0, toCenter: NSPoint(x: 270, y: 140), radius: 300, options: [])

    // Seta do app (x 150) para Aplicativos (x 390), na altura dos ícones (y 140); o "Leia antes de abrir" fica
    // à direita (x 560), depois de um traço vertical.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 214, y: 140))
    arrow.curve(to: NSPoint(x: 326, y: 140), controlPoint1: NSPoint(x: 246, y: 114), controlPoint2: NSPoint(x: 294, y: 114))
    arrow.lineWidth = 2; arrow.lineCapStyle = .round
    bronze2.withAlphaComponent(0.85).setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 315, y: 125)); head.line(to: NSPoint(x: 327, y: 141)); head.line(to: NSPoint(x: 308, y: 145))
    head.lineWidth = 2; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()

    color(0x000000, 0.10).setFill(); NSRect(x: 475, y: 90, width: 1, height: 110).fill()

    // Textos são desenhados sem o espelhamento (o NSAttributedString já espera origem no topo num contexto
    // virado), então volta ao sistema normal só para eles.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = ns
    func y(_ top: CGFloat) -> CGFloat { H - top }

    // Linha fina separando os ícones do aviso.
    color(0x000000, 0.10).setFill(); NSRect(x: 40, y: y(236), width: W - 80, height: 1).fill()

    draw("Antes de abrir · Before you open", at: CGPoint(x: 40, y: y(246) - 14),
         font: .systemFont(ofSize: 10, weight: .semibold), color: bronze1)
    let steps: [(String, String)] = [
        ("Arraste o LlMBO para Aplicativos e abra.", "Drag LlMBO to Applications and open it."),
        ("O macOS vai dizer que não pode verificar o app. É normal: o LlMBO é grátis e não paga a assinatura da Apple.",
         "macOS will say it can't verify the app. That's expected: LlMBO is free and doesn't pay for Apple's signing."),
        ("Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim.",
         "System Settings › Privacy & Security › Open Anyway."),
    ]
    var top: CGFloat = 268
    for (i, s) in steps.enumerated() {
        draw("\(i + 1)", at: CGPoint(x: 40, y: y(top) - 18), font: serif(19, italic: true), color: bronze2)
        draw(s.0, at: CGPoint(x: 62, y: y(top)), font: .systemFont(ofSize: 11.5), color: text, width: W - 110)
        draw(s.1, at: CGPoint(x: 62, y: y(top + 16) - (i == 1 ? 14 : 0)), font: .systemFont(ofSize: 10.5), color: muted, width: W - 110)
        top += i == 1 ? 48 : 34
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}

render(scale: 1, to: "\(out)/dmg-background.png")
render(scale: 2, to: "\(out)/dmg-background@2x.png")
print("ok: \(out)/dmg-background{,@2x}.png")
