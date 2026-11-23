import XCTest
@testable import TopologyCore

final class ProbeCharacterizationTests: XCTestCase {
    /// A made-up linear sensor whose channels mix X, Y and Z — the shape of the phone's raw channels.
    private let sensor: [[Double]] = [[2.0, 9.0, 18.0], [3.0, 14.0, 2.5], [21.0, 24.0, 1.0]]
    private let srgb: [(Double, Double, Double)] = [
        (1, 1, 1), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1),
        (0.2, 0.2, 0.2), (0.4, 0.4, 0.4), (0.6, 0.6, 0.6), (0.8, 0.8, 0.8),
    ]

    private func xyz(_ c: (Double, Double, Double)) -> [Double] {
        let lin = [c.0, c.1, c.2].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let m = [[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]
        return m.map { row in zip(row, lin).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    private func raw(_ v: [Double]) -> [Double] { sensor.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } } }

    func testRecoversTheTrueColourOfALinearSensor() throws {
        let patches = srgb.map { c in
            ProbeCharacterization.Patch(red: c.0, green: c.1, blue: c.2, raw: raw(xyz(c).map { $0 * 300 }))
        }
        let fitted = try XCTUnwrap(ProbeCharacterization.characterize(patches, whiteY: 300, probeModel: "iPhone18,3", at: Date()))
        XCTAssertLessThan(fitted.whiteCheckError, 1e-9)
        // A colour that wasn't in the fit comes back at its true XYZ, in the probe's units.
        let orange = xyz((1, 0.5, 0.1)).map { $0 * 300 }
        let v = try XCTUnwrap(fitted.xyz(raw: raw(orange)))
        XCTAssertEqual(v.x, orange[0], accuracy: 1e-6)
        XCTAssertEqual(v.y, orange[1], accuracy: 1e-6)
        XCTAssertEqual(v.z, orange[2], accuracy: 1e-6)
    }

    func testNeedsWhiteAndRawChannels() {
        let noWhite = srgb.dropFirst().map { c in ProbeCharacterization.Patch(red: c.0, green: c.1, blue: c.2, raw: raw(xyz(c))) }
        XCTAssertNil(ProbeCharacterization.characterize(Array(noWhite), whiteY: 1, probeModel: "x", at: Date()))
        // An old probe sends no raw channels.
        let noRaw = srgb.map { c in ProbeCharacterization.Patch(red: c.0, green: c.1, blue: c.2, raw: []) }
        XCTAssertNil(ProbeCharacterization.characterize(noRaw, whiteY: 1, probeModel: "x", at: Date()))
    }

    func testPersistsInSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let characterization = ProbeCharacterization(matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], probeModel: "iPhone18,3",
                                                     measuredAt: Date(timeIntervalSince1970: 1_800_000_000), whiteCheckError: 0.002)
        try store.save(OpenDisplaySettings(probeCharacterization: characterization))
        XCTAssertEqual(store.load().probeCharacterization, characterization)
    }
}
