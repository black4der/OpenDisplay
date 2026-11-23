#if os(macOS) && !PUBLIC_API_ONLY
import AppKit
import CoreGraphics
import D65Calibration
import D65Core
import D65Display
import D65Host
import D65Link
import D65MacRuntime
import DisplayDomain
import Network
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

// White-point calibration with an iPhone probe, built on Tinnci/d65 (MIT): the iPhone's ambient-light
// sensor reads twelve full-screen patches, d65's engine solves per-channel gains, and OpenDisplay
// applies them through its own software-gamma composition (alongside dim and colour temperature), so
// a session never fights the app for the transfer table. The probe is d65's own D65Probe app.

// MARK: - Probe transport

// Adapted from d65's Sources/D65MacRuntime/NetworkTransport.swift (MIT, © Tinnci). d65 keeps its
// listener internal, and OpenDisplay needs its own display adapter in the same CalibrationService.

/// Lets a completion handler cross into Network.framework's @Sendable callbacks; it only ever runs
/// back on the main actor.
private struct MainActorCallback: @unchecked Sendable {
    let run: (() -> Void)?
}

/// TCP on the probe port, advertised as `_d65._tcp` over Bonjour, peer-to-peer allowed.
@MainActor final class ProbeNetworkListener: ProbeListener {
    private let listener: NWListener
    private var onReady: (() -> Void)?
    private var onFailure: ((String) -> Void)?
    private var onConnection: ((any ProbeConnection) -> Void)?

    init(port: UInt16 = 50515) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw CalibrationError.invalidConfiguration }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters, on: endpoint)
        listener.service = NWListener.Service(name: "OpenDisplay", type: Link.serviceType)
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void,
               onConnection: @escaping (any ProbeConnection) -> Void) {
        self.onReady = onReady
        self.onFailure = onFailure
        self.onConnection = onConnection
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.onConnection?(ProbeNetworkConnection(connection)) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.onReady?()
                case .failed(let error):
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        self?.onFailure?(String(localized: "The probe port is in use, possibly by d65 itself. Quit it and try again."))
                    } else {
                        self?.onFailure?(String(localized: "OpenDisplay can’t listen on the local network: \(String(describing: error))"))
                    }
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    func cancel() { listener.cancel() }
}

/// One probe's TCP connection.
@MainActor final class ProbeNetworkConnection: ProbeConnection {
    private let connection: NWConnection
    private var closed = false
    private var onData: ((Data) -> Void)?
    private var onClose: (() -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func start(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.onData = onData
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.onData?(data) }
                if complete || error != nil { self.close() } else { self.receive() }
            }
        }
    }

    func send(_ data: Data, completion: (() -> Void)?) {
        let callback = MainActorCallback(run: completion)
        connection.send(content: data, completion: .contentProcessed { _ in
            Task { @MainActor in callback.run?() }
        })
    }

    func cancel() { connection.cancel() }
}

// MARK: - Display adapter

/// d65's view of the display under calibration, routed through OpenDisplay's gamma composition.
/// Calibrate mode needs no DDC (d65 reads and writes controls only in its test modes), so those throw.
@MainActor final class OpenDisplayCalibrationTarget: CalibrationDisplay {
    let context: DisplayContext
    private let model: AppModel
    private let modeID: Int32?

    init(displayID: UInt32, model: AppModel) throws {
        guard let observation = model.displays.first(where: { $0.cgDisplayID == displayID }),
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let identity = CFUUIDCreateString(nil, uuid) as String? else {
            throw CalibrationError.displayChanged
        }
        let mode = CGDisplayCopyDisplayMode(displayID)
        modeID = mode?.ioDisplayModeID
        context = DisplayContext(identity: identity, name: model.displayName(for: observation),
                                 displayID: displayID, width: mode?.pixelWidth ?? 0,
                                 height: mode?.pixelHeight ?? 0, refreshRate: mode?.refreshRate ?? 0)
        self.model = model
    }

    func begin() throws {
        try validate()
        guard model.beginCalibrationSession(displayID: context.displayID) else { throw CalibrationError.displayChanged }
    }

