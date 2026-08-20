import SwiftUI

/// Palette e token di stile centralizzati. Cambiando qui i valori l'intera
/// app segue: colori, spacing, corner radius, ombre.
enum Theme {

    // MARK: - Colori base

    /// Sfondo principale: blu-nero profondo (leggermente più caldo del nero
    /// puro, meno "aggressivo" alla vista).
    static let background = Color(red: 0.043, green: 0.055, blue: 0.075)

    /// Superficie di primo livello — card, banner.
    static let surface = Color(red: 0.070, green: 0.086, blue: 0.114)

    /// Superficie sopra la surface: campi input, dropdown, hover.
    static let surfaceElevated = Color(red: 0.100, green: 0.121, blue: 0.157)

    /// Accento primario — un arancio caldo che stacca dal rosso di Netflix.
    static let accent = Color(red: 0.960, green: 0.647, blue: 0.141)

    /// Variante più tenue per background di badge e hover.
    static let accentSoft = Color(red: 0.960, green: 0.647, blue: 0.141).opacity(0.15)

    /// Rosso semantico per warning e destructive.
    static let danger = Color(red: 0.937, green: 0.325, blue: 0.314)

    /// Verde per stati "completato".
    static let success = Color(red: 0.325, green: 0.784, blue: 0.482)

    // MARK: - Testo

    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    // MARK: - Bordi e separatori

    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.18)

    // MARK: - Spacing (multipli di 4)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
    }

    // MARK: - Raggi

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 22
    }

    // MARK: - Gradient utili

    /// Gradient scuro dal basso: usato sotto ai titoli sopra le anteprime
    /// per garantire il contrasto senza appesantire l'immagine.
    static let posterOverlay = LinearGradient(
        colors: [
            .black.opacity(0.0),
            .black.opacity(0.35),
            .black.opacity(0.88),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Gradient laterale per l'hero banner: buio a sinistra, trasparente a
    /// destra, così titoli e testi rimangono leggibili sopra l'immagine.
    static let heroOverlay = LinearGradient(
        stops: [
            .init(color: .black.opacity(0.92), location: 0.0),
            .init(color: .black.opacity(0.6),  location: 0.35),
            .init(color: .black.opacity(0.15), location: 0.7),
            .init(color: .black.opacity(0.4),  location: 1.0),
        ],
        startPoint: .leading, endPoint: .trailing
    )
}

// MARK: - Stili di bottone

/// Azione principale: pillola piena in accent con testo scuro. L'arancio è
/// chiaro, quindi il nero dà molto più contrasto del bianco.
///
/// `ButtonStyle` non ammette `@State` diretto: hover e animazioni li teniamo
/// dentro una vista interna che avvolge la label.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        InteractiveLabel(configuration: configuration, compact: compact, primary: true)
    }
}

/// Azione secondaria: contorno chiaro su fondo scuro.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        InteractiveLabel(configuration: configuration, compact: compact, primary: false)
    }
}

private struct InteractiveLabel: View {
    let configuration: ButtonStyle.Configuration
    let compact: Bool
    let primary: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(compact ? .callout.bold() : .headline)
            .foregroundStyle(primary ? Color.black.opacity(0.88) : Theme.text)
            .padding(.horizontal, compact ? 16 : 22)
            .padding(.vertical, compact ? 8 : 12)
            .background(background)
            .overlay(border)
            .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.04 : 1.0))
            .shadow(
                color: primary ? Theme.accent.opacity(hovering ? 0.45 : 0) : .clear,
                radius: hovering ? 14 : 0,
                y: hovering ? 6 : 0
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    @ViewBuilder
    private var background: some View {
        if primary {
            Capsule().fill(Theme.accent.opacity(
                configuration.isPressed ? 0.75 : (hovering ? 1.0 : 0.95)
            ))
        } else {
            Capsule().fill(Color.white.opacity(
                configuration.isPressed ? 0.20 : (hovering ? 0.16 : 0.08)
            ))
        }
    }

    @ViewBuilder
    private var border: some View {
        if !primary {
            Capsule().strokeBorder(
                hovering ? Color.white.opacity(0.35) : Theme.borderStrong,
                lineWidth: 0.5
            )
        }
    }
}

// MARK: - Modificatori di comodo

extension View {
    /// Sfondo della finestra: blu-nero profondo, si estende sotto la titlebar.
    func themedBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Card: superficie con bordo sottile e raggio grande.
    func card(padding: CGFloat = Theme.Spacing.lg,
              radius: CGFloat = Theme.Radius.lg) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
    }

    /// Etichetta con badge caldo — usata per "Film", "Nuovo", ecc.
    func chip(color: Color = Theme.accent) -> some View {
        self
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }
}
