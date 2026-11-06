import Testing

@testable import ZyoCore

@Test func cacheHitAndMiss() {
    var cache = TranslationCache(capacity: 2)
    #expect(cache.value(for: "猫", pair: "zh>en") == nil)
    cache.insert("cat", for: "猫", pair: "zh>en")
    #expect(cache.value(for: "猫", pair: "zh>en") == "cat")
}

@Test func cacheKeyIncludesLanguagePair() {
    var cache = TranslationCache()
    cache.insert("cat", for: "猫", pair: "zh>en")
    #expect(cache.value(for: "猫", pair: "en>zh") == nil)
}

@Test func cacheEvictsLeastRecentlyUsed() {
    var cache = TranslationCache(capacity: 2)
    cache.insert("a", for: "1", pair: "zh>en")
    cache.insert("b", for: "2", pair: "zh>en")
    _ = cache.value(for: "1", pair: "zh>en")
    cache.insert("c", for: "3", pair: "zh>en")
    #expect(cache.count == 2)
    #expect(cache.value(for: "1", pair: "zh>en") == "a")
    #expect(cache.value(for: "2", pair: "zh>en") == nil)
    #expect(cache.value(for: "3", pair: "zh>en") == "c")
}

@Test func cacheUpdateRefreshesRecency() {
    var cache = TranslationCache(capacity: 2)
    cache.insert("a", for: "1", pair: "zh>en")
    cache.insert("b", for: "2", pair: "zh>en")
    cache.insert("a2", for: "1", pair: "zh>en")
    cache.insert("c", for: "3", pair: "zh>en")
    #expect(cache.count == 2)
    #expect(cache.value(for: "1", pair: "zh>en") == "a2")
    #expect(cache.value(for: "2", pair: "zh>en") == nil)
}

@Test func cacheSeparatesForeignLanguages() {
    var cache = TranslationCache()
    cache.insert("cat", for: "猫", pair: "zh>en")
    #expect(cache.value(for: "猫", pair: "zh>fr") == nil)
}
