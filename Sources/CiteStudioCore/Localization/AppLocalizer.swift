import Combine
import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public static func parse(_ raw: String?) -> AppLanguage? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else { return nil }
        if token == "中文" || token == "cn" || token.hasPrefix("zh") {
            return .zhHans
        }
        if token.hasPrefix("en") {
            return .en
        }
        return nil
    }

    public static func parseCLIArguments(_ arguments: [String]) -> AppLanguage? {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--lang", idx + 1 < arguments.count {
                if let parsed = parse(arguments[idx + 1]) {
                    return parsed
                }
            } else if arg.hasPrefix("--lang=") {
                let value = String(arg.dropFirst("--lang=".count))
                if let parsed = parse(value) {
                    return parsed
                }
            }
        }
        return nil
    }
}

@MainActor
public final class AppLocalizer: ObservableObject {
    public nonisolated static let bundleLanguageKey = "io.github.zxu756.CiteStudio.language"
    public static let shared = AppLocalizer()

    @Published public private(set) var language: AppLanguage

    private let userDefaults: UserDefaults?
    private let defaultsKey: String

    public init(
        arguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.language = Self.resolveLanguage(
            arguments: arguments,
            userDefaults: userDefaults,
            preferredLanguages: preferredLanguages,
            defaultsKey: defaultsKey
        )
    }

    public init(
        language: AppLanguage,
        userDefaults: UserDefaults? = nil,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.language = language
    }

    public nonisolated static func resolveLanguage(
        arguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) -> AppLanguage {
        if let cliLang = AppLanguage.parseCLIArguments(arguments) {
            return cliLang
        }
        if let stored = userDefaults.string(forKey: defaultsKey),
           let parsed = AppLanguage.parse(stored) {
            return parsed
        }
        if let firstLocale = preferredLanguages.first,
           firstLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zh") {
            return .zhHans
        }
        return .en
    }

    public var isChinese: Bool {
        language == .zhHans
    }

    public func L(_ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
        userDefaults?.set(newLanguage.rawValue, forKey: defaultsKey)
    }

    public func toggle() {
        setLanguage(language == .zhHans ? .en : .zhHans)
    }
}

public struct CiteStudioLanguageTogglePill: View {
    @ObservedObject var localizer: AppLocalizer

    public init(localizer: AppLocalizer) {
        self.localizer = localizer
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(AppLanguage.allCases) { item in
                let active = localizer.language == item
                Button(action: { localizer.setLanguage(item) }) {
                    Text(item.badge)
                        .font(.system(size: 11, weight: active ? .semibold : .medium))
                        .tracking(0)
                        .foregroundStyle(active ? CiteStudioTheme.oxfordNavy : CiteStudioTheme.marginaliaGrey)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 4)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? CiteStudioTheme.manuscriptSheet : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(active ? CiteStudioTheme.oxfordNavy.opacity(0.42) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(CiteStudioTheme.folioRail)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(CiteStudioTheme.spineRule, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help("切换语言 / Toggle Language (⇧⌘L)")
    }
}
