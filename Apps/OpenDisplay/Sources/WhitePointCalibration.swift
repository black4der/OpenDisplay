#if os(macOS) && !PUBLIC_API_ONLY
import AppKit
import CoreGraphics
import D65Calibration
import D65Core
import D65Display
import D65Host
import D65Link
import D65MacRuntime
import D65Measurement
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
    private var listener: NWListener
    private let port: NWEndpoint.Port
    private var retries = 0
    private var cancelled = false
    private var onReady: (() -> Void)?
    private var onFailure: ((String) -> Void)?
    private var onConnection: ((any ProbeConnection) -> Void)?
    /// Applied to every reading before d65 sees it (see `ProbeNetworkConnection.sampleTransform`).
    var sampleTransform: ((MeasurementSample) -> MeasurementSample)?

    init(port: UInt16 = 50515) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw CalibrationError.invalidConfiguration }
        self.port = endpoint
        listener = try Self.makeListener(on: endpoint)
    }

    private static func makeListener(on port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(name: "OpenDisplay", type: Link.serviceType)
        return listener
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void,
               onConnection: @escaping (any ProbeConnection) -> Void) {
        self.onReady = onReady
        self.onFailure = onFailure
        self.onConnection = onConnection
        listen()
    }

    private func listen() {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                let probe = ProbeNetworkConnection(connection)
                probe.sampleTransform = self.sampleTransform
                self.onConnection?(probe)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.onReady?()
                case .failed(let error):
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        // The session closed a moment ago releases the port asynchronously; wait it out (~3 s).
                        if self.retries < 10, !self.cancelled, let next = try? Self.makeListener(on: self.port) {
                            self.retries += 1
                            self.listener.cancel()
                            self.listener = next
                            try? await Task.sleep(for: .milliseconds(300))
                            if !self.cancelled { self.listen() }
                            return
                        }
                        self.onFailure?(String(localized: "The probe port is in use, possibly by d65 itself. Quit it and try again."))
                    } else {
                        self.onFailure?(String(localized: "OpenDisplay can’t listen on the local network: \(String(describing: error))"))
                    }
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    func cancel() { cancelled = true; listener.cancel() }
}

