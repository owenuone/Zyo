/// 译文 LRU 缓存，key = 语言对（如 "zh-Hans>fr"）+ 原文。容量只有几百条，用数组维护访问顺序足够，不必上双向链表。
public struct TranslationCache: Sendable {
    private struct Key: Hashable {
        let pair: String
        let text: String
    }

    public let capacity: Int
    private var storage: [Key: String] = [:]
    /// 最久未使用的在最前
    private var order: [Key] = []

    public init(capacity: Int = 500) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    public mutating func value(for text: String, pair: String) -> String? {
        let key = Key(pair: pair, text: text)
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func insert(_ translation: String, for text: String, pair: String) {
        let key = Key(pair: pair, text: text)
        if storage.updateValue(translation, forKey: key) != nil {
            touch(key)
            return
        }
        order.append(key)
        if order.count > capacity {
            storage[order.removeFirst()] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}
