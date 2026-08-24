//
//  GlanceTheme.swift
//  glance
//
//  Color and type tokens for the notch-native onboarding redesign, lifted
//  directly from the Figma file. Nothing in the rest of the app reads this
//  today — it exists to keep OnboardingStepViews/OnboardingControls from
//  repeating the same hex literals everywhere.
//

import SwiftUI

enum GlanceTheme {
    static let accent = Color(red: 0x34 / 255, green: 0x99 / 255, blue: 0xFF / 255)
    static let surface = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
    static let surfaceRaised = Color(red: 0x32 / 255, green: 0x32 / 255, blue: 0x32 / 255)
    static let panel = Color.black
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0x94 / 255, green: 0x94 / 255, blue: 0x94 / 255)
    static let textDetail = Color(red: 0xBD / 255, green: 0xBD / 255, blue: 0xBD / 255)
    static let placeholder = Color(red: 0x2F / 255, green: 0x2F / 255, blue: 0x2F / 255)
    static let statusGranted = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let statusDenied = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    //Badge colors
    static let badgeGeneral = [Color(red: 0x9C / 255, green: 0x9C / 255, blue: 0xA1 / 255), // top: light grey
                                Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)] // bottom: grey
    static let badgeYourFace = [Color(red: 0x71 / 255, green: 0xD0 / 255, blue: 0xFF / 255), // top: light blue
                                Color(red: 0x25 / 255, green: 0x72 / 255, blue: 0xD0 / 255)]// bottom: blue
    static let badgePassword = [ Color(red: 0x40 / 255, green: 0x4C / 255, blue: 0x52 / 255), // top: dark grey
                                Color(red: 0x12 / 255, green: 0x19 / 255, blue: 0x20 / 255)] // bottom: grey
    static let badgeCamera = [ Color(red: 0x60 / 255, green: 0xE8 / 255, blue: 0x8B / 255), // top: light green
                                Color(red: 0x15 / 255, green: 0xAB / 255, blue: 0x71 / 255)] // bottom: green
    static let badgeRecognition = [Color(red: 0x83 / 255, green: 0x74 / 255, blue: 0xE6 / 255), // top: light purple
                                    Color(red: 0x55 / 255, green: 0x3F / 255, blue: 0xB5 / 255)] // bottom: purple

    enum Font {
        /// Scaled up from a literal Figma-frame halving so content reads
        /// clearly at the wider `OnboardingMetrics.panelWidth`.
        static let title = SwiftUI.Font.system(size: 26, weight: .bold)
        static let button = SwiftUI.Font.system(size: 13, weight: .medium)
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        static let grantLabel = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let rowDetail = SwiftUI.Font.system(size: 11, weight: .regular)
        static let passwordCaption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let passwordPlaceholder = SwiftUI.Font.system(size: 12, weight: .regular)
        static let instruction = SwiftUI.Font.system(size: 15, weight: .medium)
    }
}
