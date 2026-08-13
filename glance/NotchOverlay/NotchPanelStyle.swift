//
//  NotchPanelStyle.swift
//  glance
//
//  Which silhouette the overlay panel wears on a given screen. Displays with
//  a real notch get `.notch` — the inverted-corner shape welded to the top
//  edge, sitting on top of the physical hardware. Everything else (external
//  monitors, non-notched MacBooks) gets `.pill`: a detached dynamic-island
//  style pill that slides in from off-screen and expands into a floating
//  rounded rectangle, since drawing a fake notch where there is no notch
//  reads as a glitch.
//
//  Derived once per screen from `NotchGeometry.isPhysicalNotch` and passed
//  down through the environment so onboarding's step views can adapt their
//  insets without every one of them taking a parameter.
//

import SwiftUI

enum NotchPanelStyle {
    /// Inverted top corners, flush with the screen's top edge.
    case notch
    /// Fully-rounded pill / floating rounded rectangle, detached from the edge.
    case pill
}

extension EnvironmentValues {
    @Entry var notchPanelStyle: NotchPanelStyle = .notch
}
