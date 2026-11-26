import AppKit
import SwiftUI

/// Paleta del logo: azul medianoche, índigo eléctrico, violeta y lavanda. Cada color tiene variante clara y oscura.
enum Theme {
    // Medidos sobre el logo (Resources/logo).
    static let midnight = Color(hex: 0x181B49)
    static let royal = Color(hex: 0x1B4D99)
    static let indigo = Color(hex: 0x4D57DF)
    static let violet = Color(hex: 0x7C3AED)
    static let glow = Color(hex: 0x9F58F3)
    static let lavender = Color(hex: 0xC3B5FC)

    /// Acento para texto, iconos y controles: índigo en claro, lavanda-índigo en oscuro (contraste suficiente sobre medianoche).
    static let ink = Color.adaptive(light: 0x4D57DF, dark: 0xA5A8FF)
    /// Resalte de términos y párrafo citado.
    static let highlight = Color.adaptive(light: 0xEFE7FF, dark: 0x2A2463)
    static let highlightEdge = Color.adaptive(light: 0x9F58F3, dark: 0xB794FF)
    static let recording = Color(hex: 0xEF4444)
    static let successColor = Color(hex: 0x10B981)

    /// Fondos: lavanda casi blanca en claro, medianoche en oscuro.
    static let canvas = Color.adaptive(light: 0xFBFAFF, dark: 0x0F1130)
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x171A42)
    static let cardBorder = Color.adaptive(light: 0xE6E1FA, dark: 0x2C2F66)
    static let subtle = Color.adaptive(light: 0xF2EEFF, dark: 0x1D2050)

    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Degradado del fondo del logo, para la píldora y las cabeceras.
    static let night = LinearGradient(colors: [royal, midnight, Color(hex: 0x3A1D7A)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Color estable por persona en la transcripción.
    static func speakerColor(_ name: String) -> Color {
        let palette: [Color] = [indigo, violet, Color(hex: 0x0EA5E9), Color(hex: 0xDB2777), Color(hex: 0x059669), Color(hex: 0xD97706)]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Botón principal con el degradado del logo, que se eleva al pasar el ratón.
struct ProminentButtonStyle: ButtonStyle {
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.gradient)

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: AnyShapeStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(tint, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .shadow(color: Theme.violet.opacity(hover && enabled ? 0.45 : 0.2), radius: hover ? 10 : 4, y: hover ? 3 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.5)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Aviso en línea (procesando, error, información).
struct Banner<Trailing: View>: View {
    let icon: String
    let text: String
    var tint: Color = Theme.ink
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            // Sin fixedSize vertical: con él, el cálculo del tamaño mínimo lo maquetaba casi sin ancho
            // y su altura desbordaba la ventana entera, desplazando las tres columnas.
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
    }
}

extension Banner where Trailing == EmptyView {
    init(icon: String, text: String, tint: Color = Theme.ink) {
        self.init(icon: icon, text: text, tint: tint) { EmptyView() }
    }
}

/// Tarjeta con borde lavanda y sombra suave.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardBorder))
            .shadow(color: Theme.midnight.opacity(0.06), radius: 8, y: 2)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// El icono de la app (el logo), para la bienvenida y el onboarding.
struct AppLogo: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: Theme.violet.opacity(0.35), radius: size / 6, y: size / 16)
    }
}

/// Bandera del idioma de la clase, con esquinas suaves y un filo para que el blanco no se pierda en claro.
struct Flag: View {
    let language: ClassLanguage
    var height: CGFloat = 14

    var body: some View {
        Image(language.flag).resizable()
            .frame(width: height * 4 / 3, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height / 5))
            .overlay(RoundedRectangle(cornerRadius: height / 5).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel(language.name)
    }
}
