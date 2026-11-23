import Foundation

/// An iPhone probe characterized on the MacBook's factory-calibrated screen: a 3×3 matrix from three
/// of the phone's raw light-sensor channels to CIE XYZ.
///
/// The phone firmware's own XYZ is neither accurate nor linear — it reads a D65 MacBook near 9,500 K,
/// and a yellow patch's Z comes out 30 % above red's plus green's. The raw channels do add up
/// linearly, so a matrix fitted to patches of known colour corrects them: the colorimeter-correction
/// method, with the MacBook standing in for the reference instrument. It is fitted on the MacBook's
/// spectra; on a panel with very different primaries it is closer, not exact.
public struct ProbeCharacterization: Hashable, Sendable, Codable {
    /// Row-major: XYZ = matrix · (raw[channels[0]], raw[channels[1]], raw[channels[2]]).
    public var matrix: [[Double]]
    /// The three raw channels used: the least collinear trio on the MacBook. A near-collinear trio
    /// fits the MacBook just as well but blows small spectral differences up on any other panel
    /// (iPhone 17: channels 0–2 read a monitor near 6,700 K as 3,500 K; 0, 2, 3 don't).
    public var channels: [Int]
    /// The probe it belongs to (e.g. "iPhone18,3"); another phone needs its own.
    public var probeModel: String
    public var measuredAt: Date
    /// |Δx| + |Δy| when a fit that left the white patch out predicts it — the honesty check.
    public var whiteCheckError: Double

    public init(matrix: [[Double]], channels: [Int] = [0, 1, 2], probeModel: String, measuredAt: Date,
                whiteCheckError: Double) {
        self.matrix = matrix
        self.channels = channels
        self.probeModel = probeModel
        self.measuredAt = measuredAt
        self.whiteCheckError = whiteCheckError
    }

    public func xyz(raw: [Double]) -> (x: Double, y: Double, z: Double)? {
        guard channels.count == 3, let last = channels.max(), raw.count > last, channels.min() ?? -1 >= 0,
              matrix.count == 3, matrix.allSatisfy({ $0.count == 3 }) else { return nil }
        let v = Self.multiply(matrix, channels.map { raw[$0] })
        return (v[0], v[1], v[2])
    }

    /// A patch as the overlay drew it (explicit sRGB, 0…1) and the probe's raw channels for it with
    /// the black patch subtracted.
    public struct Patch: Sendable {
        public var red, green, blue: Double
        public var raw: [Double]
        public init(red: Double, green: Double, blue: Double, raw: [Double]) {
            self.red = red; self.green = green; self.blue = blue; self.raw = raw
        }
        var isWhite: Bool { red == 1 && green == 1 && blue == 1 }
    }

    /// Fits the matrix from patches shown on a D65 sRGB-managed screen. `whiteY` scales the result so
    /// the corrected white's Y matches the probe's own units (d65's luminance floors expect those).
    /// Nil without a white patch and at least three others, or when the patches don't span colour.
    public static func characterize(_ patches: [Patch], whiteY: Double, probeModel: String,
                                    at date: Date) -> ProbeCharacterization? {
        let width = min(4, patches.map(\.raw.count).min() ?? 0)
        guard width >= 3 else { return nil }
        let trios = width == 4 ? [[0, 1, 2], [0, 1, 3], [0, 2, 3], [1, 2, 3]] : [[0, 1, 2]]
        guard let channels = trios.max(by: { independence(patches, $0) < independence(patches, $1) }) else { return nil }
        let usable = patches.map { patch in
            Patch(red: patch.red, green: patch.green, blue: patch.blue, raw: channels.map { patch.raw[$0] })
        }
        guard let white = usable.first(where: \.isWhite), usable.filter({ !$0.isWhite }).count >= 3,
              whiteY > 0, let matrix = fit(usable, scale: whiteY),
              let heldOut = fit(usable.filter { !$0.isWhite }, scale: whiteY) else { return nil }
        let predicted = multiply(heldOut, white.raw)
        let sum = predicted.reduce(0, +)
        guard sum > 0 else { return nil }
        let truth = multiply(sRGBToXYZ, [1, 1, 1]), truthSum = truth.reduce(0, +)
        let error = abs(predicted[0] / sum - truth[0] / truthSum) + abs(predicted[1] / sum - truth[1] / truthSum)
        return ProbeCharacterization(matrix: matrix, channels: channels, probeModel: probeModel, measuredAt: date,
                                     whiteCheckError: error)
    }

    /// How far from collinear these channels are across the patches: the determinant of their Gram
    /// matrix with each channel scaled to unit length — 1 for orthogonal, 0 for collinear.
    private static func independence(_ patches: [Patch], _ channels: [Int]) -> Double {
        let columns = channels.map { c in patches.map { $0.raw[c] } }
        let norms = columns.map { sqrt($0.reduce(0) { $0 + $1 * $1 }) }
        guard norms.allSatisfy({ $0 > 0 }) else { return 0 }
        let gram = (0..<3).map { i in
            (0..<3).map { j in zip(columns[i], columns[j]).reduce(0) { $0 + $1.0 * $1.1 } / (norms[i] * norms[j]) }
        }
        return determinant(gram)
    }

    /// Least squares: the 3×3 M minimising Σ‖M·raw − truth‖², via the normal equations.
    private static func fit(_ patches: [Patch], scale: Double) -> [[Double]]? {
        let raw = patches.map(\.raw)
        let truth = patches.map { patch in multiply(sRGBToXYZ, [patch.red, patch.green, patch.blue].map(linear)).map { $0 * scale } }
        let gram = (0..<3).map { i in (0..<3).map { j in raw.reduce(0) { $0 + $1[i] * $1[j] } } }
        guard let inverseGram = inverse(gram) else { return nil }
        // Row r of M solves gram · m_r = Σ raw · truth_r.
        return (0..<3).map { r in
            let rhs = (0..<3).map { i in zip(raw, truth).reduce(0) { $0 + $1.0[i] * $1.1[r] } }
            return multiply(inverseGram, rhs)
        }
    }

    /// sRGB (IEC 61966-2-1) primaries, D65 white at Y = 1.
    private static let sRGBToXYZ: [[Double]] = [
        [0.4124, 0.3576, 0.1805],
        [0.2126, 0.7152, 0.0722],
        [0.0193, 0.1192, 0.9505],
    ]

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// 3×3 inverse by cofactors; nil when singular.
    private static func inverse(_ m: [[Double]]) -> [[Double]]? {
        let cofactors: [[Double]] = (0..<3).map { row in
            (0..<3).map { column in
                let r = [(row + 1) % 3, (row + 2) % 3], c = [(column + 1) % 3, (column + 2) % 3]
                return m[r[0]][c[0]] * m[r[1]][c[1]] - m[r[0]][c[1]] * m[r[1]][c[0]]
            }
        }
        let det = (0..<3).reduce(0) { $0 + m[0][$1] * cofactors[0][$1] }
        guard abs(det) > 1e-12 * pow(m.flatMap { $0 }.map(abs).max() ?? 1, 3) else { return nil }
        return (0..<3).map { row in (0..<3).map { column in cofactors[column][row] / det } }
    }

    private static func determinant(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    private static func multiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        matrix.map { row in zip(row, vector).reduce(0) { $0 + $1.0 * $1.1 } }
    }
}
