import Testing

@testable import ZyoCore

private struct Failure: Error {}

private let debounce: Duration = .milliseconds(250)
private let timeout: Duration = .seconds(1)

/// 翻译请求挂起，直到测试调用 finish
@MainActor
private final class FakeTranslator: Translating {
    var cache: [String: String] = [:]
    private(set) var requests: [String] = []
    private var pending: [(source: String, continuation: UnsafeContinuation<String, Error>)] = []

    func cachedTranslation(_ text: String, direction: Direction) -> String? { cache[text] }

    func translate(_ text: String, direction: Direction) async throws -> String {
        requests.append(text)
        return try await withUnsafeThrowingContinuation { pending.append((text, $0)) }
    }

    func finish(_ source: String, with result: Result<String, Error>) {
        guard let index = pending.firstIndex(where: { $0.source == source }) else {
            Issue.record("没有「\(source)」的在途请求")
            return
        }
        pending.remove(at: index).continuation.resume(with: result)
    }
}

/// 手动推进的时间：sleep 挂起，直到测试 fire 对应的时长
@MainActor
private final class ManualClock {
    private var sleepers: [(duration: Duration, continuation: UnsafeContinuation<Void, Never>)] = []

    var pending: [Duration] { sleepers.map(\.duration) }

    nonisolated var sleep: TranslationScheduler.Sleep {
        { [self] duration in await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async {
        await withUnsafeContinuation { sleepers.append((duration, $0)) }
    }

    func fire(_ duration: Duration) async {
        let due = sleepers.filter { $0.duration == duration }
        sleepers.removeAll { $0.duration == duration }
        due.forEach { $0.continuation.resume() }
        await settle()
    }
}

/// 让调度器里的 Task 跑到下一个挂起点
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private final class Harness {
    let translator = FakeTranslator()
    let clock = ManualClock()
    let scheduler: TranslationScheduler
    private(set) var results: [(source: String, text: String?, cached: Bool)] = []
    private(set) var timeouts = 0

    init() {
        scheduler = TranslationScheduler(
            translator: translator, debounce: debounce, commitTimeout: timeout, sleep: clock.sleep
        )
        scheduler.onResult = { [unowned self] result, source, cached in
            results.append((source, try? result.get(), cached))
        }
        scheduler.onCommitTimeout = { [unowned self] in timeouts += 1 }
    }

    func request(_ source: String) async {
        scheduler.request(source, direction: .chineseToForeign)
        await settle()
    }

    func waitToCommit(_ source: String, retry: Bool = false) async {
        scheduler.waitToCommit(source, direction: .chineseToForeign, retry: retry)
        await settle()
    }

    func finish(_ source: String, with result: Result<String, Error>) async {
        translator.finish(source, with: result)
        await settle()
    }
}

@MainActor @Test func requestWaitsForDebounce() async {
    let h = Harness()
    await h.request("猫")
    #expect(h.translator.requests.isEmpty)
    await h.clock.fire(debounce)
    #expect(h.translator.requests == ["猫"])
    await h.finish("猫", with: .success("cat"))
    #expect(h.results.map(\.source) == ["猫"])
    #expect(h.results.first?.text == "cat")
    #expect(h.results.first?.cached == false)
}

@MainActor @Test func typingDuringDebounceOnlyTranslatesLatest() async {
    let h = Harness()
    await h.request("猫")
    await h.request("猫咪")
    await h.clock.fire(debounce)
    #expect(h.translator.requests == ["猫咪"])
}

@MainActor @Test func sameSourceIsNotRequestedAgain() async {
    let h = Harness()
    await h.request("猫")
    await h.clock.fire(debounce)
    await h.request("猫")
    #expect(h.clock.pending.isEmpty)
    #expect(h.translator.requests == ["猫"])
}

@MainActor @Test func staleResultIsDiscarded() async {
    let h = Harness()
    await h.request("猫")
    await h.clock.fire(debounce)
    await h.request("猫咪")
    await h.finish("猫", with: .success("cat"))
    #expect(h.results.isEmpty)
    await h.clock.fire(debounce)
    await h.finish("猫咪", with: .success("kitty"))
    #expect(h.results.map(\.source) == ["猫咪"])
}

@MainActor @Test func cacheHitIsDeliveredSynchronously() async {
    let h = Harness()
    h.translator.cache["猫"] = "cat"
    h.scheduler.request("猫", direction: .chineseToForeign)
    #expect(h.results.map(\.text) == ["cat"])
    #expect(h.results.first?.cached == true)
    #expect(h.clock.pending.isEmpty)
    #expect(h.translator.requests.isEmpty)
}

@MainActor @Test func waitToCommitSkipsRemainingDebounce() async {
    let h = Harness()
    await h.request("猫")
    await h.waitToCommit("猫")
    #expect(h.translator.requests == ["猫"])
    #expect(h.scheduler.isWaitingToCommit)
}

@MainActor @Test func waitToCommitDoesNotResendInFlightRequest() async {
    let h = Harness()
    await h.request("猫")
    await h.clock.fire(debounce)
    await h.waitToCommit("猫")
    #expect(h.translator.requests == ["猫"])
    await h.finish("猫", with: .success("cat"))
    #expect(h.results.count == 1)
    #expect(h.scheduler.isWaitingToCommit)
}

@MainActor @Test func retryResendsAfterFailure() async {
    let h = Harness()
    await h.request("猫")
    await h.clock.fire(debounce)
    await h.finish("猫", with: .failure(Failure()))
    #expect(h.results.first?.text == nil)
    await h.waitToCommit("猫", retry: true)
    #expect(h.translator.requests == ["猫", "猫"])
}

@MainActor @Test func commitWaitTimesOut() async {
    let h = Harness()
    await h.waitToCommit("猫")
    await h.clock.fire(timeout)
    #expect(h.timeouts == 1)
    #expect(!h.scheduler.isWaitingToCommit)
}

@MainActor @Test func inputChangeCancelsCommitWait() async {
    let h = Harness()
    await h.waitToCommit("猫")
    await h.request("猫咪")
    #expect(!h.scheduler.isWaitingToCommit)
    await h.clock.fire(timeout)
    #expect(h.timeouts == 0)
}

@MainActor @Test func resetDropsInFlightResult() async {
    let h = Harness()
    await h.request("猫")
    await h.clock.fire(debounce)
    h.scheduler.reset()
    await h.finish("猫", with: .success("cat"))
    #expect(h.results.isEmpty)
    // reset 后同一原文可以重新请求
    await h.request("猫")
    await h.clock.fire(debounce)
    #expect(h.translator.requests == ["猫", "猫"])
}
