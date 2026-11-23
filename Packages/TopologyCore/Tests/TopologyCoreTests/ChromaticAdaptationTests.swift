import XCTest
@testable import TopologyCore

final class ChromaticAdaptationTests: XCTestCase {
    private let d65 = (x: 0.3127, y: 0.3290)
    private let greenishWhite = (x: 0.3050, y: 0.3400)  // a white an uncalibrated sensor might report

    private func chromaticity(_ v: (x: Double, y: Double, z: Double)) -> (x: Double, y: Double) {
        let sum = v.x + v.y + v.z
        return (v.x / sum, v.y / sum)
    }

    func testCarriesTheSourceWhiteOntoTheTargetWhiteAtTheSameLuminance() {
        let matrix = ChromaticAdaptation.bradford(fromWhite: greenishWhite, toWhite: d65)
        let source = (x: greenishWhite.x / greenishWhite.y, y: 1.0,
                      z: (1 - greenishWhite.x - greenishWhite.y) / greenishWhite.y)
        let adapted = ChromaticAdaptation.apply(matrix, x: source.x * 120, y: source.y * 120, z: source.z * 120)
        let xy = chromaticity(adapted)
        XCTAssertEqual(xy.x, d65.x, accuracy: 1e-9)
        XCTAssertEqual(xy.y, d65.y, accuracy: 1e-9)
        XCTAssertEqual(adapted.y, 120, accuracy: 1e-9)
    }

    func testSameWhiteIsIdentity() {
        let matrix = ChromaticAdaptation.bradford(fromWhite: d65, toWhite: d65)
        let v = ChromaticAdaptation.apply(matrix, x: 41.2, y: 21.3, z: 1.9)  // a red patch
        XCTAssertEqual(v.x, 41.2, accuracy: 1e-6)
        XCTAssertEqual(v.y, 21.3, accuracy: 1e-6)
        XCTAssertEqual(v.z, 1.9, accuracy: 1e-6)
    }

    func testReferenceRoundTripsThroughSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let reference = CalibrationReference(x: 0.3127, y: 0.3290, probeModel: "iPhone18,3",
                                             measuredAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(OpenDisplaySettings(calibrationReference: reference))
        XCTAssertEqual(store.load().calibrationReference, reference)
    }
}
