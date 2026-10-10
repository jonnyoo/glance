//
//  RelockPolicy.swift
//  glance
//
//  Defines conditions under which an unlocked app should relock.
//

import Foundation

/// Defines conditions under which an unlocked app should relock.
public enum RelockPolicy: Codable, Equatable, Sendable, Hashable {
    /// Relocks immediately when the app loses focus.
    case everyTime
    /// Relocks N minutes after authentication regardless of focus.
    case afterMinutes(Int)
    /// Relocks N minutes after losing focus; returning before resets the timer.
    case afterFocusLossMinutes(Int)

    public var title: String {
        switch self {
        case .everyTime:
            return "Every time"
        case .afterMinutes(let mins):
            return "After \(mins) minute\(mins == 1 ? "" : "s")"
        case .afterFocusLossMinutes(let mins):
            return "After \(mins) min of inactivity"
        }
    }

    public var shortTitle: String {
        switch self {
        case .everyTime:
            return "Every time"
        case .afterMinutes(let mins):
            return "After \(mins)m"
        case .afterFocusLossMinutes(let mins):
            return "After \(mins)m away"
        }
    }
}
