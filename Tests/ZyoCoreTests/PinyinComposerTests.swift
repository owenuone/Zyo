import Testing

@testable import ZyoCore

/// 模拟 rime：字母追加到输入，空格选中高亮候选并上屏，Esc 清空。
@MainActor
private final class FakeEngine: ConversionEngine {
    var state = EngineState()
    var pages: [[String]] = [["选中", "旋转", "选址"], ["宣战", "悬钟"]]
    private var page = 0
    private var input = ""
    private var commit: String?
    /// 模拟重新部署清掉了 session：之后按键都不处理，输入状态丢失
    var sessionLost = false

    func process(_ key: Key) -> Bool {
        if sessionLost {
            clear()
            return false
        }
        switch key {
        case let .character(c) where c.isLetter:
            input.append(c)
        case .character("，"), .character(","):
            guard !state.isComposing else { return true }
            commit = "，"
            return true
        case .space:
            guard state.isComposing else { return false }
            commit = state.confirmedText + state.candidates[state.highlightedIndex]
            clear()
            return true
        case .escape, .backspace:
            guard state.isComposing else { return false }
            clear()
            return true
        default:
            return false
        }
        refresh()
        return true
    }

    func takeCommit() -> String? {
        defer { commit = nil }
        return commit
    }

    func selectCandidate(at index: Int) {
        state.highlightedIndex = index
        _ = process(.space)
    }

    func highlightCandidate(at index: Int) {
        state.highlightedIndex = index
    }

    func changePage(backward: Bool) {
        page = max(0, min(pages.count - 1, page + (backward ? -1 : 1)))
        refresh()
    }

    func commitComposition() -> String? {
        defer { clear() }
        return state.preedit
    }

    func clear() {
        input = ""
        page = 0
        state = EngineState()
    }

    /// 模拟部分确认：已确认「当前」，剩余拼音继续转换
    func confirmPrefix(_ text: String) {
        state.confirmedText = text
        state.preedit = text + input
    }

    private func refresh() {
        state.rawInput = input
        state.preedit = state.confirmedText + input
        state.candidates = input.isEmpty ? [] : pages[page]
        state.isLastPage = page == pages.count - 1
    }
}

@MainActor
private func makeComposer(typing input: String, buffersSentence: Bool = false) -> (Composer, FakeEngine) {
    let engine = FakeEngine()
    var composer = Composer(engine: engine, buffersSentence: buffersSentence)
    for c in input { _ = composer.handle(.character(c)) }
    return (composer, engine)
}

@Test @MainActor func directionFollowsEngine() {
    #expect(Composer().direction == .foreignToChinese)
    #expect(Composer(engine: FakeEngine()).direction == .chineseToForeign)
}

@Test @MainActor func idleKeysGoToEngineOrPassThrough() {
    var composer = Composer(engine: FakeEngine())
    #expect(composer.handle(.space) == .passThrough)
    #expect(composer.handle(.down) == .passThrough)
    #expect(composer.handle(.character(",")) == .commit("，"))
}

@Test @MainActor func lostSessionCancelsComposition() {
    var (composer, engine) = makeComposer(typing: "xrvs")
    engine.sessionLost = true
    #expect(composer.handle(.backspace) == .cancel)
    #expect(!composer.isComposing)
}

@Test @MainActor func pendingTextIsConfirmedPlusHighlighted() {
    var (composer, engine) = makeComposer(typing: "xrvs")
    #expect(composer.pendingText == "选中")
    engine.confirmPrefix("当前")
    #expect(composer.pendingText == "当前选中")
    #expect(composer.handle(.right) == .update)
    #expect(composer.highlightedIndex == 1)
    #expect(composer.pendingText == "当前旋转")
}

@Test @MainActor func highlightCrossesPages() {
    var (composer, _) = makeComposer(typing: "xr")
    _ = composer.handle(.right)
    _ = composer.handle(.right)
    _ = composer.handle(.right)
    #expect(composer.candidates == ["宣战", "悬钟"])
    #expect(composer.highlightedIndex == 0)
    _ = composer.handle(.right)
    _ = composer.handle(.right)
    #expect(composer.highlightedIndex == 1)
    _ = composer.handle(.left)
    _ = composer.handle(.left)
    #expect(composer.candidates == ["选中", "旋转", "选址"])
    #expect(composer.highlightedIndex == 2)
}

@Test @MainActor func spaceCommitsCandidateFromCandidateRow() {
    var (composer, _) = makeComposer(typing: "xrvs")
    #expect(composer.handle(.space) == .commit("选中"))
}

@Test @MainActor func translationRowInPinyinMode() {
    var (composer, _) = makeComposer(typing: "xrvs")
    #expect(composer.handle(.tab) == .update)
    #expect(composer.focus == .translation)
    #expect(composer.handle(.space) == .commitTranslation)
    #expect(composer.handle(.enter) == .commitTranslation)
    #expect(composer.handle(.escape) == .update)
    #expect(composer.focus == .candidates)
}

