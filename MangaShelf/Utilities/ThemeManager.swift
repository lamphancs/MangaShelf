//
//  ThemeManager.swift
//  MangaShelf
//

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case warmBrown
    case midnight
    case oledBlack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: "Dark"
        case .warmBrown: "Warm Brown"
        case .midnight: "Midnight"
        case .oledBlack: "OLED Black"
        }
    }

    var libraryBackground: Color {
        switch self {
        case .dark: Color(red: 0.08, green: 0.08, blue: 0.08)
        case .warmBrown: Color(red: 0.11, green: 0.10, blue: 0.08)
        case .midnight: Color(red: 0.05, green: 0.07, blue: 0.14)
        case .oledBlack: Color.black
        }
    }

    var cardBackground: Color {
        switch self {
        case .dark: Color(red: 0.14, green: 0.14, blue: 0.14)
        case .warmBrown: Color(red: 0.18, green: 0.16, blue: 0.14)
        case .midnight: Color(red: 0.10, green: 0.12, blue: 0.20)
        case .oledBlack: Color(red: 0.10, green: 0.10, blue: 0.10)
        }
    }

    var cardBorder: Color {
        switch self {
        case .dark: Color(white: 0.22)
        case .warmBrown: Color(red: 0.28, green: 0.25, blue: 0.21)
        case .midnight: Color(red: 0.16, green: 0.18, blue: 0.30)
        case .oledBlack: Color(white: 0.15)
        }
    }
}

enum AccentTheme: String, CaseIterable, Identifiable {
    case blue
    case red
    case purple
    case teal
    case orange
    case green

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: "Blue"
        case .red: "Red"
        case .purple: "Purple"
        case .teal: "Teal"
        case .orange: "Orange"
        case .green: "Green"
        }
    }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.0, green: 0.48, blue: 1.0)
        case .red: Color(red: 0.93, green: 0.26, blue: 0.26)
        case .purple: Color(red: 0.62, green: 0.32, blue: 0.88)
        case .teal: Color(red: 0.0, green: 0.75, blue: 0.72)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.0)
        case .green: Color(red: 0.30, green: 0.78, blue: 0.35)
        }
    }
}

@Observable
class ThemeManager {

    var selectedTheme: AppTheme {
        didSet { UserDefaults.standard.set(selectedTheme.rawValue, forKey: StorageKey.appTheme) }
    }

    var selectedAccent: AccentTheme {
        didSet { UserDefaults.standard.set(selectedAccent.rawValue, forKey: StorageKey.accentTheme) }
    }

    var libraryBackground: Color { selectedTheme.libraryBackground }
    var cardBackground: Color { selectedTheme.cardBackground }
    var cardBorder: Color { selectedTheme.cardBorder }
    var accent: Color { selectedAccent.color }

    init() {
        let themeRaw = UserDefaults.standard.string(forKey: StorageKey.appTheme) ?? AppTheme.warmBrown.rawValue
        selectedTheme = AppTheme(rawValue: themeRaw) ?? .warmBrown

        let accentRaw = UserDefaults.standard.string(forKey: StorageKey.accentTheme) ?? AccentTheme.blue.rawValue
        selectedAccent = AccentTheme(rawValue: accentRaw) ?? .blue
    }
}
