import Foundation

/// 翻译后端；实际使用的是 Apple 离线翻译（AppleTranslator），测试里换成假的
@MainActor
public protocol Translating: AnyObject, Sendable {
    func cachedTranslation(_ text: String, direction: Direction) -> String?
    func translate(_ text: String, direction: Direction) async throws -> String
}

/// 翻译调度：缓存命中立即给结果，否则防抖后请求；原文变了取消在途请求、丢弃过期结果；
/// 要上屏译文但还没就绪时跳过剩余防抖，等结果回来，超时则放弃。结果写入 Composer 由调用方负责
@MainActor
public final class TranslationScheduler {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// 翻译结果。`cached` 为 true 时是在 `request` / `waitToCommit` 里同步给出的，调用方之后会自己渲染
    public var onResult: ((_ result: Result<String, Error>, _ source: String, _ cached: Bool) -> Void)?
    /// 等译文上屏超时
    public var onCommitTimeout: (() -> Void)?

    /// 译文回来时调用方应直接上屏
    public private(set) var isWaitingToCommit = false

    private let translator: any Translating
    private let debounce: Duration
    private let commitTimeout: Duration
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var requestedSource: String?
    /// 当前请求还在防抖等待中，尚未发给翻译后端
    private var debouncing = false
    private var commitTimeoutTask: Task<Void, Never>?

    public init(
        translator: any Translating,
        debounce: Duration = .milliseconds(250),
        commitTimeout: Duration = .seconds(1),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.translator = translator
        self.debounce = debounce
        self.commitTimeout = commitTimeout
        self.sleep = sleep
    }

    /// 输入变化后调用；同一原文已在请求中就不重发
    public func request(_ source: String, direction: Direction) {
        // 等译文期间输入变了，不能把新输入的译文自动上屏
        if source != requestedSource { cancelCommitWait() }
        schedule(source, direction: direction, immediate: false)
    }

    /// 要上屏译文但还没就绪：立即请求，结果回来时 `isWaitingToCommit` 为 true。
    /// `retry` 时即使同一原文也重新请求（上次失败了）
    public func waitToCommit(_ source: String, direction: Direction, retry: Bool) {
        if retry { requestedSource = nil }
        isWaitingToCommit = true
        commitTimeoutTask?.cancel()
        commitTimeoutTask = Task { [weak self, sleep, commitTimeout] in
            try? await sleep(commitTimeout)
            guard !Task.isCancelled, let self, self.isWaitingToCommit else { return }
            self.isWaitingToCommit = false
            self.onCommitTimeout?()
        }
        schedule(source, direction: direction, immediate: true)
    }

    public func cancelCommitWait() {
        isWaitingToCommit = false
        commitTimeoutTask?.cancel()
        commitTimeoutTask = nil
    }

    public func reset() {
        task?.cancel()
        task = nil
        requestedSource = nil
        debouncing = false
        cancelCommitWait()
    }

    private func schedule(_ source: String, direction: Direction, immediate: Bool) {
        // 要立即提交时不能再等剩下的防抖时间
        guard source != requestedSource || (immediate && debouncing) else { return }
        requestedSource = source
        task?.cancel()
        debouncing = !immediate
        if let cached = translator.cachedTranslation(source, direction: direction) {
            task = nil
            debouncing = false
            onResult?(.success(cached), source, true)
            return
        }
        task = Task { [weak self, translator, debounce, sleep] in
            if !immediate {
                try? await sleep(debounce)
                guard !Task.isCancelled else { return }
                self?.debouncing = false
            }
            let result: Result<String, Error>
            do {
                result = .success(try await translator.translate(source, direction: direction))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.onResult?(result, source, false)
        }
    }
}
