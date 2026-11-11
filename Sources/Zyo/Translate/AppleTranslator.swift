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
final class AppleTranslator: Translating {
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
        let (source, target) = Self.languages(for: direction)
        let pair = Self.pairKey(source, target)
        let session = try await readySession(source: source, target: target, pair: pair)
        let result: String
        do {
            result = try await session.translate(trimmed).targetText
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            // 语言包可能在 session 创建后被删除：丢掉 session，下次重新检查；未安装时改报缺语言包，引导下载
            sessions[pair] = nil
            if await LanguageAvailability().status(from: source, to: target) != .installed {
                throw TranslatorError.languageNotInstalled
            }
            throw error
        }
        cache.insert(result, for: trimmed, pair: pair)
        return result
    }

    /// 中文 ⇄ 该外语两个方向中第一个未下载的语言对，都已下载时返回 nil。
    /// 非拉丁外语的外→中方向回退为英语→中文，可能与中→外不在同一个语言包里
    func missingLanguages(foreign: String) async -> (source: Locale.Language, target: Locale.Language)? {
        let availability = LanguageAvailability()
        for direction in Direction.allCases {
            let (source, target) = Self.languages(for: direction, foreign: foreign)
            if await availability.status(from: source, to: target) != .installed { return (source, target) }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func pairKey(for direction: Direction) -> String {
        let (source, target) = languages(for: direction)
        return pairKey(source, target)
    }

    private static func pairKey(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
    }

    private func readySession(
        source: Locale.Language, target: Locale.Language, pair: String
    ) async throws -> TranslationSession {
        if let session = sessions[pair] { return session }
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