    /// A mode switch mid-session would invalidate every patch measured so far.
    func validate() throws {
        guard CGDisplayIsOnline(context.displayID) != 0,
              CGDisplayCopyDisplayMode(context.displayID)?.ioDisplayModeID == modeID else {
            throw CalibrationError.displayChanged
        }
    }

    func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws {
        try validate()
        model.setCalibrationSessionGains(ColorTemperatureCurve.Gains(
            red: DisplayCalibration.encoded(linear: gains.r, gamma: gamma),
            green: DisplayCalibration.encoded(linear: gains.g, gamma: gamma),
            blue: DisplayCalibration.encoded(linear: gains.b, gamma: gamma)), displayID: context.displayID)
    }

    /// Back to the bare panel the engine started from; the session window previews or ends from here.
    func restore() throws {
        model.setCalibrationSessionGains(.neutral, displayID: context.displayID)
    }

    func readControl(_ code: UInt8) throws -> DDCValue { throw CalibrationError.controlUnavailable(code) }
    func writeControl(_ code: UInt8, value: UInt16) throws { throw CalibrationError.controlUnavailable(code) }
}

// MARK: - Session

/// One calibration session: Prepare → Connect → Place → Measure → Review, reduced from d65's
/// `SessionEvent`s. The display stays owned by the session (bare panel, auto-brightness paused)
/// until `close()`, so Review can preview the result before Keep or Discard.
@MainActor final class WhitePointSession: ObservableObject {
    enum Step: Int, CaseIterable { case prepare, connect, place, measure, review }

    @Published private(set) var step = Step.prepare
    @Published private(set) var probe: ProbeIdentity?
    @Published private(set) var notice: String?
    @Published private(set) var placement = PlacementReading(state: .waiting)
    @Published private(set) var patchIndex = 0
    @Published private(set) var verifyingPass: Int?
    @Published private(set) var record: ExperimentRecord?
    @Published private(set) var canKeep = false
    /// Hold to see the panel without the candidate correction.
    @Published var showOriginal = false { didSet { preview() } }

    let displayID: CGDirectDisplayID
    let displayName: String
    private let model: AppModel
    private var service: CalibrationService?
    private var autoStartArmed = true
    private var closed = false

    init(displayID: CGDirectDisplayID, displayName: String, model: AppModel) {
        self.displayID = displayID
        self.displayName = displayName
        self.model = model
    }

    var patchCount: Int { CalibrationPatch.sequence.count }

    func start() {
        notice = nil
        if service == nil {
            do {
                let listener = try ProbeNetworkListener()
                let platform = HostPlatform(
                    makeOverlay: HostPlatform.mac.makeOverlay,
                    makeDisplay: { [model] id in try OpenDisplayCalibrationTarget(displayID: id, model: model) })
                let service = CalibrationService(listener: listener, platform: platform,
                                                 recordDirectory: Self.recordDirectory(),
                                                 softwareRevision: "OpenDisplay \(AboutView.version)")
                service.onEvent = { [weak self] event in self?.handle(event) }
                service.start()
                self.service = service
            } catch {
                notice = String(localized: "OpenDisplay can’t listen on the local network: \(error.localizedDescription)")
                return
            }
        }
        if probe != nil { enterPlacement() } else { step = .connect }
    }

    func startNow() {
        guard step == .place, let service else { return }
        patchIndex = 0
        verifyingPass = nil
        record = nil
        canKeep = false
        step = .measure
        service.run(configuration: CalibrationConfiguration(mode: .calibrate), displayID: displayID)
    }

    func retry() {
        record = nil
        canKeep = false
        showOriginal = false
        model.setCalibrationSessionGains(.neutral, displayID: displayID)
        if probe != nil { enterPlacement() } else { step = .connect }
    }

