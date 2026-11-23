import Foundation

/// Tunables for Adaptive Display, derived from `OpenDisplaySettings` (one value object so the
/// policy signature stays stable as knobs are added).
public struct AdaptiveDisplayConfig: Hashable, Sendable {
    /// Minute-of-day the day phase begins (ramp up starts here).
    public var dayStartMinute: Int
    /// Minute-of-day the night phase begins (ramp down starts here).
    public var nightStartMinute: Int
    /// Width in minutes of the linear ramp at each edge.
    public var transitionMinutes: Int
    /// Schedule-fallback brightness plateaus (0...1).
    public var fallbackDayLevel: Float
    public var fallbackNightLevel: Float
    /// Minimum target movement before a DDC write is issued. Keeps quiet-light ticks write-free
    /// and bounds bus traffic; DDC values are 0...100 on most panels, so 0.02 ≈ 2 panel steps.
    public var hysteresis: Float
    /// Seconds after a manual brightness change during which adaptive stays hands-off (sync mode).
    public var manualCooldown: TimeInterval

    public init(dayStartMinute: Int = 420, nightStartMinute: Int = 1140, transitionMinutes: Int = 30,
                fallbackDayLevel: Float = 0.8, fallbackNightLevel: Float = 0.35,
                hysteresis: Float = 0.02, manualCooldown: TimeInterval = 60) {
        self.dayStartMinute = dayStartMinute
        self.nightStartMinute = nightStartMinute
        self.transitionMinutes = transitionMinutes
        self.fallbackDayLevel = fallbackDayLevel
        self.fallbackNightLevel = fallbackNightLevel
        self.hysteresis = hysteresis
        self.manualCooldown = manualCooldown
    }
}

extension OpenDisplaySettings {
    /// The adaptive tunables as one value (hysteresis/cooldown are code constants, not settings).
    public var adaptiveConfig: AdaptiveDisplayConfig {
        AdaptiveDisplayConfig(
            dayStartMinute: adaptiveDayStartMinute, nightStartMinute: adaptiveNightStartMinute,
            transitionMinutes: adaptiveTransitionMinutes, fallbackDayLevel: adaptiveFallbackDayLevel,
            fallbackNightLevel: adaptiveFallbackNightLevel)
    }
}

/// Pure decision core for per-display auto-brightness (plus Clock Mode and Location Mode), the
/// "transfer the built-in display's intelligence to the external monitor" feature.
///
/// Deterministic and clock-free: the caller injects `now` (used only for cooldown arithmetic) and
/// `minuteOfDay` (so the policy never touches Calendar/timezones), threads a caller-owned
/// `DisplayState` through, and receives a `Decision` naming the writes to perform. All hardware,
/// persistence, and UI side effects belong to the caller (AppModel) — this type is exercised by
/// `make test` like `MediaKeyTargetPolicy` and `OSDPresentationPolicy`.
public enum AdaptiveDisplayPolicy {
    /// Caller-owned per-display evolution state, threaded through `evaluate`.
    public struct DisplayState: Hashable, Sendable {
        /// Hysteresis anchor: the last brightness adaptive wrote (or adopted from a manual change).
        public var lastWrittenBrightness: Float?
        /// Learned offset relative to the built-in (sync mode): external = builtIn + offset.
        public var brightnessOffset: Float
        /// When the user last changed brightness manually (cooldown anchor); nil = never.
        public var manualBrightnessAt: Date?
        /// Schedule-mode adoption: the schedule target at the moment of the manual change. While the
        /// schedule target stays within hysteresis of this anchor, adaptive holds off — a bare
        /// cooldown would snap the user's setting back after 60s even though nothing changed.
        public var manualScheduleAnchor: Float?

        public init(lastWrittenBrightness: Float? = nil, brightnessOffset: Float = 0,
                    manualBrightnessAt: Date? = nil, manualScheduleAnchor: Float? = nil) {
            self.lastWrittenBrightness = lastWrittenBrightness
            self.brightnessOffset = brightnessOffset
            self.manualBrightnessAt = manualBrightnessAt
            self.manualScheduleAnchor = manualScheduleAnchor
        }
    }