/// One probe's TCP connection.
@MainActor final class ProbeNetworkConnection: ProbeConnection {
    private let connection: NWConnection
    private var closed = false
    private var onData: ((Data) -> Void)?
    private var onClose: (() -> Void)?
    /// When set, each probe reading is rewritten before CalibrationService sees it — how a session
    /// swaps the phone firmware's XYZ for its MacBook-corrected raw channels.
    var sampleTransform: ((MeasurementSample) -> MeasurementSample)?
    private var inbound = Data()

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
                if let data, !data.isEmpty { self.deliver(data) }
                if complete || error != nil { self.close() } else { self.receive() }
            }
        }
    }

    /// Passes bytes on, rewriting sample readings when a transform is set. Partial frames wait in
    /// `inbound` for the rest; anything undecodable goes through untouched for the service to reject.
    private func deliver(_ data: Data) {
        guard let transform = sampleTransform else { onData?(data); return }
        inbound.append(data)
        guard let messages = try? MessageFraming.drain(&inbound) else {
            let raw = inbound
            inbound.removeAll()
            onData?(raw)
            return
        }
        var out = Data()
        for message in messages {
            let rewritten: CalibrationMessage
            switch message {
            case .taggedSample(let session, let patch, let sample):
                rewritten = .taggedSample(sessionID: session, patchID: patch, sample: transform(sample))
            case .previewSample(let session, let sample, let stable):
                rewritten = .previewSample(sessionID: session, sample: transform(sample), stable: stable)
            default:
                rewritten = message
            }
            if let encoded = try? MessageFraming.encode(rewritten) { out.append(encoded) }
        }
        if !out.isEmpty { onData?(out) }
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

/// One session, reduced from d65's `SessionEvent`s: Prepare → Connect → Place → Measure → Review.
/// It either calibrates an external display, or characterizes the iPhone on the MacBook's built-in
/// screen — patches of known colour — so later calibrations can correct its readings. The display stays owned by the session (bare panel,
/// auto-brightness paused) until `close()`, so Review can preview the result before Keep or Discard.
@MainActor final class WhitePointSession: ObservableObject {
    enum Step: Int, CaseIterable { case prepare, connect, place, measure, review }
    enum Purpose { case calibrate, measureReference }

    @Published private(set) var step = Step.prepare
    @Published private(set) var probe: ProbeIdentity?
    @Published private(set) var notice: String?
    @Published private(set) var placement = PlacementReading(state: .waiting)
    @Published private(set) var patchIndex = 0
    @Published private(set) var verifyingPass: Int?
    @Published private(set) var record: ExperimentRecord?
    @Published private(set) var canKeep = false
    /// The correction this session fitted (measureReference only).
    @Published private(set) var fitted: ProbeCharacterization?
    /// The phone firmware's own reading of the MacBook white, shown beside the correction.
    @Published private(set) var firmwareWhite: Chromaticity?
    /// Correct readings with the saved characterization (calibrate only; needs one).
    @Published var correctProbe: Bool
    /// A reading arrived without raw channels while correcting: the probe isn't the updated one.
    @Published private(set) var rawChannelsMissing = false
    /// Hold to see the panel without the candidate correction.
    @Published var showOriginal = false { didSet { preview() } }

    let purpose: Purpose
    let displayID: CGDirectDisplayID
    let displayName: String
    private let model: AppModel
    private var service: CalibrationService?
    private var correction: ProbeCharacterization?
    private var autoStartArmed = true
    private var closed = false

    init(purpose: Purpose, displayID: CGDirectDisplayID, displayName: String, model: AppModel) {
        self.purpose = purpose
        self.displayID = displayID
        self.displayName = displayName
        self.model = model
        correctProbe = purpose == .calibrate && model.probeCharacterization != nil
    }

    var patchCount: Int { CalibrationPatch.sequence.count }
    var characterization: ProbeCharacterization? { model.probeCharacterization }

    func start() {
        notice = nil
        if service == nil {
            do {
                let listener = try ProbeNetworkListener()
                correction = purpose == .calibrate && correctProbe ? characterization : nil
                listener.sampleTransform = { [weak self] sample in self?.adapt(sample) ?? sample }
                let platform = HostPlatform(
                    makeOverlay: { id in
                        NSScreen.screens.first {
                            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
                        }.map { PhonePatchOverlay(screen: $0, displayID: id) }
                    },
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
        if purpose == .measureReference { model.liftBuiltInForReference(displayID: displayID) }
        if probe != nil { enterPlacement() } else { step = .connect }
    }

    func startNow() {
        guard step == .place, let service else { return }
        patchIndex = 0
        verifyingPass = nil
        record = nil
        canKeep = false
        fitted = nil
        firmwareWhite = nil
        rawChannelsMissing = false
        step = .measure
        let mode: CalibrationMode = purpose == .measureReference ? .measureOnly : .calibrate
        service.run(configuration: CalibrationConfiguration(mode: mode), displayID: displayID)
    }

    func retry() {
        record = nil
        canKeep = false
        fitted = nil
        firmwareWhite = nil
        showOriginal = false
        model.setCalibrationSessionGains(.neutral, displayID: displayID)
        if probe != nil { enterPlacement() } else { step = .connect }
    }

    func keep() {
        switch purpose {
        case .measureReference:
            if canKeep, let fitted { model.saveProbeCharacterization(fitted) }
        case .calibrate:
            if let record, let gains = record.bestGains {
                model.keepCalibration(DisplayCalibration(
                    red: DisplayCalibration.encoded(linear: gains.r, gamma: record.gamma),
                    green: DisplayCalibration.encoded(linear: gains.g, gamma: record.gamma),
                    blue: DisplayCalibration.encoded(linear: gains.b, gamma: record.gamma),
                    deltaEBefore: record.baselineDeltaE, deltaEAfter: record.bestDeltaE,
                    calibratedAt: Date(), matchedReference: correction != nil), displayID: displayID)
            }
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

    /// The reading's XYZ recomputed from its raw channels through the MacBook characterization.
    private func adapt(_ sample: MeasurementSample) -> MeasurementSample {
        guard let correction else { return sample }
        guard let v = correction.xyz(raw: sample.channels) else { rawChannelsMissing = true; return sample }
        var corrected = sample
        // d65 drops readings with a negative component; only near-black ones come out a hair below 0.
        corrected.xyz = XYZ(x: max(0, v.x), y: max(0, v.y), z: max(0, v.z))
        corrected.reportedCCT = nil  // the sensor's own CCT describes the uncorrected reading
        return corrected
    }

    /// Fits this phone's raw channels to the colours the MacBook showed: d65's patches are drawn in
    /// explicit sRGB, and the factory-calibrated, colour-managed panel shows them as specified.
    /// Nil for a probe that sends no raw channels.
    private func characterize(_ record: ExperimentRecord, whiteY: Double) -> ProbeCharacterization? {
        func raw(_ phase: String) -> [Double]? {
            let channels = record.measurements.last { $0.request.phase == phase }?.samples.map(\.channels)
                .filter { $0.count >= 3 } ?? []
            // Raw channels 0–3 (the probe appends diagnostics after them); older probes send fewer.
            guard let width = channels.map({ min(4, $0.count) }).min() else { return nil }
            return (0..<width).map { i in channels.reduce(0) { $0 + $1[i] } / Double(channels.count) }
        }
        guard let probe, let black = raw("black") else { return nil }
        let patches = CalibrationPatch.sequence.filter { $0.name != "black" }.compactMap { patch in
            raw(patch.name).map { ProbeCharacterization.Patch(red: patch.red, green: patch.green, blue: patch.blue,
                                                              raw: zip($0, black).map { $0 - $1 }) }
        }
        return ProbeCharacterization.characterize(patches, whiteY: whiteY, probeModel: probe.model, at: Date())
    }

    private func enterPlacement() {
        autoStartArmed = true
        placement = PlacementReading(state: .waiting)
        step = .place
        service?.beginPlacement(displayID: displayID)
    }

    private func preview() {
        guard purpose == .calibrate, step == .review, canKeep, let record, let gains = record.bestGains else { return }
        let shown = showOriginal ? ColorTemperatureCurve.Gains.neutral : ColorTemperatureCurve.Gains(
            red: DisplayCalibration.encoded(linear: gains.r, gamma: record.gamma),
            green: DisplayCalibration.encoded(linear: gains.g, gamma: record.gamma),
            blue: DisplayCalibration.encoded(linear: gains.b, gamma: record.gamma))
        model.setCalibrationSessionGains(shown, displayID: displayID)
    }

    /// d65 marks the whole run `.rejected` when the *next* pass would dim the display past its 20 % gate,
    /// even after a measured pass already improved the white within every gate. That pass stands.
    private static func bestPassStands(in record: ExperimentRecord) -> Bool {
        guard record.outcome == .rejected, record.restorationErrors.isEmpty, !record.passes.isEmpty,
              let gains = record.bestGains, !gains.isIdentity,
              let before = record.baselineDeltaE, let best = record.bestDeltaE else { return false }
        return best < before && best <= record.configuration.gate.maximumPostCorrectionDeltaE
    }

    /// The firmware's white, ambient subtracted: the white patch less the black one.
    private static func emittedWhite(in record: ExperimentRecord) -> XYZ? {
        guard let white = record.measurements.last(where: { $0.request.phase == "white" }) else { return nil }
        let ambient = record.measurements.last(where: { $0.request.phase == "black" })?.mean ?? .zero
        let emitted = white.subtracting(ambient)
        return emitted.y > 1 ? emitted : nil
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
            if let correction, correction.probeModel != identity.model {
                notice = String(localized: "The saved characterization belongs to another iPhone (\(correction.probeModel)). Measure the MacBook with this one first.")
            }
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
            switch purpose {
            case .measureReference:
                let white = Self.emittedWhite(in: record)
                firmwareWhite = white?.chromaticity
                fitted = white.flatMap { characterize(record, whiteY: $0.y) }
                // |Δx|+|Δy| 0.01 is about ΔE00 4: past that the run was too noisy to trust.
                canKeep = (fitted?.whiteCheckError ?? 1) <= 0.01
            case .calibrate:
                canKeep = record.bestGains != nil
                    && (SessionSummary(record: record).canKeep || Self.bestPassStands(in: record))
            }
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

// MARK: - Patch overlay

/// d65's overlay fills the whole screen and marks the sensor with a dark bar right under it, so a
/// hand shifting by a millimetre changes the reading and placement starts over. This one, adapted from
/// d65's `ScreenPatchPresenter` (MIT), lights only a patch a little larger than the phone on black —
/// like Apple TV's Color Balance and the 10 % windows calibration tools use — and keeps every mark
/// and word outside it. Esc cancels, Space starts now.
@MainActor final class PhonePatchOverlay: HostOverlay {
    let screen: NSScreen
    let displayID: UInt32
    var onCancel: (() -> Void)?
    var onStartNow: (() -> Void)?
    var showsProgress = true
    private var window: PatchWindow?
    private var view: PhonePatchView?
    private var cursorHidden = false
    private var awake: NSObjectProtocol?
    private var phoneModel: String?

    init(screen: NSScreen, displayID: UInt32) { self.screen = screen; self.displayID = displayID }

    func show(_ patch: CalibrationPatch) async throws {
        let view = open()
        view.fill = NSColor(srgbRed: patch.red, green: patch.green, blue: patch.blue, alpha: 1)
        view.hint = nil
        view.needsDisplay = true
        window?.displayIfNeeded()
    }

    func showPlacement(probeModel: String?, hint: String) {
        phoneModel = probeModel
        let view = open()
        view.fill = .white
        view.hint = hint.localized
        view.footer = String(localized: "Space to start now · Esc to cancel")
        view.fraction = nil
        view.needsDisplay = true
    }

    func setHint(_ hint: String) { view?.hint = hint.localized; view?.needsDisplay = true }

    func setProgress(_ text: String, fraction: Double?) {
        guard showsProgress else { return }
        view?.footer = text + " · Esc"; view?.fraction = fraction; view?.needsDisplay = true
    }

    func close() {
        window?.orderOut(nil); window = nil; view = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
    }

    private func open() -> PhonePatchView {
        if let view { view.patch = patchSize(); return view }
        // A dark or sleeping screen would blank the patch the phone is reading.
        awake = awake ?? ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Measuring the display with an iPhone")
        let w = PatchWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.setFrame(screen.frame, display: false)
        let v = PhonePatchView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.patch = patchSize()
        w.contentView = v
        w.onKey = { [weak self] event in
            switch event.keyCode {
            case 53: self?.onCancel?(); return true   // Esc
            case 49: self?.onStartNow?(); return true // Space
            default: return false
            }
        }
        window = w; view = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        return v
    }

    /// The phone at physical size plus a 6 mm margin, so a slightly off-centre phone still sits
    /// entirely on the patch.
    private func patchSize() -> CGSize {
        let phone = Self.bodies[phoneModel ?? ""] ?? PhoneOutline.millimetres(model: phoneModel)
        let physical = CGDisplayScreenSize(displayID)
        // EDID-derived and sometimes zero; fall back to ~110 ppi.
        let perMM = physical.width > 0 ? screen.frame.width / physical.width : 110 / 25.4
        return CGSize(width: (phone.width + 12) * perMM, height: (phone.height + 12) * perMM)
    }

    /// iPhone 17 family bodies, which d65's table predates.
    private static let bodies: [String: (width: Double, height: Double)] = [
        "iPhone18,1": (71.9, 150.0), "iPhone18,2": (78.0, 163.4), "iPhone18,3": (71.5, 149.6),
    ]
}

private final class PatchWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

private final class PhonePatchView: NSView {
    var fill: NSColor = .white
    var patch: CGSize = .zero
    var hint: String?
    var footer: String?
    var fraction: Double?

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let rect = NSRect(x: bounds.midX - patch.width / 2, y: bounds.midY - patch.height / 2,
                          width: patch.width, height: patch.height)
        let radius = patch.width * 0.14
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        // Marks stay outside the lit patch, where the phone's body covers nothing the sensor sees.
        let ink = NSColor(white: 1, alpha: 0.4)
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: -6, dy: -6), xRadius: radius + 6, yRadius: radius + 6)
        frame.lineWidth = 1.5
        frame.setLineDash([8, 6], count: 2, phase: 0)
        ink.setStroke(); frame.stroke()
        draw(String(localized: "Top of the iPhone here ↑"), at: NSPoint(x: rect.midX, y: rect.maxY + 26), size: 13, color: ink)
        if let hint {
            draw(hint, at: NSPoint(x: bounds.midX, y: min(bounds.maxY - 60, rect.maxY + 80)), size: 22,
                 color: NSColor(white: 1, alpha: 0.75), weight: .semibold)
        }
        if let footer {
            draw(footer, at: NSPoint(x: bounds.midX, y: max(40, rect.minY - 48)), size: 13, color: ink)
            if let fraction {
                let track = NSRect(x: rect.minX, y: max(40, rect.minY - 48) - 18, width: rect.width, height: 2)
                ink.withAlphaComponent(0.2).setFill(); track.fill()
                ink.setFill()
                NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: 2).fill()
            }
        }
    }

    private func draw(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let measured = string.size()
        string.draw(at: NSPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2))
    }
}

// MARK: - Session window

struct WhitePointSessionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: WhitePointSession
    let onDone: () -> Void

    private static let stepTitles = ["Prepare", "Connect", "Place", "Measure", "Review"]

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.md) {
            if session.purpose == .measureReference {
                Text("Characterize the iPhone on the MacBook").font(.title3)
            } else {
                Text("Calibrate white point · \(session.displayName)").font(.title3)
            }
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
        case .prepare: prepare
        case .connect:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for D65 Probe on your iPhone…")
            }
        case .place:
            VStack(alignment: .leading, spacing: 8) {
                Text("Press the iPhone face-down on the bright patch, top edge up, and hold it still.")
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
            if session.purpose == .measureReference { referenceReview } else { review }
        }
    }

    @ViewBuilder private var prepare: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.purpose == .measureReference {
                Text("1. Open D65 Probe on your iPhone and keep it on the same Wi-Fi as this Mac.")
                Text("2. Turn off True Tone and Night Shift for now. The MacBook screen lights up for the measurement and goes back to its brightness afterwards.")
                Text("3. In System Settings › Displays, turn off “Automatically adjust brightness” for the built-in display while you measure — otherwise covering its light sensor changes the brightness and placement keeps starting over.")
                Text("4. Tilt the MacBook screen back a little and press the iPhone face-down on the bright patch when it appears; hold it steady.")
                Text("The MacBook shows twelve patches of known colour; their readings teach OpenDisplay this iPhone’s sensor error. Calibrate with the same iPhone afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(isOn: $session.correctProbe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Correct the iPhone with its MacBook characterization")
                        if let characterization = session.characterization {
                            Text("Characterized with \(characterization.probeModel) on \(characterization.measuredAt.formatted(.dateTime.month(.abbreviated).day())).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Characterize the iPhone on the MacBook first (in the White point card); uncorrected, the iPhone reads whites far too blue.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(session.characterization == nil)
                Text("1. Open D65 Probe on your iPhone and keep it on the same Wi-Fi as this Mac.")
                Text("2. Turn off True Tone and Night Shift for now, and keep the room light steady and not too bright.")
                Text("3. Leave the monitor at the brightness and contrast you normally use — changing contrast later makes a calibration stale.")
                Text("4. Let the monitor warm up for 20–30 minutes first, and turn off its own dynamic contrast, eco mode and auto-brightness.")
                brightnessHint
            }
            Text("The display shows colour patches under the iPhone for about a minute. Press Esc on it to cancel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The display's live brightness: calibrate at the level you use, and not so dim that the
    /// iPhone sensor's noise (worst on the dark blue patch) swamps the reading.
    @ViewBuilder private var brightnessHint: some View {
        if let observation = model.displays.first(where: { $0.cgDisplayID == session.displayID }),
           let level = model.brightness[observation.recordID] {
            let percent = Int((level * 100).rounded())
            if level < 0.4 {
                Text("Brightness is \(percent)% — too dim for the iPhone sensor. Raise it to the level you normally use (40% or more) before you start.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Current brightness: \(percent)%. The calibration is most accurate near this level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    let target = "D65"
                    if let after = record.bestDeltaE {
                        Text("Distance from \(target), ΔE00: \(String(format: "%.2f", before)) → \(String(format: "%.2f", after))")
                    } else {
                        Text("Distance from \(target), ΔE00: \(String(format: "%.2f", before))")
                    }
                }
                if let gains = record.bestGains {
                    Text("Gains R \(String(format: "%.3f", gains.r)) · G \(String(format: "%.3f", gains.g)) · B \(String(format: "%.3f", gains.b))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if session.canKeep, record.outcome == .rejected {
                    Text("Getting any closer would dim the display by more than 20 %, so it stopped at the best measured pass.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.rawChannelsMissing {
                    Text("This D65 Probe sends no raw channels, so its readings weren’t corrected. Install the OpenDisplay build of the probe.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.canKeep {
                    Toggle("Show the original", isOn: $session.showOriginal).toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var referenceReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fitted = session.fitted {
                Text(session.canKeep ? "iPhone characterized." : "The readings were too noisy to trust.").font(.headline)
                if let white = session.firmwareWhite {
                    Text("The iPhone’s own reading of the MacBook white: about \(Int(white.correlatedColorTemperature().rounded())) K (the screen is 6500 K).")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Check — corrected, the white lands within Δxy \(String(format: "%.4f", fitted.whiteCheckError)) of 6500 K, with the white left out of the fit.")
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(session.canKeep
                     ? "Save it, then calibrate each external display with the correction on."
                     : "Keep the phone still and flat on the patch, then try again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.firmwareWhite != nil {
                Text("This D65 Probe sends no raw channels, so it can’t be characterized. Install the OpenDisplay build of the probe.")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The measurement wasn’t usable — try again with the phone flat on the patch.").font(.headline)
            }
        }
    }

    private var placementText: String {
        switch session.placement.state {
        case .waiting: return String(localized: "Waiting for the phone on the patch")
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
                Button(session.purpose == .measureReference ? "Save" : "Keep") { session.keep(); onDone() }
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

/// The "White point" card on an external display's page: the iPhone's MacBook characterization, and
/// this display's calibration (status, calibrate, remove).
struct WhitePointCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var session: WhitePointSession?

    var body: some View {
        ODCard(title: "White point",
               footnote: "Measured with the D65 Probe app on an iPhone placed on the screen. Corrects the white only, in software, while OpenDisplay runs.") {
            ODRow("iPhone characterization", secondary: referenceStatus) {
                Button("Measure MacBook…") {
                    guard let builtIn = model.activeBuiltInDisplay, let cgID = builtIn.cgDisplayID else { return }
                    session = WhitePointSession(purpose: .measureReference, displayID: cgID,
                                                displayName: model.displayName(for: builtIn), model: model)
                }
                .controlSize(.small)
                .disabled(session != nil || model.activeBuiltInDisplay == nil)
            }
            ODDivider()
            ODRow("Calibration", secondary: status) {
                HStack(spacing: 8) {
                    if model.calibration(for: display) != nil {
                        Button("Remove") { model.removeCalibration(for: display) }
                            .controlSize(.small)
                    }
                    Button("Calibrate…") {
                        guard let cgID = display.cgDisplayID else { return }
                        session = WhitePointSession(purpose: .calibrate, displayID: cgID,
                                                    displayName: model.displayName(for: display), model: model)
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

    private var referenceStatus: String {
        guard model.activeBuiltInDisplay != nil || model.probeCharacterization != nil else {
            return String(localized: "Turn the built-in display on to measure it")
        }
        guard let characterization = model.probeCharacterization else { return String(localized: "Not measured on the MacBook yet") }
        let date = characterization.measuredAt.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "\(characterization.probeModel) · check Δxy \(String(format: "%.3f", characterization.whiteCheckError)) · \(date)")
    }

    private var status: String {
        guard let calibration = model.calibration(for: display) else { return String(localized: "Not calibrated") }
        let date = calibration.calibratedAt.formatted(.dateTime.month(.abbreviated).day())
        let target = calibration.matchedReference == true ? String(localized: "D65, corrected iPhone") : "D65"
        if let before = calibration.deltaEBefore, let after = calibration.deltaEAfter {
            return String(localized: "Calibrated to \(target) · ΔE \(String(format: "%.1f", before)) → \(String(format: "%.1f", after)) · \(date)")
        }
        return String(localized: "Calibrated to \(target) · \(date)")
    }
}
#endif
