import Foundation
import Translation
import ZyoCore

enum TranslatorError: LocalizedError {
    case languageNotInstalled

    var errorDescription: String? {
        switch self {
        case .languageNotInstalled:
            "未下载离线翻译语言包 · 点击这里下载"
        }
    }
}

/// 只使用已下载的离线模型，不弹任何系统界面。外语读自 Preferences.foreignLanguage。
@MainActor
final class AppleTranslator {
    static let shared = AppleTranslator()

    /// key = 语言对，换外语后旧会话保留，切回来可直接复用
    private var sessions: [String: TranslationSession] = [:]
    private var cache = TranslationCache()

    func cachedTranslation(_ text: String, direction: Direction) -> String? {
        cache.value(for: Self.normalized(text), pair: Self.pairKey(for: direction))
    }

    func translate(_ text: String, direction: Direction) async throws -> String {
        let trimmed = Self.normalized(text)
        guard !trimmed.isEmpty else { return "" }
        let pair = Self.pairKey(for: direction)
        let session = try await readySession(for: direction, pair: pair)
        let result = try await session.translate(trimmed).targetText
        cache.insert(result, for: trimmed, pair: pair)
        return result
    }

    /// 中文 ⇄ 该外语两个方向都已下载才算可用
    func languagesInstalled(foreign: String) async -> Bool {
        let availability = LanguageAvailability()
        for direction in Direction.allCases {
            let (source, target) = Self.languages(for: direction, foreign: foreign)
            guard await availability.status(from: source, to: target) == .installed else { return false }
        }
        return true
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func pairKey(for direction: Direction) -> String {
        let (source, target) = languages(for: direction)
        return "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
    }

    private func readySession(for direction: Direction, pair: String) async throws -> TranslationSession {
        if let session = sessions[pair] { return session }
        let (source, target) = Self.languages(for: direction)
        // 未安装时每次都重新检查，用户装好语言包后无需重启输入法
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { throw TranslatorError.languageNotInstalled }
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        sessions[pair] = session
        return session
    }

    static func languages(
        for direction: Direction,
        foreign: String = Preferences.foreignLanguage
    ) -> (Locale.Language, Locale.Language) {
        let chinese = Locale.Language(identifier: "zh-Hans")
        return switch direction {
        case .chineseToForeign: (chinese, Locale.Language(identifier: foreign))
        case .foreignToChinese: (Locale.Language(identifier: Preferences.inputLanguage(for: foreign)), chinese)
        }
    }
}