    /// One tick's worth of observed world, assembled by the caller.
    public struct Input: Hashable, Sendable {
        public var now: Date
        public var minuteOfDay: Int
        /// Topology says a built-in panel is ACTIVE (false ⇒ built-in off or lid closed). Never
        /// derive this from a read failure — a transient failure must skip the tick, not flip modes.
        public var builtInPresent: Bool
        /// The built-in's current brightness, nil on a transient read failure.
        public var builtInBrightness: Float?
        /// Smoothed ambient light in lux, when the sensor is readable (lid open). Drives brightness
        /// directly when the built-in is off-but-lid-open — the user's "internal display off, Mac
        /// keyboard" mode — so real light intelligence survives without any panel to mirror.
        public var ambientLux: Double?
        /// This external is asleep — adaptive must not touch it at all.
        public var displayAsleep: Bool
        /// Whether anything governs this display's brightness (its auto-brightness switch, Clock Mode
        /// or Location Mode); false ⇒ the tick leaves it alone.
        public var brightnessSyncEnabled: Bool
        /// Clock Mode's explicit scheduled brightness for this tick, or nil when Clock Mode isn't
        /// governing. When present it TAKES PRECEDENCE over the built-in mirror and the ambient
        /// curve — an explicit user schedule outranks the inferred sync — while reusing the same
        /// cooldown/hysteresis/manual-adoption machinery so the write stays silent and non-fighting.
        public var scheduleOverride: Float?
        /// Location Mode: the sun's current elevation in degrees at the configured location, or nil
        /// when Location Mode is off or no location is configured. A user-selected source like the
        /// ambient curve — it slots in below the built-in mirror and the ambient sensor (both are
        /// live readings and win when available) but above the flat day/night schedule, making it a
        /// better lid-closed fallback than a fixed plateau. `scheduleOverride` still outranks it.
        public var locationElevationDegrees: Double?

        public init(now: Date, minuteOfDay: Int, builtInPresent: Bool, builtInBrightness: Float?,
                    ambientLux: Double? = nil, displayAsleep: Bool, brightnessSyncEnabled: Bool,
                    scheduleOverride: Float? = nil, locationElevationDegrees: Double? = nil) {
            self.now = now
            self.minuteOfDay = minuteOfDay
            self.builtInPresent = builtInPresent
            self.builtInBrightness = builtInBrightness
            self.ambientLux = ambientLux
            self.displayAsleep = displayAsleep
            self.brightnessSyncEnabled = brightnessSyncEnabled
            self.scheduleOverride = scheduleOverride
            self.locationElevationDegrees = locationElevationDegrees
        }
    }

    /// What the caller should do this tick: issue `brightnessWrite` (if any), then store `state`.
    public struct Decision: Hashable, Sendable {
        public var brightnessWrite: Float?
        public var state: DisplayState

        public init(brightnessWrite: Float? = nil, state: DisplayState) {
            self.brightnessWrite = brightnessWrite
            self.state = state
        }
    }

    // MARK: - Schedule curve

    /// The schedule-fallback brightness at a minute-of-day: day/night plateaus joined by linear
    /// ramps of `transitionMinutes` starting at each edge (day ramps UP from `dayStartMinute`,
    /// night ramps DOWN from `nightStartMinute`). Handles night phases that wrap midnight.
    public static func scheduleLevel(atMinute minute: Int, config: AdaptiveDisplayConfig) -> Float {
        let ramp = max(1, config.transitionMinutes)
        let day = config.fallbackDayLevel
        let night = config.fallbackNightLevel
        if let progress = rampProgress(minute, from: config.dayStartMinute, width: ramp) {
            return night + (day - night) * progress  // morning: night → day
        }
        if let progress = rampProgress(minute, from: config.nightStartMinute, width: ramp) {
            return day - (day - night) * progress    // evening: day → night
        }
        return scheduleIsNight(atMinute: minute, config: config) ? night : day
    }

    /// Whether a minute-of-day falls in the night phase: it begins AT `nightStartMinute` and ends
    /// AT `dayStartMinute` (the plateau `scheduleLevel` returns outside the ramps).
    public static func scheduleIsNight(atMinute minute: Int, config: AdaptiveDisplayConfig) -> Bool {
        inWrappedRange(minute, from: config.nightStartMinute, to: config.dayStartMinute)
    }

    /// Brightness level for an ambient light reading: log-linear from 10 lux (dark room → 0.25)
    /// to 5000 lux (bright daylight room → 1.0). Log because perception and typical indoor
    /// lighting both span orders of magnitude — linear lux would slam to full brightness the
    /// moment a lamp comes on. The learned per-display offset applies on top, so the curve only
    /// has to be *reasonable*, not perfect for every room.
    public static func ambientLevel(forLux lux: Double) -> Float {
        let floorLux = 10.0, ceilLux = 5000.0
        let floorLevel: Float = 0.25, ceilLevel: Float = 1.0
        guard lux > floorLux else { return floorLevel }
        guard lux < ceilLux else { return ceilLevel }
        let progress = Float((log10(lux) - log10(floorLux)) / (log10(ceilLux) - log10(floorLux)))
        return floorLevel + (ceilLevel - floorLevel) * progress
    }

    /// Brightness level for the sun's elevation above the horizon (Location Mode): a night floor
    /// while the sun sits below civil twilight (-6°, the point outdoor light is negligible), a
    /// linear ramp through dawn/dusk, and a plateau once the sun is high enough (20°) that indoor
    /// natural light is already plentiful. Linear-in-elevation is the simple, honest model — unlike
    /// `ambientLevel` there is no lux reading to fit a curve to, only the sun's geometry.
    public static func locationLevel(forElevationDegrees elevation: Double) -> Float {
        let nightFloorElevation = -6.0
        let daylightPlateauElevation = 20.0
        let floorLevel: Float = 0.2, ceilLevel: Float = 1.0
        guard elevation > nightFloorElevation else { return floorLevel }
        guard elevation < daylightPlateauElevation else { return ceilLevel }
        let progress = Float((elevation - nightFloorElevation)
            / (daylightPlateauElevation - nightFloorElevation))
        return floorLevel + (ceilLevel - floorLevel) * progress
    }

