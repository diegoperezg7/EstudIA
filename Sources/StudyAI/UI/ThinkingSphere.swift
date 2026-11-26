import SwiftUI

/// Esfera de puntos que respira y gira sola («Thinking Sphere», DesignBookmark Motion).
/// Al pasar el ratón se inclina hacia el puntero; arrastrándola se gira y sigue con inercia.
/// Puntos en una esfera de Fibonacci con ruido senoidal; los cercanos más nítidos y grandes, los lejanos tenues.
/// A 30 fps como mucho, y quieta si la ventana no está delante o con «Reducir movimiento».
struct ThinkingSphere: View {
    var size: CGFloat = 160
    var dots = 420
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var motion = Motion()

    /// Estado del giro: se actualiza en cada fotograma y no hace falta que SwiftUI lo observe.
    final class Motion {
        var last: Double?
        var yaw = 0.0, yawV = 0.45, pitch = 0.32
        var hx = 0.0, hy = 0.0           // inclinación suavizada hacia el puntero (-0,5…0,5)
        var target: CGPoint?             // dónde está el puntero, si está encima
        var dragLast: CGPoint?, dragging = false

        func step(_ t: Double, reduce: Bool) {
            let dt = max(0, min(t - (last ?? t), 1 / 15))
            last = t
            if !dragging {
                yawV += ((reduce ? 0.06 : 0.45) - yawV) * (1 - exp(-dt * 1.4))
                pitch += (0.32 - pitch) * (1 - exp(-dt * 0.8))
            }
            yaw += yawV * dt
            let ease = 1 - exp(-dt * 7)
            hx += ((target?.x ?? 0) - hx) * ease
            hy += ((target?.y ?? 0) - hy) * ease
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || activeState == .inactive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvas in
                motion.step(t, reduce: reduceMotion)
                draw(ctx, canvas, t: reduceMotion ? 2 : t)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                motion.target = CGPoint(x: max(-0.5, min(0.5, p.x / size - 0.5)), y: max(-0.5, min(0.5, p.y / size - 0.5)))
            case .ended: motion.target = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                let prev = motion.dragLast ?? g.startLocation
                let dx = g.location.x - prev.x, dy = g.location.y - prev.y
                motion.dragging = true
                motion.yaw += dx * 0.011
                motion.yawV = dx * 0.011 * 30 // inercia aproximada a 30 fps
                motion.pitch = max(-0.6, min(1.1, motion.pitch + dy * 0.006))
                motion.dragLast = g.location
            }
            .onEnded { _ in motion.dragging = false; motion.dragLast = nil })
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ canvas: CGSize, t: Double) {
        let n = dots
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius = Double(min(canvas.width, canvas.height)) * 0.36
        let yaw = motion.yaw + motion.hx * 0.5, pitch = motion.pitch + motion.hy * 0.4
        let (cy, sy, cp, sp) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch))
        let breathe = 0.025 * sin(t * 1.7)
        let focal = radius * 5.5
        let dotScale = Double(size) / 160

        for i in 0..<n {
            let y0 = 1 - Double(i) / Double(n - 1) * 2
            let r0 = (1 - y0 * y0).squareRoot()
            let th = golden * Double(i)
            let (x0, z0) = (cos(th) * r0, sin(th) * r0)
            let noise = 0.1 * sin(x0 * 2.3 + t * 0.9) * sin(y0 * 2.9 - t * 0.7 + 1.3) * sin(z0 * 2.1 + t * 1.1 + 0.5)
                + 0.018 * sin(x0 * 5.1 - t * 1.3 + y0 * 3.7)
            let r = radius * (1 + noise + breathe)
            var x = (x0 * cy - z0 * sy) * r
            var z = (x0 * sy + z0 * cy) * r
            var y = y0 * r
            (y, z) = (y * cp - z * sp, y * sp + z * cp)
            let persp = focal / (focal - z)
            x *= persp; y *= persp
            let front = max(0, min(1, (z / radius + 1) / 2))
            let d = (0.9 + 1.4 * front) * persp * dotScale
            let alpha = 0.15 + 0.85 * front
            // Índigo detrás, violeta delante: la paleta del logo.
            let color = Color(red: 0.30 + 0.32 * front, green: 0.34 - 0.10 * front, blue: 0.87 + 0.08 * front).opacity(alpha)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x + x - d / 2, y: c.y + y - d / 2, width: d, height: d)), with: .color(color))
        }
    }
}
