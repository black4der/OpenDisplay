import Foundation

/// The MacBook's own screen as a calibration reference: its white as one particular iPhone probe saw
/// it. An uncalibrated phone sensor reads every white with the same bias, so steering an external
/// toward the MacBook white *as that phone sees it* cancels the bias — a relative match to a
/// factory-calibrated panel, not a claim of absolute D65. Only meaningful with the same phone.
public struct CalibrationReference: Hashable, Sendable, Codable {
    /// CIE 1931 xy chromaticity of the built-in panel's white, ambient light subtracted.
    public var x: Double
    public var y: Double
    /// The probe that measured it (e.g. "iPhone18,3"); another phone needs its own reference.
    public var probeModel: String
    public var measuredAt: Date

    public init(x: Double, y: Double, probeModel: String, measuredAt: Date) {
        self.x = x
        self.y = y
        self.probeModel = probeModel
        self.measuredAt = measuredAt
    }
}

/// Bradford chromatic adaptation: the linear map that carries one white point onto another, applied
/// to every probe reading so a calibration engine that always aims at D65 aims at another white
/// instead. Linear, so it commutes with ambient subtraction and keeps the patch set consistent.
public enum ChromaticAdaptation {
    /// Row-major 3×3.
    public typealias Matrix = [[Double]]

    private static let bradford: Matrix = [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296],
    ]
    /// Inverted exactly rather than copied from a table, so adapting a white to itself is the identity.
    private static let bradfordInverse: Matrix = inverse(bradford)

    /// The adaptation taking a reading under `source` white to the equivalent under `target` white
    /// (both CIE xy). The source white itself lands exactly on the target white at the same luminance.
    public static func bradford(fromWhite source: (x: Double, y: Double),
                                toWhite target: (x: Double, y: Double)) -> Matrix {
        let sourceCone = multiply(bradford, xyz(source))
        let targetCone = multiply(bradford, xyz(target))
        let scale = (0..<3).map { targetCone[$0] / sourceCone[$0] }
        // M⁻¹ · diag(scale) · M
        let scaled = bradford.enumerated().map { row, values in values.map { $0 * scale[row] } }
        return (0..<3).map { row in
            (0..<3).map { column in (0..<3).reduce(0) { $0 + bradfordInverse[row][$1] * scaled[$1][column] } }
        }
    }

    public static func apply(_ matrix: Matrix, x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double) {
        let result = multiply(matrix, [x, y, z])
        return (result[0], result[1], result[2])
    }

    private static func xyz(_ white: (x: Double, y: Double)) -> [Double] {
        [white.x / white.y, 1, (1 - white.x - white.y) / white.y]
    }

    /// 3×3 inverse by cofactors (the Bradford matrix is well-conditioned).
    private static func inverse(_ m: Matrix) -> Matrix {
        let cofactors: Matrix = (0..<3).map { row in
            (0..<3).map { column in
                let r = [(row + 1) % 3, (row + 2) % 3], c = [(column + 1) % 3, (column + 2) % 3]
                return m[r[0]][c[0]] * m[r[1]][c[1]] - m[r[0]][c[1]] * m[r[1]][c[0]]
            }
        }
        let determinant = (0..<3).reduce(0) { $0 + m[0][$1] * cofactors[0][$1] }
        return (0..<3).map { row in (0..<3).map { column in cofactors[column][row] / determinant } }
    }

    private static func multiply(_ matrix: Matrix, _ vector: [Double]) -> [Double] {
        matrix.map { row in zip(row, vector).reduce(0) { $0 + $1.0 * $1.1 } }
    }
}
