import SwiftUI

/// The voz dark + single-electric-blue palette for the Insights window (from brand/tokens.md).
/// One accent only — surfaces and charts differentiate by depth/opacity, never a second hue.
enum VozTheme {
    static let black = Color(red: 0x07 / 255.0, green: 0x08 / 255.0, blue: 0x0C / 255.0) // backdrop
    static let ink = Color(red: 0x16 / 255.0, green: 0x15 / 255.0, blue: 0x20 / 255.0)   // raised surface (cards)
    static let line = Color(red: 0x2A / 255.0, green: 0x28 / 255.0, blue: 0x33 / 255.0)   // hairline
    static let electric = Color(red: 0x2E / 255.0, green: 0x74 / 255.0, blue: 0xFF / 255.0) // the accent
    static let electricBright = Color(red: 0x3C / 255.0, green: 0xC6 / 255.0, blue: 0xFF / 255.0) // crest (sparing)
    static let mist = Color(red: 0x8B / 255.0, green: 0x87 / 255.0, blue: 0x94 / 255.0)   // secondary text
    static let textHi = Color(red: 0.93, green: 0.94, blue: 0.96)                         // primary text
}