    /// Progress 0...1 through a ramp starting at `start` of `width` minutes, or nil outside it
    /// (wrap-aware: a ramp beginning at 23:50 continues past midnight).
    private static func rampProgress(_ minute: Int, from start: Int, width: Int) -> Float? {
        let delta = ((minute - start) % 1440 + 1440) % 1440
        guard delta < width else { return nil }
        return (Float(delta) + 1) / Float(width)
    }

    /// Whether `minute` lies in [from, to) on a 24h clock, correctly when the range wraps midnight.
    private static func inWrappedRange(_ minute: Int, from: Int, to: Int) -> Bool {
        if from == to { return false }
        if from < to { return minute >= from && minute < to }
        return minute >= from || minute < to
    }

    // MARK: - Manual-change bookkeeping

    /// Record a user-initiated brightness change on a synced display. Sets the cooldown stamp and
    /// the hysteresis anchor (so post-cooldown resumption doesn't immediately re-write). When a
    /// live reference level exists (the built-in's brightness in sync mode, or the ambient-light
    /// curve level in sensor mode) the change *teaches the offset* relative to it; with no
    /// reference (schedule mode) it records the adoption anchor instead — see
    /// `DisplayState.manualScheduleAnchor`.
    public static func noteManualBrightness(_ value: Float, reference: Float?,
                                            scheduleTarget: Float, at now: Date,
                                            state: DisplayState) -> DisplayState {
        var state = state
        state.manualBrightnessAt = now
        state.lastWrittenBrightness = value
        if let reference {
            state.brightnessOffset = min(1, max(-1, value - reference))
        } else {
            state.manualScheduleAnchor = scheduleTarget
        }
        return state
    }

    // MARK: - Tick evaluation

    public static func evaluate(_ input: Input, config: AdaptiveDisplayConfig,
                                state: DisplayState) -> Decision {
        var state = state
        guard !input.displayAsleep, input.brightnessSyncEnabled else { return Decision(state: state) }
        let brightnessWrite = brightnessDecision(input, config: config, state: &state)
        return Decision(brightnessWrite: brightnessWrite, state: state)
    }

    private static func brightnessDecision(_ input: Input, config: AdaptiveDisplayConfig,
                                           state: inout DisplayState) -> Float? {
        // Cooldown: the user just adjusted this display — stay hands-off.
        if let manualAt = state.manualBrightnessAt,
           input.now < manualAt.addingTimeInterval(config.manualCooldown) {
            return nil
        }
        let target: Float
        if let override = input.scheduleOverride {
            // Clock Mode precedence: an explicit user schedule outranks the built-in mirror and the
            // ambient curve. Adopt a manual change the same way schedule mode does — hold the user's
            // level until the scheduled target itself moves past hysteresis.
            target = override
            if let anchor = state.manualScheduleAnchor {
                if abs(target - anchor) < config.hysteresis { return nil }
                state.manualScheduleAnchor = nil
            }
        } else if input.builtInPresent {
            // Sync mode. A nil sample is a transient read failure: skip the tick — NEVER treat it
            // as built-in-gone (that would yank brightness to a fallback level on a hiccup).
            guard let builtIn = input.builtInBrightness else { return nil }
            target = min(1, max(0, builtIn + state.brightnessOffset))
            state.manualScheduleAnchor = nil  // anchor is a schedule-mode concept
        } else if let lux = input.ambientLux {
            // Ambient mode: built-in off but the lid is open, so the light sensor still sees the
            // room — follow it directly. Same offset-learning contract as sync mode.
            target = min(1, max(0, ambientLevel(forLux: lux) + state.brightnessOffset))
            state.manualScheduleAnchor = nil
        } else if let elevationDegrees = input.locationElevationDegrees {
            // Location Mode: neither a live mirror nor an ambient reading is available (typically
            // lid closed, no light sensor) — follow the sun's elevation instead of the flat
            // schedule. Same offset-learning contract as sync/ambient mode.
            target = min(1, max(0, locationLevel(forElevationDegrees: elevationDegrees) + state.brightnessOffset))
            state.manualScheduleAnchor = nil
        } else {
            target = scheduleLevel(atMinute: input.minuteOfDay, config: config)
            // Schedule-mode adoption: hold the user's manual level until the schedule target
            // itself moves past hysteresis from where it was when they set it.
            if let anchor = state.manualScheduleAnchor {
                if abs(target - anchor) < config.hysteresis { return nil }
                state.manualScheduleAnchor = nil
            }
        }
        if let last = state.lastWrittenBrightness, abs(target - last) < config.hysteresis {
            return nil
        }
        state.lastWrittenBrightness = target
        return target
    }
}
