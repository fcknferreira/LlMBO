// Gera os ícones do LlMBO (1024 px): buraco negro estilo Gargantua em traço uniforme — disco reto passando
// na frente, arcos de lente em cima e embaixo — com sombreado só por dentro dos traços e do vazio.
// Uso: swift Design/render_icon.swift Resources   → AppIcon.png (escuro) e AppIconLight.png (claro, invertido)
//      swift Design/render_icon.swift Social --social → versões quadradas de 2048 px com o fundo até a borda,
//      sem o formato do macOS nem sombra, para posts, e circulares (fora do círculo transparente) para perfil.
import AppKit

let S: CGFloat = 1024

struct Palette {
    let bgCenter: NSColor, bgEdge: NSColor
    let hole: NSColor                 // o "vazio" dentro do anel
    let strokeHot: NSColor, strokeCool: NSColor   // gradiente do traço (lado que se aproxima → lado que se afasta)
    let glow: NSColor                 // luz que cai para dentro do vazio
    let innerGlow: CGFloat
    let shade: NSColor, shadeAlpha: CGFloat        // sombreado dentro da espessura do traço
}

let dark = Palette(
    bgCenter: NSColor(srgbRed: 0.075, green: 0.070, blue: 0.095, alpha: 1),
    bgEdge: NSColor(srgbRed: 0.010, green: 0.010, blue: 0.016, alpha: 1),
    hole: .black,
    strokeHot: NSColor(srgbRed: 1.00, green: 0.96, blue: 0.88, alpha: 1),
    strokeCool: NSColor(srgbRed: 0.98, green: 0.66, blue: 0.32, alpha: 1),
    glow: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 1), innerGlow: 0.42,
    shade: NSColor(srgbRed: 0.25, green: 0.10, blue: 0.0, alpha: 1), shadeAlpha: 0.40)

// Mesmo desenho, vazio e sombreado do escuro; só o fundo inverte. O traço é um bronze que contrasta
// tanto com o vazio preto quanto com o papel, para nenhum detalhe sumir (anel, disco na frente do vazio).
let light = Palette(
    bgCenter: NSColor(srgbRed: 0.995, green: 0.990, blue: 0.975, alpha: 1),
    bgEdge: NSColor(srgbRed: 0.880, green: 0.865, blue: 0.835, alpha: 1),
    hole: .black,
    strokeHot: NSColor(srgbRed: 0.86, green: 0.55, blue: 0.22, alpha: 1),
    strokeCool: NSColor(srgbRed: 0.66, green: 0.38, blue: 0.14, alpha: 1),
    glow: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 1), innerGlow: 0.42,
    shade: NSColor(srgbRed: 0.25, green: 0.10, blue: 0.0, alpha: 1), shadeAlpha: 0.40)

