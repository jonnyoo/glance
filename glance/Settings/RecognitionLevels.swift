//
//  RecognitionLevels.swift
//  glance
//
//  The named stops behind Settings > Recognition's sliders. Kept out of
//  `RecognitionSettingsPage` so `GlanceSettings` can take its fresh-install
//  defaults straight from `.standard` — two copies of these numbers drifted
//  apart twice — and so `tools/recognition_levels_selftest.swift` can
//  compile them without SwiftUI.
//

import Foundation

/// The three selectable points on the "Match confidence" slider — named
/// rather than exposing the raw cosine-similarity threshold directly.
enum MatchConfidenceLevel: Int, CaseIterable {
    case lessStrict, standard, moreStrict

    var title: String {
        switch self {
        case .lessStrict: return "Less strict"
        case .standard: return "Default"
        case .moreStrict: return "More strict"
        }
    }

    var threshold: Float {
        switch self {
        case .lessStrict: return 0.58
        // 0.66, not d0d2cf2's 0.63: every install that never moved this
        // slider has matched at 0.66 since 0acf68b, and `GlanceSettings`
        // now reads its default from here, so a lower stop would silently
        // loosen the unlock gate for all of them.
        case .standard: return 0.66
        case .moreStrict: return 0.68
        }
    }

    /// Position in `allCases` — same role as `AutoLockInterval.sliderIndex`.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    /// Display only: the stored threshold stays in force whatever this
    /// returns. Known gap: an install that picked Default under d0d2cf2
    /// stored 0.63, which snaps here to Default (0.66) while 0.63 is still
    /// enforced, and re-picking Default writes nothing because the slider
    /// index does not change. Moving off Default and back stores 0.66.
    /// Stored values are deliberately never rewritten behind the user.
    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .standard
    }
}

/// The three selectable points on the "Detection distance" slider.
enum DetectionDistanceLevel: Int, CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "Close"
        case .standard: return "Default"
        case .far: return "Far"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.23
        case .standard: return 0.19
        case .far: return 0.15
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }
}