    func keep() {
        if let record, let gains = record.bestGains {
            model.keepCalibration(DisplayCalibration(
                red: DisplayCalibration.encoded(linear: gains.r, gamma: record.gamma),
                green: DisplayCalibration.encoded(linear: gains.g, gamma: record.gamma),
                blue: DisplayCalibration.encoded(linear: gains.b, gamma: record.gamma),
                deltaEBefore: record.baselineDeltaE, deltaEAfter: record.bestDeltaE,
                calibratedAt: Date()), displayID: displayID)
        }
        close()
    }

    /// Cancels any run (the engine restores first), releases the probe, and hands the display back.
    func close() {
        guard !closed else { return }
        closed = true
        let service = self.service
        self.service = nil
        let model = self.model
        let displayID = self.displayID
        Task { @MainActor in
            await service?.stop()
            model.endCalibrationSession(displayID: displayID)
        }
    }

    private func enterPlacement() {
        autoStartArmed = true
        placement = PlacementReading(state: .waiting)
        step = .place
        service?.beginPlacement(displayID: displayID)
    }

    private func preview() {
        guard step == .review, canKeep, let record, let gains = record.bestGains else { return }
        let shown = showOriginal ? ColorTemperatureCurve.Gains.neutral : ColorTemperatureCurve.Gains(
            red: DisplayCalibration.encoded(linear: gains.r, gamma: record.gamma),
            green: DisplayCalibration.encoded(linear: gains.g, gamma: record.gamma),
            blue: DisplayCalibration.encoded(linear: gains.b, gamma: record.gamma))
        model.setCalibrationSessionGains(shown, displayID: displayID)
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .listening:
            break
        case .listenerFailed(let text), .probeRejected(let text):
            notice = text
        case .probeConnected(let identity):
            probe = identity
            notice = nil
            if step == .connect { enterPlacement() }
        case .probeDisconnected:
            probe = nil
            if step == .place { step = .connect }
        case .placement(let reading):
            placement = reading
            if reading.state == .settled, autoStartArmed, step == .place {
                autoStartArmed = false
                startNow()
            }
        case .startRequested:
            if step == .place { startNow() }
        case .cancelRequested:
            if step == .place { step = .prepare }
        case .progress(let progress):
            switch progress {
            case .patch(let index, _, _): patchIndex = index
            case .applying: patchIndex = patchCount
            case .verifying(let pass): verifyingPass = pass
            case .passMeasured: verifyingPass = nil
            case .restoring: break
            }
        case .finished(let record, _):
            self.record = record
            canKeep = SessionSummary(record: record).canKeep && record.bestGains != nil
            step = .review
            preview()
            NSApp.activate(ignoringOtherApps: true)
        case .runFailed(let text):
            notice = text
            step = probe == nil ? .connect : .prepare
        }
    }

    private static func recordDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("OpenDisplay/calibration-records", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Session window

struct WhitePointSessionView: View {
    @ObservedObject var session: WhitePointSession
    let onDone: () -> Void

    private static let stepTitles = ["Prepare", "Connect", "Place", "Measure", "Review"]

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.md) {
            Text("Calibrate white point · \(session.displayName)").font(.title3)
            HStack(spacing: 6) {
                ForEach(WhitePointSession.Step.allCases, id: \.self) { step in
                    Text(Self.stepTitles[step.rawValue].localized)
                        .font(.caption.weight(step == session.step ? .semibold : .regular))
                        .foregroundStyle(step == session.step ? Color.accentColor : .secondary)
                    if step != .review { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Divider()
            content.frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            if let notice = session.notice {
                Text(notice).font(.caption).foregroundStyle(ODColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            buttons
        }
        .padding(ODSpacing.lg)
        .frame(width: 460)
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .prepare:
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open D65 Probe on your iPhone and keep it on the same Wi-Fi as this Mac.")
                Text("2. Turn off True Tone and Night Shift for now, and keep the room light steady and not too bright.")
                Text("3. Leave the monitor at the brightness and contrast you normally use — changing contrast later makes a calibration stale.")
                Text("The display shows full-screen patches for about a minute. Press Esc on it to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .connect:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for D65 Probe on your iPhone…")
            }
        case .place:
            VStack(alignment: .leading, spacing: 8) {
                Text("Press the iPhone face-down inside the outline on the display and hold it still.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(placementText).foregroundStyle(.secondary)
                ProgressView(value: min(max(session.placement.steadyFraction, 0), 1))
                Text("Measuring starts on its own once the phone has been still for a moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .measure:
            VStack(alignment: .leading, spacing: 8) {
                if let pass = session.verifyingPass {
                    Text("Verifying the corrected white · pass \(pass)")
                } else {
                    Text("Measuring patch \(min(session.patchIndex + 1, session.patchCount)) of \(session.patchCount)")
                }
                ProgressView(value: Double(session.patchIndex), total: Double(session.patchCount))
                Text("Keep the iPhone still until it finishes.").font(.caption).foregroundStyle(.secondary)
            }
        case .review:
            review
        }
    }

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record = session.record {
                if session.canKeep {
                    Text("The correction is showing on the display now.").font(.headline)
                } else {
                    Text("No correction worth keeping — the display was left as it was.").font(.headline)
                }
                if let before = record.baselineDeltaE {
                    if let after = record.bestDeltaE {
                        Text("White error ΔE00: \(String(format: "%.2f", before)) → \(String(format: "%.2f", after))")
                    } else {
                        Text("White error ΔE00: \(String(format: "%.2f", before))")
                    }
                }
                if let gains = record.bestGains {
                    Text("Gains R \(String(format: "%.3f", gains.r)) · G \(String(format: "%.3f", gains.g)) · B \(String(format: "%.3f", gains.b))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if session.canKeep {
                    Toggle("Show the original", isOn: $session.showOriginal).toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var placementText: String {
        switch session.placement.state {
        case .waiting: return String(localized: "Waiting for the phone on the outline")
        case .tooDark: return String(localized: "Too dark — the sensor must sit inside the outline")
        case .moving: return String(localized: "Hold the phone still")
        case .settling: return String(localized: "Hold still…")
        case .settled: return String(localized: "Starting")
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if session.step == .review {
                Button("Discard") { session.close(); onDone() }
                Button("Try again") { session.retry() }
                Spacer()
                Button("Keep") { session.keep(); onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canKeep)
            } else {
                Button("Cancel") { session.close(); onDone() }
                Spacer()
                if session.step == .prepare {
                    Button("Start") { session.start() }.keyboardShortcut(.defaultAction)
                } else if session.step == .place {
                    Button("Start now") { session.startNow() }
                }
            }
        }
    }
}

// MARK: - Display card

/// The "White point" card on an external display's page: status, calibrate, remove.
struct WhitePointCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var session: WhitePointSession?

    var body: some View {
        ODCard(title: "White point",
               footnote: "Measured with the D65 Probe app on an iPhone placed on the screen. Corrects the white only, in software, while OpenDisplay runs.") {
            ODRow("Calibration", secondary: status) {
                HStack(spacing: 8) {
                    if model.calibration(for: display) != nil {
                        Button("Remove") { model.removeCalibration(for: display) }
                            .controlSize(.small)
                    }
                    Button("Calibrate…") {
                        guard let cgID = display.cgDisplayID else { return }
                        session = WhitePointSession(displayID: cgID, displayName: model.displayName(for: display),
                                                    model: model)
                    }
                    .controlSize(.small)
                    .disabled(session != nil)
                }
            }
        }
        .sheet(isPresented: Binding(get: { session != nil }, set: { if !$0 { session?.close(); session = nil } })) {
            if let session {
                WhitePointSessionView(session: session) { self.session = nil }
            }
        }
    }

    private var status: String {
        guard let calibration = model.calibration(for: display) else { return String(localized: "Not calibrated") }
        let date = calibration.calibratedAt.formatted(.dateTime.month(.abbreviated).day())
        if let before = calibration.deltaEBefore, let after = calibration.deltaEAfter {
            return String(localized: "Calibrated · ΔE \(String(format: "%.1f", before)) → \(String(format: "%.1f", after)) · \(date)")
        }
        return String(localized: "Calibrated · \(date)")
    }
}
#endif
