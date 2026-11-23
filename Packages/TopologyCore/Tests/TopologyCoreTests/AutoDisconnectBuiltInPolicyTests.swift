import DisplayDomain
import XCTest
@testable import TopologyCore

final class AutoDisconnectBuiltInPolicyTests: XCTestCase {
    func testFiresOnFirstExternalArrivalWhenEnabled() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testDoesNotFireWhenDisabled() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertFalse(policy.onTopologyChange(enabled: false, externalPresent: true))
        // ...and after later enabling, a *steady* external (no new edge) still doesn't fire.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testSecondExternalDoesNotReTrigger() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))   // first arrives → fire
        // A second external: presence is still "some" → no new rising edge.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testDisconnectingBuiltInDoesNotReTrigger() {
        // After firing, turning the built-in off raises another topology change, but the external is
        // still present (presence stays true) so the policy must not fire again.
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testReArmsAfterAllExternalsLeave() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))    // arrive → fire
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))  // all leave
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))    // new arrival → fire again
    }

    func testSeedSuppressesPreexistingExternalAsArrival() {
        // Launch with an external already attached: seed so the first observed change isn't an "edge".
        var policy = AutoDisconnectBuiltInPolicy()
        policy.seed(externalPresent: true)
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
        // A genuine unplug+replug still fires.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testArrivalWhileDisabledIsTrackedSoLaterEnableDoesNotFireOnSteadyState() {
        var policy = AutoDisconnectBuiltInPolicy()
        // External arrives while the policy is off — tracked but not fired.
        XCTAssertFalse(policy.onTopologyChange(enabled: false, externalPresent: true))
        // Now enabled, but the external didn't *just* arrive → no fire.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
        // It leaves and comes back while enabled → fires.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testNoExternalNeverFires() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
    }

    /// On a wake the external's re-arrival edge can fire this policy before the wake re-assert gets
    /// its turn — an unaudited firing there reads as the re-assert acting silently. So a firing is
    /// audited like every other automatic display write.
    func testAFiringIsAudited() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = AutoDisconnectBuiltInPolicy.auditEntry(
            builtIn: DisplayRecordID(rawValue: "builtin"), committed: true, at: now)
        XCTAssertEqual(entry.actor, .system)
        XCTAssertEqual(entry.command, "autoDisconnect")
        XCTAssertEqual(entry.transactionId, "txn_autoDisconnect")
        XCTAssertEqual(entry.status, "committed")
        XCTAssertEqual(entry.targets, ["builtin"])
        XCTAssertEqual(entry.timestamp, now)
        XCTAssertEqual(AutoDisconnectBuiltInPolicy.auditEntry(
            builtIn: DisplayRecordID(rawValue: "builtin"), committed: false, at: now).status,
                       "failed")
    }

    func testParksAtTheBottomRightCornerOfTheRightmostExternal() {
        // Two externals side by side, as on the desk this was measured on.
        let sideBySide = [CGRect(x: 0, y: 0, width: 2304, height: 1296),
                          CGRect(x: 2304, y: 6, width: 2304, height: 1296)]
        XCTAssertEqual(AutoDisconnectBuiltInPolicy.parkedOrigin(externals: sideBySide), CGPoint(x: 4608, y: 1302))
        // Stacked with a shared right edge: anchor on the lower one, or the built-in would share an
        // edge with it and the pointer could cross.
        let stacked = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 100, width: 100, height: 100)]
        XCTAssertEqual(AutoDisconnectBuiltInPolicy.parkedOrigin(externals: stacked), CGPoint(x: 100, y: 200))
        XCTAssertNil(AutoDisconnectBuiltInPolicy.parkedOrigin(externals: []))
    }

    func testADarkPanelComesBackAtAUsableBrightness() {
        XCTAssertEqual(AutoDisconnectBuiltInPolicy.restoredBrightness(from: 0), 0.4)
        XCTAssertEqual(AutoDisconnectBuiltInPolicy.restoredBrightness(from: 0.75), 0.75)
    }
}
