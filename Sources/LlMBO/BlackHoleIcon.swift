import AppKit

/// Ícone da barra de menus: o mesmo buraco negro do ícone do app, em vetor (template, segue o tema).
/// Parado: o vazio com os arcos de lente em volta. Ativo: ganha o disco reto passando na frente.
enum BlackHoleIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            // O arco de cima (7,6) é mais alto que o de baixo (6,0): no centro da imagem a tinta
            // ficava ~1 pt acima dos outros ícones da barra (medido na tela, 06/11/2026). Desce 1 pt.
            let c = NSPoint(x: rect.midX, y: rect.midY - 1)
            let lw: CGFloat = 1.3
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Horizonte de eventos
            let holeR: CGFloat = 3.4
            NSBezierPath(ovalIn: NSRect(x: c.x - holeR, y: c.y - holeR, width: holeR * 2, height: holeR * 2)).fill()

            // Arcos de lente: em cima (mais alto) e embaixo (mais fraco)
            func lens(ry: CGFloat, top: Bool) -> NSBezierPath {
                let p = NSBezierPath()
                p.appendArc(withCenter: .zero, radius: 1, startAngle: 180, endAngle: 0, clockwise: top)
                var t = AffineTransform(translationByX: c.x, byY: c.y)
                t.scale(x: 6.2, y: ry)
                p.transform(using: t)
                p.lineWidth = lw
                return p
            }
            lens(ry: 7.6, top: true).stroke()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            lens(ry: 6.0, top: false).stroke()

            guard active else { return true }

            // Disco reto: apaga um vão em volta e desenha a linha por cima.
            let disk = NSBezierPath()
            disk.move(to: NSPoint(x: c.x - 9.2, y: c.y))
            disk.line(to: NSPoint(x: c.x + 9.2, y: c.y))
            disk.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            disk.lineWidth = 3.6
            disk.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            disk.lineWidth = lw
            disk.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
