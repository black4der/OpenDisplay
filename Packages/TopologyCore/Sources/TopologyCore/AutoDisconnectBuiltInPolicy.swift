import DisplayDomain
import Foundation

/// Edge-triggered policy for "ignore the built-in panel when an external connects" (Issue 5).
///
/// It fires only on the **rising edge** of external presence (none → some): the moment the first
/// external arrives is when the built-in should step aside. Plugging in a *second* external (some →
/// more) leaves presence "some", so no new edge fires and the built-in isn't disturbed again.
///
/// "Ignore" deliberately does NOT disconnect the panel: it stays active, so macOS's own True Tone
/// keeps reaching the externals, but its backlight goes to 0 and it is parked where the pointer can't
/// reach (`parkedOrigin`). Pure decision logic — the dimming, parking and restoring are the host's job.
public struct AutoDisconnectBuiltInPolicy {
    private var externalPresent: Bool

    public init(externalPresent: Bool = false) {
        self.externalPresent = externalPresent
    }

    /// Re-seed the tracked presence *without* firing — e.g. to the launch topology — so the next
    /// change is compared against the true prior state and an already-connected external isn't
    /// mistaken for a fresh arrival.
    public mutating func seed(externalPresent: Bool) {
        self.externalPresent = externalPresent
    }

    /// Feed the latest `(enabled, externalPresent)` on every topology change. Returns true exactly when
    /// an external just arrived (none → some) while the policy is enabled — the moment to turn the
    /// built-in off. Always updates the tracked presence (even when disabled) so edges stay accurate.
    public mutating func onTopologyChange(enabled: Bool, externalPresent: Bool) -> Bool {
        let arrived = !self.externalPresent && externalPresent
        self.externalPresent = externalPresent
        return enabled && arrived
    }

    /// Where to park the built-in so the pointer can't reach it: touching the externals at a single
    /// corner only — the bottom-right one of the right-most (then lowest) external. Displays that meet
    /// at one point share no edge, so the cursor can't cross, and Core Graphics keeps the layout as
    /// given (measured on macOS 26) instead of snapping it to an edge. Global Core Graphics
    /// coordinates, y growing downward. Nil when there are no externals.
    public static func parkedOrigin(externals: [CGRect]) -> CGPoint? {
        // origin + size rather than maxX/maxY: those come from CoreGraphics, absent on Linux.
        func corner(_ rect: CGRect) -> (CGFloat, CGFloat) {
            (rect.origin.x + rect.size.width, rect.origin.y + rect.size.height)
        }
        guard let anchor = externals.max(by: { corner($0) < corner($1) }) else { return nil }
        let point = corner(anchor)
        return CGPoint(x: point.0, y: point.1)
    }

    /// The brightness to give the built-in back. A panel that was already dark (a desk setup often
    /// keeps it at 0) comes back at a usable floor, so an undocked laptop is never left black.
    public static func restoredBrightness(from prior: Float) -> Float {
        max(prior, 0.4)
    }

    /// Command recorded when the policy fires. On a wake the external's re-arrival edge can fire
    /// this before the wake re-assert gets its turn, so an unaudited firing reads as the re-assert
    /// acting silently — the exact confusion the entry exists to prevent.
    public static let auditCommand = "autoDisconnect"

    /// The audit entry for one firing. `system` actor, like Protected Layout's restores: the app
    /// acted on its own, on the user's standing instruction.
    public static func auditEntry(builtIn: DisplayRecordID, committed: Bool,
                                  at now: Date) -> AuditEntry {
        AuditEntry(timestamp: now, actor: .system, command: auditCommand,
                   transactionId: "txn_\(auditCommand)",
                   status: committed ? "committed" : "failed",
                   targets: [builtIn.rawValue])
    }
}

/// Restore ledger for an ignored built-in: what it looked like before it was dimmed and parked.
public struct IgnoredBuiltInState: Hashable, Sendable, Codable {
    public var brightness: Float
    public var originX: Int
    public var originY: Int

    public init(brightness: Float, originX: Int, originY: Int) {
        self.brightness = brightness
        self.originX = originX
        self.originY = originY
    }
}
