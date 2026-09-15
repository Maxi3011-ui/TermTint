import AppKit

/// A window's colour identity: a hue inside its role's family.
struct Tint {
    let hue: CGFloat
    let role: Role

    var base: NSColor {
        NSColor(calibratedHue: hue, saturation: role.saturation, brightness: 0.98, alpha: 1)
    }

    /// The milky wash laid over the window.
    var wash: NSColor { base.withAlphaComponent(0.30) }

    /// Lighter wash for the title bar, which has to stay readable.
    var titleBarWash: NSColor { base.withAlphaComponent(0.38) }

    /// Hairline around the edge, a touch stronger than the wash.
    var edge: NSColor { base.withAlphaComponent(0.58) }

    /// Picked from the luminance of the composited overlay (dark HUD material
    /// underneath, wash on top) so every hue reads with the same contrast.
    var textColor: NSColor {
        let c = base.usingColorSpace(.sRGB) ?? .white
        let tintLuminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        let composite = 0.16 * 0.70 + tintLuminance * 0.30
        return composite > 0.62
            ? NSColor(white: 0.08, alpha: 0.92)
            : NSColor(white: 1.00, alpha: 0.97)
    }
}

/// Hands out hues inside a role's band, always as far as possible from the
/// hues that family is already using, so sibling windows stay distinguishable.
enum Palette {
    static func tint(for role: Role, avoiding used: [CGFloat]) -> Tint {
        let band = role.hues
        let span = band.upperBound - band.lowerBound
        let samples = 24
        let step = span / CGFloat(samples)

        var best = band.lowerBound + span / 2
        var bestDistance: CGFloat = -1

        for index in 0..<samples {
            let hue = band.lowerBound + step * (CGFloat(index) + 0.5)
            let distance = used.map { abs($0 - hue) }.min() ?? .greatestFiniteMagnitude
            if distance > bestDistance {
                bestDistance = distance
                best = hue
            }
        }

        // A little jitter so two identical situations don't produce identical
        // colours every single time.
        let jittered = (best + .random(in: -step / 3 ... step / 3))
            .clamped(to: band)
        return Tint(hue: jittered, role: role)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
