//
//  GlanceSettings.swift
//  glance
//
//  Single source of truth for persisted user preferences. Backed directly by
//  `UserDefaults.standard` — each property's `didSet` writes through
//  immediately, so there's no explicit "save" step. This is the first
//  preference-persistence layer in the app; before this, `isEnabled` /
//  `matchThreshold` / `autoInjectOnLock` all silently reset on every launch.
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
}

@Observable
@MainActor
final class GlanceSettings {
    static let shared = GlanceSettings()

    private enum Key {
        static let isFaceUnlockEnabled = "GlanceSettings.isFaceUnlockEnabled"
        static let matchThreshold = "GlanceSettings.matchThreshold"
        static let minimumFaceWidth = "GlanceSettings.minimumFaceWidth"
        static let unlockOnWake = "GlanceSettings.unlockOnWake"
        static let unlockAnimationStyle = "GlanceSettings.unlockAnimationStyle"
        /// Legacy bool key — read once during migration, then ignored.
        static let playUnlockAnimation = "GlanceSettings.playUnlockAnimation"
        static let autoCheckForUpdates = "GlanceSettings.autoCheckForUpdates"
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
    var unlockOnWake: Bool {
        didSet { defaults.set(unlockOnWake, forKey: Key.unlockOnWake) }
    }
    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }

    /// Convenience for call sites that only care whether any unlock animation plays.
    var playUnlockAnimation: Bool { unlockAnimationStyle != .none }
    /// UI-only for now — no update mechanism exists yet.
    var autoCheckForUpdates: Bool {
        didSet { defaults.set(autoCheckForUpdates, forKey: Key.autoCheckForUpdates) }
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
        minimumFaceWidth = defaults.object(forKey: Key.minimumFaceWidth) as? Float ?? 0.18
        unlockOnWake = defaults.object(forKey: Key.unlockOnWake) as? Bool ?? false
        if let raw = defaults.string(forKey: Key.unlockAnimationStyle),
           let style = UnlockAnimationStyle(rawValue: raw) {
            unlockAnimationStyle = style
        } else if let legacy = defaults.object(forKey: Key.playUnlockAnimation) as? Bool {
            // Migrate the old on/off toggle: off → none, on → original.
            unlockAnimationStyle = legacy ? .original : .none
        } else {
            unlockAnimationStyle = .original
        }
        autoCheckForUpdates = defaults.object(forKey: Key.autoCheckForUpdates) as? Bool ?? true
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
