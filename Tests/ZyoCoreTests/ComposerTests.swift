import Testing

@testable import ZyoCore

@MainActor
private func type(_ text: String, into composer: inout Composer) {
    for c in text {
        _ = composer.handle(c == " " ? .space : .character(c))
    }
}

@Test @MainActor func nonLetterPassesThroughWhenIdle() {
    var composer = Composer()
    #expect(composer.handle(.character("1")) == .passThrough)
    #expect(composer.handle(.space) == .passThrough)
    #expect(composer.handle(.enter) == .passThrough)
    #expect(!composer.isComposing)
}

@Test @MainActor func typingBuildsPendingText() {
    var composer = Composer()
    type("hello world", into: &composer)
    #expect(composer.markedText == "hello world")
    #expect(composer.candidates == ["hello world"])
    #expect(composer.pendingText == "hello world")
}

@Test @MainActor func enterCommitsRawInputFromCandidateRow() {
    var composer = Composer()
    type("hi", into: &composer)
    #expect(composer.handle(.enter) == .commit("hi"))
}

@Test @MainActor func translationRowCommitsTranslation() {
    var composer = Composer()
    type("hi", into: &composer)
    #expect(composer.handle(.down) == .update)
    #expect(composer.focus == .translation)
    #expect(composer.handle(.space) == .commitTranslation)
    #expect(composer.handle(.enter) == .commitTranslation)
}

@Test @MainActor func escapeLeavesTranslationRowThenCancels() {
    var composer = Composer()
    type("hi", into: &composer)
    _ = composer.handle(.tab)
    #expect(composer.handle(.escape) == .update)
    #expect(composer.focus == .candidates)
    #expect(composer.handle(.escape) == .cancel)
    #expect(!composer.isComposing)
}

@Test @MainActor func backspaceToEmptyCancels() {
    var composer = Composer()
    type("ab", into: &composer)
    _ = composer.handle(.down)
    #expect(composer.handle(.backspace) == .update)
    #expect(composer.focus == .candidates)
    #expect(composer.handle(.backspace) == .cancel)
    #expect(!composer.isComposing)
}

@Test @MainActor func staleTranslationIsDiscarded() {
    var composer = Composer()
    type("cat", into: &composer)
    composer.applyTranslation("猫", for: "ca")
    #expect(composer.freshTranslation == nil)
    composer.applyTranslation("猫", for: "cat")
    #expect(composer.freshTranslation == "猫")
}

@Test @MainActor func translationBecomesStaleWhenInputChanges() {
    var composer = Composer()
    type("cat", into: &composer)
    composer.applyTranslation("猫", for: "cat")
    type("s", into: &composer)
    #expect(composer.freshTranslation == nil)
    #expect(composer.translation == .done(source: "cat", text: "猫"))
}

@Test @MainActor func selectCandidateCommits() {
    var composer = Composer()
    type("ok", into: &composer)
    #expect(composer.selectCandidate(at: 0) == .commit("ok"))
    #expect(composer.selectCandidate(at: 3) == .update)
}
