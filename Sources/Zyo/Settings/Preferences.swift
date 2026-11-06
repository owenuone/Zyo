import Foundation
import ZyoCore

struct PinyinScheme {
    let id: String
    let name: String
}

enum Preferences {
    /// 第一个为默认方案
    static let schemes: [PinyinScheme] = [
        PinyinScheme(id: "rime_ice", name: "全拼"),
        PinyinScheme(id: "double_pinyin_flypy", name: "小鹤双拼"),
        PinyinScheme(id: "double_pinyin_mspy", name: "微软双拼"),
        PinyinScheme(id: "double_pinyin", name: "自然码双拼"),
        PinyinScheme(id: "wubi86_jidian", name: "五笔 86"),
        PinyinScheme(id: "wubi98", name: "五笔 98"),
        PinyinScheme(id: "wubi06", name: "新世纪五笔"),
    ]

    /// 列表来自 macOS 27 的 LanguageAvailability().supportedLanguages（2026-10-27 核对）
    static let latinLanguages = ["en", "de", "fr", "es", "it", "pt", "nl", "pl", "tr", "id", "vi"]
    /// 键盘打不出这些语言的原文，所以只支持中文→外语；外语→中文方向回退为英语→中文
    static let nonLatinLanguages = ["ja", "ko", "ru", "uk", "ar", "th", "hi"]
    static let foreignLanguages = latinLanguages + nonLatinLanguages

    private static let schemeKey = "pinyinScheme"
    private static let foreignLanguageKey = "foreignLanguage"
    private static let buffersSentenceKey = "buffersSentence"
    private static let dictionaryUpdatedAtKey = "dictionaryUpdatedAt"
    private static let dictionaryDigestKey = "dictionaryDigest"
    private static let dictionaryLastCheckKey = "dictionaryLastCheck"

    /// 已下载词典的版本（nightly 资源的更新时间）；nil 表示使用 App 自带词典
    static var dictionaryUpdatedAt: Date? {
        get { UserDefaults.standard.object(forKey: dictionaryUpdatedAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: dictionaryUpdatedAtKey) }
    }

    static var dictionaryDigest: String? {
        get { UserDefaults.standard.string(forKey: dictionaryDigestKey) }
        set { UserDefaults.standard.set(newValue, forKey: dictionaryDigestKey) }
    }

    static var dictionaryLastCheck: Date? {
        get { UserDefaults.standard.object(forKey: dictionaryLastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: dictionaryLastCheckKey) }
    }

    /// 选词后先攒成整句再上屏，默认开启
    static var buffersSentence: Bool {
        get { UserDefaults.standard.object(forKey: buffersSentenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: buffersSentenceKey) }
    }

    static var foreignLanguage: String {
        get {
            let stored = UserDefaults.standard.string(forKey: foreignLanguageKey)
            return foreignLanguages.contains { $0 == stored } ? stored! : foreignLanguages[0]
        }
        set { UserDefaults.standard.set(newValue, forKey: foreignLanguageKey) }
    }

    /// 外语→中文方向实际使用的源语言
    static func inputLanguage(for foreign: String) -> String {
        latinLanguages.contains(foreign) ? foreign : "en"
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? code
    }

    static var schemeID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: schemeKey)
            return schemes.contains { $0.id == stored } ? stored! : schemes[0].id
        }
        set { UserDefaults.standard.set(newValue, forKey: schemeKey) }
    }
}

extension Direction {
    var label: String {
        let foreign = Preferences.foreignLanguage
        return switch self {
        case .chineseToForeign: "中文 → \(Preferences.languageName(foreign))"
        case .foreignToChinese: "\(Preferences.languageName(Preferences.inputLanguage(for: foreign))) → 中文"
        }
    }
}
