//
//  GlanceSettings.swift
//  glance
//
//  Single source of truth for persisted user preferences. Backed directly by
//  `UserDefaults.standard` — each property's `didSet` writes through
//  immediately, so there's no explicit "save" step. This is the first
//  preference-persistence layer in the app; before this, `isEnabled` /
//  `matchThreshold` silently reset on every launch.
//

import Foundation
import Observation

/// How long the Touch-ID-unlocked session may sit idle before it re-locks
/// and Touch ID is required again. Backed by the raw day count so the
/// persisted value stays readable and the four options can be reordered or
/// extended without invalidating what's already stored.
enum AutoLockInterval: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }

    var title: String { rawValue == 1 ? "1 day" : "\(rawValue) days" }

    var duration: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }

    /// Position in `allCases`, used to drive the discrete 4-stop slider.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> AutoLockInterval {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .sevenDays
    }
}

/// Unlock success/failure animation style shown in the notch overlay.
enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case none
    case minimal
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .original: return "Original"
        }
    }

    /// The styles the picker actually offers. `.none` is still a valid
    /// *stored* value — the overlay's resolve path keys off it — but it's no
    /// longer chosen by picking a tile; the "Show animation" toggle
    /// (`GlanceSettings.showUnlockAnimation`) produces it instead.
    static let selectableCases: [UnlockAnimationStyle] = [.minimal, .original]
}

/// What can prompt Face Unlock. Multi-select — any combination may be armed,
/// and at least one is always kept selected (a Mac with none selected would
/// never show the notch, leaving nothing to hover and no way back in).
enum UnlockTrigger: String, CaseIterable, Identifiable {
    /// The display turned back on — from real system sleep, from
    /// display-only sleep, or from the screensaver stopping at an
    /// already-locked screen. See `LockEventKind.wake` for why this used to
    /// be two separate options ("On wake" / "On activity") and no longer is:
    /// the split was unreliable and effectively made "On wake" alone never
    /// fire in the common case.
    case onWake
    /// The screen just became locked, no wake involved.
    case onLock
    /// Pressing space on the lock screen starts a scan. The lock screen runs
    /// under Secure Event Input, which suppresses event taps and `NSEvent`
    /// monitors, so this is detected via IOKit HID below that boundary (see
    /// `SpaceKeyMonitor`) — which requires the Input Monitoring permission.
    case onSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onWake: return "On wake"
        case .onLock: return "On lock"
        case .onSpace: return "On space"
        }
    }

    var iconName: String {
        switch self {
        case .onWake: return "zzz"
        case .onLock: return "lock.display"
        case .onSpace: return "space"
        }
    }
}

@Observable
@MainActor
final class GlanceSettings {
    static let shared = GlanceSettings()