@Test @MainActor func typingFromTranslationRowReturnsToCandidates() {
    var (composer, _) = makeComposer(typing: "xr")
    _ = composer.handle(.down)
    #expect(composer.handle(.character("v")) == .update)
    #expect(composer.focus == .candidates)
    #expect(composer.markedText == "xrv")
}

@Test @MainActor func escapeClearsComposition() {
    var (composer, _) = makeComposer(typing: "xr")
    #expect(composer.handle(.escape) == .cancel)
    #expect(!composer.isComposing)
}

@Test @MainActor func mouseSelectCommits() {
    var (composer, _) = makeComposer(typing: "xr")
    #expect(composer.selectCandidate(at: 2) == .commit("选址"))
}

@Test @MainActor func staleTranslationDiscardedAfterHighlightChange() {
    var (composer, _) = makeComposer(typing: "xr")
    composer.applyTranslation("select", for: "选中")
    #expect(composer.freshTranslation == "select")
    _ = composer.handle(.right)
    #expect(composer.freshTranslation == nil)
    composer.applyTranslation("select", for: "选中")
    #expect(composer.freshTranslation == nil)
}

@Test @MainActor func rawInputIsTypedKeys() {
    let (composer, _) = makeComposer(typing: "hello")
    #expect(composer.rawInput == "hello")
    var english = Composer()
    _ = english.handle(.character("h"))
    _ = english.handle(.character("i"))
    #expect(english.rawInput == "hi")
}

// MARK: 句子缓冲

@MainActor
private func type(_ input: String, into composer: inout Composer) {
    for c in input { _ = composer.handle(.character(c)) }
}

@Test @MainActor func bufferedSelectionDoesNotCommit() {
    var (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    #expect(composer.handle(.space) == .update)
    #expect(composer.isComposing)
    #expect(composer.markedText == "选中")
    #expect(composer.candidates == ["选中"])
    #expect(composer.pendingText == "选中")

    type("xr", into: &composer)
    _ = composer.handle(.right)
    #expect(composer.markedText == "选中xr")
    #expect(composer.pendingText == "选中旋转")
    #expect(composer.selectCandidate(at: 1) == .update)
    #expect(composer.markedText == "选中旋转")
}

@Test @MainActor func bufferedSentenceCommitsWithSpaceOrEnter() {
    var (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    #expect(composer.handle(.space) == .commit("选中"))

    (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    #expect(composer.handle(.enter) == .commit("选中"))

    (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    #expect(composer.selectCandidate(at: 0) == .commit("选中"))
}

@Test @MainActor func enterCommitsPendingText() {
    var (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    type("xr", into: &composer)
    _ = composer.handle(.right)
    #expect(composer.handle(.enter) == .commit("选中旋转"))
    #expect(!composer.isComposing)

    (composer, _) = makeComposer(typing: "xr")
    #expect(composer.handle(.enter) == .commit("选中"))
}

@Test @MainActor func bufferedSentenceEditing() {
    var (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    #expect(composer.handle(.character("，")) == .update)
    #expect(composer.handle(.character("1")) == .update)
    #expect(composer.markedText == "选中，1")
    _ = composer.handle(.backspace)
    _ = composer.handle(.backspace)
    #expect(composer.markedText == "选中")
    _ = composer.handle(.backspace)
    #expect(composer.handle(.backspace) == .cancel)
    #expect(!composer.isComposing)
}

@Test @MainActor func idlePunctuationStillCommitsDirectly() {
    var (composer, _) = makeComposer(typing: "", buffersSentence: true)
    #expect(composer.handle(.character("，")) == .commit("，"))
}

@Test @MainActor func bufferedSentenceTranslationRowAndEscape() {
    var (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    _ = composer.handle(.down)
    #expect(composer.focus == .translation)
    #expect(composer.handle(.enter) == .commitTranslation)
    _ = composer.handle(.escape)
    #expect(composer.focus == .candidates)
    #expect(composer.handle(.escape) == .cancel)
    #expect(!composer.isComposing)
}

@Test @MainActor func forceCommitIncludesSentence() {
    var (composer, _) = makeComposer(typing: "xr", buffersSentence: true)
    _ = composer.handle(.space)
    type("xr", into: &composer)
    #expect(composer.rawInput == "选中xr")
    #expect(composer.forceCommitText() == "选中xr")
}

@Test @MainActor func translationRowWithoutCandidatesDoesNotCommit() {
    let engine = FakeEngine()
    engine.pages = [[]]
    var composer = Composer(engine: engine)
    type("xr", into: &composer)
    #expect(composer.isComposing)
    #expect(composer.pendingText.isEmpty)
    _ = composer.handle(.down)
    #expect(composer.handle(.enter) == .update)
    #expect(composer.handle(.space) == .update)
    #expect(composer.isComposing)
}
