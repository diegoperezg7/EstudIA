// Fondo del .dmg: la imagen de Resources/dmg con una pastilla violeta bajo el nombre de cada icono.
// Finder pinta las etiquetas en negro (modo claro) o blanco (oscuro) y no deja elegir: #7468C0 da
// 4,5:1 con negro y 4,7:1 con blanco, así que se leen en los dos.
// Uso: swift scripts/dmg-background.swift <entrada.png> <salida@2x.png>   (posiciones en puntos, ver make-dmg.sh)
import AppKit

let args = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let w = src.pixelsWide, h = src.pixelsHigh
let scale = CGFloat(w) / 887 // la ventana mide 887 pt de ancho
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
// Centro de cada icono (pt, desde arriba) y ancho de su etiqueta.
for (cx, cy, width) in [(270.0, 205.0, 92.0), (610.0, 205.0, 118.0)] {
    let labelY = cy + 56 + 18 // bajo un icono de 112 pt, con la etiqueta de 13 pt
    let r = NSRect(x: (cx - width / 2) * scale, y: CGFloat(h) - (labelY + 12) * scale, width: width * scale, height: 24 * scale)
    let path = NSBezierPath(roundedRect: r, xRadius: 12 * scale, yRadius: 12 * scale)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = NSColor(red: 0.62, green: 0.35, blue: 0.95, alpha: 0.6); glow.shadowBlurRadius = 10 * scale
    glow.set()
    NSColor(red: 0x74 / 255.0, green: 0x68 / 255.0, blue: 0xC0 / 255.0, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
