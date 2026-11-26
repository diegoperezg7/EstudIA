// Genera Resources/AppIcon.icns a partir del logo (Resources/logo/*.png), en la retícula de iconos de macOS:
// lienzo de 1024 con el cuerpo en 824 y esquinas redondeadas, sin el fondo blanco del original.
// Uso: swift scripts/make-icon.swift
import AppKit

let logoDir = URL(fileURLWithPath: "Resources/logo")
let logoURL = try! FileManager.default.contentsOfDirectory(at: logoDir, includingPropertiesForKeys: nil)
    .first { $0.pathExtension.lowercased() == "png" }!
let logo = NSBitmapImageRep(data: try! Data(contentsOf: logoURL))!

// Cuerpo del icono dentro del PNG original (medido: x 99…1145, y 102…1148), con un margen para no arrastrar el halo blanco.
let inset = 14.0
let body = CGRect(x: 99 + inset, y: 102 + inset, width: 1046 - 2 * inset, height: 1046 - 2 * inset)
let cropped = logo.cgImage!.cropping(to: body)!

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).addClip()
    NSImage(cgImage: cropped, size: body.size).draw(in: rect)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK Resources/AppIcon.icns" : "iconutil falló")