/// Squircle no grid de ícones da Apple (824 de 1024), superelipse n = 5.
func squircle(_ rect: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5, a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * copysign(pow(abs(c), 2 / n), c), y = b * copysign(pow(abs(s), 2 / n), s)
        let pt = CGPoint(x: rect.midX + x, y: rect.midY + y)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func render(_ pal: Palette, to url: URL, social: Bool = false, circle: Bool = false) {
    let px = social ? 2048 : Int(S)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)   // desenha sempre na grade de 1024

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let full = CGRect(x: 0, y: 0, width: S, height: S)
    let shape = circle ? CGPath(ellipseIn: full, transform: nil)
        : social ? CGPath(rect: full, transform: nil) : squircle(tile)
    let c = CGPoint(x: S / 2, y: S / 2)

    // Sombra do próprio ícone, como nos ícones do macOS
    ctx.saveGState()
    if !social { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor.black.withAlphaComponent(0.30).cgColor) }
    ctx.addPath(shape); ctx.setFillColor(pal.bgEdge.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Fundo: gradiente radial com leve luz vinda de cima
    let bg = CGGradient(colorsSpace: space, colors: [pal.bgCenter.cgColor, pal.bgEdge.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: c.x, y: c.y + 60), startRadius: 0,
                           endCenter: c, endRadius: 560, options: [.drawsAfterEndLocation])

    // Geometria (estilo Gargantua, com o horizonte reto). Traço uniforme em tudo.
    let w: CGFloat = 18                     // espessura do traço
    let R: CGFloat = 122                    // anel de fótons (centro do traço) = borda do vazio
    let gap: CGFloat = 15                   // vão entre elementos que se cruzam
    let lensRX = R + w + gap                // arcos de lente: a parte de trás do disco, curvada pela gravidade
    let lensTop = lensRX + 36               // em cima, mais alto (imagem principal)
    let lensBottom = lensRX - 4             // embaixo, mais baixo e fraco (imagem secundária)
    let diskA: CGFloat = 300                // meia largura do disco: uma linha reta

    let ring = CGPath(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2), transform: nil)
    func halfEllipse(ry: CGFloat, top: Bool) -> CGPath {
        let p = CGMutablePath()
        let t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: lensRX, y: ry)
        p.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: top, transform: t)
        return p
    }
    let lensUp = halfEllipse(ry: lensTop, top: true)
    let lensDown = halfEllipse(ry: lensBottom, top: false)
    let disk = CGMutablePath()
    disk.move(to: CGPoint(x: c.x - diskA, y: c.y)); disk.addLine(to: CGPoint(x: c.x + diskA, y: c.y))

    // Faixa do disco: o que passa atrás dele some (o vão).
    let band = CGRect(x: 0, y: c.y - w / 2 - gap, width: S, height: w + gap * 2)
    func outsideBand() {
        ctx.addRect(CGRect(x: 0, y: 0, width: S, height: S)); ctx.addRect(band); ctx.clip(using: .evenOdd)
    }

    // Traço com sombreado por dentro: gradiente Doppler (esquerda mais intensa) e, dentro da espessura,
    // mais luz do lado de dentro (voltado ao vazio) e menos do lado de fora. Nada vaza para fora do traço.
    func strokeShaded(_ path: CGPath, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path); ctx.setLineWidth(w); ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [pal.strokeHot.cgColor, pal.strokeCool.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x - diskA, y: c.y), end: CGPoint(x: c.x + diskA, y: c.y),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Sombreado interno: escurece (ou clareia, no claro) do miolo para fora.
        let shade = CGGradient(colorsSpace: space, colors: [pal.shade.withAlphaComponent(0).cgColor,
                                                            pal.shade.withAlphaComponent(pal.shadeAlpha).cgColor] as CFArray,
                               locations: [0, 1])!
        ctx.drawRadialGradient(shade, startCenter: c, startRadius: R - w, endCenter: c, endRadius: lensTop + w * 2,
                               options: [.drawsAfterEndLocation])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // 1) O vazio, com a luz do anel caindo para dentro dele (sombreado interno)
    ctx.addPath(ring); ctx.setFillColor(pal.hole.cgColor); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(ring); ctx.clip()
    let inner = CGGradient(colorsSpace: space, colors: [pal.glow.withAlphaComponent(0).cgColor,
                                                        pal.glow.withAlphaComponent(pal.innerGlow).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(inner, startCenter: c, startRadius: R * 0.45, endCenter: c, endRadius: R, options: [])
    ctx.restoreGState()

    // 2) Arcos de lente e anel de fótons, interrompidos onde o disco passa na frente
    ctx.saveGState()
    outsideBand()
    strokeShaded(lensDown, alpha: 0.45)
    strokeShaded(lensUp)
    strokeShaded(ring)
    ctx.restoreGState()

    // 3) Disco: reto, inteiro, por cima de tudo
    strokeShaded(disk)

    ctx.restoreGState()   // clip do squircle

    // Contorno sutil do squircle
    if !social {
    ctx.addPath(shape); ctx.setLineWidth(2)
    ctx.setStrokeColor((pal === dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor)
    ctx.strokePath()
    }

    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func === (a: Palette, b: Palette) -> Bool { a.bgCenter == b.bgCenter }

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
if CommandLine.arguments.contains("--social") {
    render(dark, to: out.appendingPathComponent("LlMBO-icone-escuro-2048.png"), social: true)
    render(light, to: out.appendingPathComponent("LlMBO-icone-claro-2048.png"), social: true)
    render(dark, to: out.appendingPathComponent("LlMBO-icone-escuro-circulo.png"), social: true, circle: true)
    render(light, to: out.appendingPathComponent("LlMBO-icone-claro-circulo.png"), social: true, circle: true)
} else {
    render(dark, to: out.appendingPathComponent("AppIcon.png"))
    render(light, to: out.appendingPathComponent("AppIconLight.png"))
}
print("ok")