    private enum Key {
        static let isFaceUnlockEnabled = "GlanceSettings.isFaceUnlockEnabled"
        static let matchThreshold = "GlanceSettings.matchThreshold"
        static let livenessChecksEnabled = "GlanceSettings.livenessChecksEnabled"
        static let livenessMode = "GlanceSettings.livenessMode"
        static let minimumFaceWidth = "GlanceSettings.minimumFaceWidth"
        static let unlockAnimationStyle = "GlanceSettings.unlockAnimationStyle"
        static let showUnlockAnimation = "GlanceSettings.showUnlockAnimation"
        /// Legacy bool key — read once during migration, then ignored.
        static let playUnlockAnimation = "GlanceSettings.playUnlockAnimation"
        static let unlockTriggers = "GlanceSettings.unlockTriggers"
        static let retryOnHover = "GlanceSettings.retryOnHover"
        static let faceDetectionSeconds = "GlanceSettings.faceDetectionSeconds"
        static let autoRetryOnce = "GlanceSettings.autoRetryOnce"
        static let hapticFeedbackEnabled = "GlanceSettings.hapticFeedbackEnabled"
        static let preferredDisplayID = "GlanceSettings.preferredDisplayID"
        static let preferredDisplayName = "GlanceSettings.preferredDisplayName"
        static let autoLockIntervalDays = "GlanceSettings.autoLockIntervalDays"
        static let defaultCameraID = "GlanceSettings.defaultCameraID"
        static let builtInDisplayCameraID = "GlanceSettings.builtInDisplayCameraID"
        static let externalDisplayCameraID = "GlanceSettings.externalDisplayCameraID"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var isFaceUnlockEnabled: Bool {
        didSet { defaults.set(isFaceUnlockEnabled, forKey: Key.isFaceUnlockEnabled) }
    }
    var matchThreshold: Float {
        didSet { defaults.set(matchThreshold, forKey: Key.matchThreshold) }
    }
    /// Master switch for liveness checking. Off means face recognition
    /// alone decides an unlock — convenient, and strictly less safe: a
    /// photo of the enrolled user on a phone screen would be accepted.
    ///
    /// Read directly from `FaceUnlockCoordinator`'s scan loop, which runs on
    /// the main actor — unlike `minimumFaceWidth` below, these need no
    /// `nonisolated(unsafe)` mirror, since nothing reads them from a
    /// background task.
    var livenessChecksEnabled: Bool {
        didSet { defaults.set(livenessChecksEnabled, forKey: Key.livenessChecksEnabled) }
    }
    /// Light (deny-only) vs Heavy (deny plus a required proof of life) —
    /// see `LivenessMode`.
    var livenessMode: LivenessMode {
        didSet { defaults.set(livenessMode.rawValue, forKey: Key.livenessMode) }
    }
    /// Mirrored into `FaceRecognitionPipeline.minimumProminentFaceWidth`
    /// (a `nonisolated(unsafe) static var`) on every change, since that
    /// value is read from a background-thread `nonisolated` context that
    /// can't synchronously touch this MainActor-isolated class.
    var minimumFaceWidth: Float {
        didSet {
            defaults.set(minimumFaceWidth, forKey: Key.minimumFaceWidth)
            FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
        }
    }
    /// The *remembered* choice — only ever `.minimal` or `.original`.
    /// Whether an animation plays at all is `showUnlockAnimation`, kept
    /// separate so toggling off and back on restores the previous pick
    /// instead of resetting it. Read `effectiveUnlockAnimationStyle`, not
    /// this, to decide what to actually show.
    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }
    var showUnlockAnimation: Bool {
        didSet { defaults.set(showUnlockAnimation, forKey: Key.showUnlockAnimation) }
    }

    /// What the overlay should actually render — the pick, or `.none` when
    /// animations are switched off entirely.
    var effectiveUnlockAnimationStyle: UnlockAnimationStyle {
        showUnlockAnimation ? unlockAnimationStyle : .none
    }

