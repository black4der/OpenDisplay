import Foundation

/// Converts a colour temperature in kelvin into per-channel gamma gains, for the software
/// warm/cool control. Built on the Tanner Helland blackbody approximation, expressed *relative to
/// the neutral point* so `neutralKelvin` is exactly (1, 1, 1) — the display's calibration is
/// untouched at neutral — and every other temperature only ever attenuates channels (gains ≤ 1,
/// dominant channel pinned to 1) so highlights never clip.
public enum ColorTemperatureCurve {
    /// Identity — the display's own calibration.
    public static let neutralKelvin: Float = 6500
    /// Candle-light warm; matches the bottom of typical night-mode ranges.
    public static let minKelvin: Float = 2700
    /// Strongly blue; the cool end of common display presets.
    public static let maxKelvin: Float = 9300

    public struct Gains: Equatable, Sendable {
        public let red: Float
        public let green: Float
        public let blue: Float

        public init(red: Float, green: Float, blue: Float) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let neutral = Gains(red: 1, green: 1, blue: 1)
    }

    /// Gains for `kelvin` (clamped to `minKelvin...maxKelvin`).
    public static func gains(kelvin: Float) -> Gains {
        let kelvin = min(max(kelvin, minKelvin), maxKelvin)
        if kelvin == neutralKelvin { return .neutral }
        let target = blackbody(kelvin: Double(kelvin))
        let neutral = blackbody(kelvin: Double(neutralKelvin))
        // Relative correction from neutral, renormalised so the dominant channel stays at 1.
        var r = target.r / neutral.r
        var g = target.g / neutral.g
        var b = target.b / neutral.b
        let peak = max(r, g, b)
        r /= peak
        g /= peak
        b /= peak
        return Gains(red: Float(r), green: Float(g), blue: Float(b))
    }

    /// Tanner Helland's kelvin → RGB fit (0...255 per channel), the standard screen-warmth curve.
    private static func blackbody(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let t = kelvin / 100
        let r: Double
        let g: Double
        let b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
        }
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(t - 10) - 305.0447927307
        }
        return (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }
}

/// True Tone for external displays: how far a display's white point leans toward the room's light.
/// macOS's own True Tone offers no reading of the white point it applies, so this works from the
/// same ambient colour sensor. The display moves `strength` of the way from neutral toward the
/// room's colour temperature, within `range`: a warm lamp warms the screen, daylight leaves it
/// neutral, and it never swings to the extremes the manual slider allows. Deliberately subtle, like
/// Apple's own: leaning 60% of the way turned a monitor visibly yellow under ordinary warm LEDs.
public enum TrueTonePolicy {
    public static let strength: Float = 0.3
    public static let range: ClosedRange<Float> = 5200...7000
    /// Smallest change worth a gamma write. Matches the colour-temperature setter's snap-to-native
    /// band, so a target just off neutral doesn't rewrite every tick.
    public static let hysteresisKelvin: Float = 100

    public static func displayKelvin(forAmbient ambient: Double) -> Float {
        let neutral = ColorTemperatureCurve.neutralKelvin
        let target = neutral + strength * (Float(ambient) - neutral)
        return min(max(target, range.lowerBound), range.upperBound)
    }
}
