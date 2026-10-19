import SwiftUI

enum Theme {
    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    // Tema oscuro: fondo casi negro, tarjetas con borde fino y colores vivos.
    static let background = hex(0x0A0C10)
    static let cardFill = hex(0x14181F)
    static let cardStroke = Color.white.opacity(0.07)
    static let cardRadius: CGFloat = 16

    static let steps = hex(0x00FF94)
    static let sleep = hex(0x7B5CFF)
    static let heart = hex(0xFF1F5A)
    /// FC en reposo: la misma línea en la gráfica del día y en las de periodo.
    static let resting = Color.blue.opacity(0.75)
    static let calories = hex(0xFF9500)

    static let deep = Color(red: 0.29, green: 0.18, blue: 0.88)
    static let light = Color(red: 0.18, green: 0.42, blue: 1.0)
    static let rem = Color(red: 0.16, green: 0.78, blue: 1.0)
    static let awake = Color(red: 1.0, green: 0.45, blue: 0.30)

    static func stageColor(_ s: String) -> Color {
        switch s {
        case "DEEP": return deep
        case "LIGHT": return light
        case "REM": return rem
        default: return awake
        }
    }

    static func stageName(_ s: String) -> String {
        switch s {
        case "DEEP": return "Profundo"
        case "LIGHT": return "Ligero"
        case "REM": return "REM"
        default: return "Despierto"
        }
    }

    /// De arriba abajo, como en el hipnograma.
    static let stageOrder = ["AWAKE", "REM", "LIGHT", "DEEP"]
}

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1) }
    }

    /// Tarjeta de media anchura: dos por fila, con la misma altura dentro de la fila.
    func miniCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1) }
    }
}