    /// Which signals arm Face Unlock. Persisted as a `[String]` of raw
    /// values — the first multi-select preference in the app, but string
    /// arrays are natively `UserDefaults`-representable so it stays close to
    /// the single-select `rawValue` convention used everywhere else here.
    /// The setter refuses to store an empty set (see `UnlockTrigger`).
    var unlockTriggers: Set<UnlockTrigger> {
        didSet {
            // Belt-and-braces behind the picker's own min-one rule.
            // Assigning here *does* re-enter `didSet` (self-reassignment
            // inside a didSet always does — see `faceDetectionSeconds` for
            // what happens when that reentry isn't guarded), but it
            // terminates after one extra pass: the corrected value is never
            // itself empty, so the second call's `isEmpty` check is false
            // and it falls straight through to `defaults.set` below.
            if unlockTriggers.isEmpty {
                unlockTriggers = oldValue.isEmpty ? Set(UnlockTrigger.allCases) : oldValue
            }
            defaults.set(unlockTriggers.map(\.rawValue), forKey: Key.unlockTriggers)
        }
    }
    var retryOnHover: Bool {
        didSet { defaults.set(retryOnHover, forKey: Key.retryOnHover) }
    }
    /// How long each scan cycle looks for a face before giving up. Drives
    /// both the recognition loop's deadline and the overlay's own collapse
    /// timer — see `FaceUnlockCoordinator.scanWindowDuration` and
    /// `NotchOverlayController.scanTimeoutDuration`, which must stay equal.
    var faceDetectionSeconds: Int {
        didSet {
            // Reassigning unconditionally here would retrigger `didSet` on
            // every single set — including already-in-range ones, which is
            // all the slider ever produces — for infinite recursion that
            // hangs the (MainActor-isolated) app the instant the slider
            // moves. Only reassign when clamping actually changes the
            // value, so the recursive call it causes is guaranteed to see
            // `clamped == faceDetectionSeconds` and stop there.
            let clamped = min(max(faceDetectionSeconds, Self.faceDetectionRange.lowerBound),
                               Self.faceDetectionRange.upperBound)
            guard clamped == faceDetectionSeconds else {
                faceDetectionSeconds = clamped
                return
            }
            defaults.set(faceDetectionSeconds, forKey: Key.faceDetectionSeconds)
        }
    }
    var autoRetryOnce: Bool {
        didSet { defaults.set(autoRetryOnce, forKey: Key.autoRetryOnce) }
    }
    /// Trackpad haptic on hovering the notch/pill, and on a successful
    /// unlock. See `NotchOverlayView`'s hover handler and
    /// `.onChange(of: controller.phase)` for where these actually fire.
    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }

    static let faceDetectionRange = 3...10

    /// Which display Face Unlock is allowed to show on. `nil` means "Main
    /// display" — `NotchGeometry.preferredScreen()`'s existing behavior
    /// (the notched display if any is connected, else the system's primary
    /// display), re-evaluated live. A non-nil value pins the overlay to one
    /// specific screen, identified by `NSScreen.stableDisplayID` — and
    /// deliberately has NO fallback: if that display isn't connected right
    /// now, Face Unlock doesn't arm on any other display either (gated in
    /// `FaceUnlockCoordinator.evaluateTrigger()`).
    var preferredDisplayID: String? {
        didSet { defaults.set(preferredDisplayID, forKey: Key.preferredDisplayID) }
    }
    /// The chosen display's name at the time it was picked — cosmetic only,
    /// so the settings row can still show something recognizable
    /// ("LG UltraFine (disconnected)") when that display isn't currently
    /// connected, rather than falling back to a bare ID.
    var preferredDisplayName: String? {
        didSet { defaults.set(preferredDisplayName, forKey: Key.preferredDisplayName) }
    }
    /// Enforced by `SessionAutoLocker`, not here — this is only the stored
    /// preference.
    var autoLockInterval: AutoLockInterval {
        didSet { defaults.set(autoLockInterval.rawValue, forKey: Key.autoLockIntervalDays) }
    }
    /// Device `uniqueID`s, not device objects — devices can disconnect/
    /// reconnect between launches, but their unique ID is stable.
    var defaultCameraID: String? {
        didSet { defaults.set(defaultCameraID, forKey: Key.defaultCameraID) }
    }
    var builtInDisplayCameraID: String? {
        didSet { defaults.set(builtInDisplayCameraID, forKey: Key.builtInDisplayCameraID) }
    }
    var externalDisplayCameraID: String? {
        didSet { defaults.set(externalDisplayCameraID, forKey: Key.externalDisplayCameraID) }
    }

    private init() {
        isFaceUnlockEnabled = defaults.object(forKey: Key.isFaceUnlockEnabled) as? Bool ?? false
        matchThreshold = defaults.object(forKey: Key.matchThreshold) as? Float ?? 0.6
        livenessChecksEnabled = defaults.object(forKey: Key.livenessChecksEnabled) as? Bool ?? true
        // Light by default, deliberately. Heavy requires one of flat-vs-3D,
        // depth/pose, or a blink to actually fire before it will unlock —
        // and a real user who holds still and doesn't blink produces none
        // of them, which would leave them unable to unlock at all. Light
        // still rejects the attack this app most needs to catch (a face on
        // a phone screen) without ever blocking a legitimate scan.
        livenessMode = defaults.string(forKey: Key.livenessMode)
            .flatMap(LivenessMode.init(rawValue:)) ?? .light
        minimumFaceWidth = defaults.object(forKey: Key.minimumFaceWidth) as? Float ?? 0.18

        // Resolve the stored style first, `.none` included, then split it
        // into the pick + the on/off flag the UI now works in.
        let storedStyle: UnlockAnimationStyle
        if let raw = defaults.string(forKey: Key.unlockAnimationStyle),
           let style = UnlockAnimationStyle(rawValue: raw) {
            storedStyle = style
        } else if let legacy = defaults.object(forKey: Key.playUnlockAnimation) as? Bool {
            // Migrate the oldest on/off toggle: off → none, on → original.
            storedStyle = legacy ? .original : .none
        } else {
            storedStyle = .original
        }
        // A stored `.none` becomes "animations off, remembering .original",
        // so switching them back on has something to restore. An explicit
        // flag written by a newer build always wins over that inference.
        unlockAnimationStyle = storedStyle == .none ? .original : storedStyle
        showUnlockAnimation = defaults.object(forKey: Key.showUnlockAnimation) as? Bool
            ?? (storedStyle != .none)

        // Every trigger on by default — that's what the app did before this
        // was configurable (it armed on any lock-related signal), so an
        // existing install sees no behavior change.
        let storedTriggers = (defaults.array(forKey: Key.unlockTriggers) as? [String])?
            .compactMap { raw -> UnlockTrigger? in
                // "onActivity" was merged into "onWake" — an install that
                // had it selected (quite possibly the *only* trigger that
                // actually worked, given why the merge happened) should keep
                // working the same way rather than silently losing it.
                if raw == "onActivity" { return .onWake }
                return UnlockTrigger(rawValue: raw)
            }
        unlockTriggers = storedTriggers.map(Set.init).flatMap { $0.isEmpty ? nil : $0 }
            ?? Set(UnlockTrigger.allCases)
        retryOnHover = defaults.object(forKey: Key.retryOnHover) as? Bool ?? true
        faceDetectionSeconds = (defaults.object(forKey: Key.faceDetectionSeconds) as? Int)
            .map { min(max($0, Self.faceDetectionRange.lowerBound), Self.faceDetectionRange.upperBound) }
            ?? 5
        autoRetryOnce = defaults.object(forKey: Key.autoRetryOnce) as? Bool ?? false
        hapticFeedbackEnabled = defaults.object(forKey: Key.hapticFeedbackEnabled) as? Bool ?? true
        preferredDisplayID = defaults.string(forKey: Key.preferredDisplayID)
        preferredDisplayName = defaults.string(forKey: Key.preferredDisplayName)

        // Defaults to 7 days: long enough not to nag someone who uses face
        // unlock daily, short enough that an abandoned Mac doesn't keep a
        // usable session key in memory indefinitely.
        autoLockInterval = (defaults.object(forKey: Key.autoLockIntervalDays) as? Int)
            .flatMap(AutoLockInterval.init(rawValue:)) ?? .sevenDays
        defaultCameraID = defaults.string(forKey: Key.defaultCameraID)
        builtInDisplayCameraID = defaults.string(forKey: Key.builtInDisplayCameraID)
        externalDisplayCameraID = defaults.string(forKey: Key.externalDisplayCameraID)

        // Push the persisted value into the nonisolated mirror immediately —
        // otherwise FaceRecognitionPipeline would keep using its own 0.18
        // default until the user first touches the Recognition page's slider.
        FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
    }
}
