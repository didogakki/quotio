//
//  MenuBarPalette.swift
//  QuotioPresentation
//
//  Design tokens for the A4 menu-bar dropdown pass (docs/handoff/menubar-weight-a4):
//  green/amber/coral quota-state colors, and the indigo/teal/pink/sky channel-weight
//  palette. Defined here rather than in Assets.xcassets because this package cannot
//  reliably reference the app target's asset catalog; colors are still dynamic
//  (`NSColor(name:dynamicProvider:)`) so light/dark appearance both resolve correctly.
//

import AppKit
import SwiftUI

enum MenuBarPalette {
    // MARK: Quota status colors (replace the old green/yellow-or-orange/red trio)

    static let quotaNormal = Color.green
    static let quotaWarning = dynamic(light: "B86E00", dark: "FFB340")
    static let quotaDanger = dynamic(light: "D8392B", dark: "FF6B5E")

    // MARK: Channel-weight palette

    private static let channelIndigo = dynamic(light: "5856D6", dark: "8E8CFF")
    private static let channelTeal = dynamic(light: "0B7A70", dark: "3FD0C0")
    private static let channelPink = dynamic(light: "C2255C", dark: "FF8FB1")
    private static let channelSky = dynamic(light: "0071A4", dark: "64D2FF")

    /// Cyclic assignment order for successive multi-account groups within one
    /// provider — indigo, teal, pink, sky, then repeating.
    private static let channelColors: [Color] = [channelIndigo, channelTeal, channelPink, channelSky]

    static func channelColor(at index: Int) -> Color {
        channelColors[index % channelColors.count]
    }

    /// `WeightDistributionBar` segment number color on a dark-appearance fill — fixed
    /// rather than dynamic, since the fill itself already carries the light/dark split.
    static let segmentDarkText = Color(hex: "16161A") ?? .black

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light) ?? .primary)
        }))
    }
}
