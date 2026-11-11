import AppKit
import InputMethodKit
import ZyoCore

/// IMKit 在主线程回调，但 SDK 未标注 actor 隔离，所以覆写方法标 nonisolated 再断言回主线程。
@MainActor
@objc(ZyoInputController)
final class InputController: IMKInputController {
    private static let debounce: Duration = .milliseconds(250)
    private static let commitWaitTimeout: Duration = .seconds(1)
    private static let notFound = NSRange(location: NSNotFound, length: 0)

    private lazy var rimeEngine = RimeEngine()
    private lazy var composer = makeComposer(for: Self.direction)
    private var translationTask: Task<Void, Never>?
    private var requestedSource: String?
    /// 当前请求还在防抖等待中，尚未发给翻译框架
    private var debouncing = false
    private var commitWhenTranslated = false
    private var commitTimeoutTask: Task<Void, Never>?
    private var languagePackMissing = false

    /// 翻译方向在所有输入会话间共享，不持久化，进程重启后回到中→外
    private static var direction: Direction = .chineseToForeign
    private static let shiftTapMaxDuration: TimeInterval = 0.5
    /// Shift 按下时的事件时间戳（开机以来的秒数，不受系统改时间影响）
    private var shiftPressedAt: TimeInterval?

    private var panel: CandidatePanel { .shared }

    // MARK: IMKit 回调

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]).rawValue)
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        MainActor.assumeIsolated {
            switch event?.type {
            case .flagsChanged:
                return handleFlagsChanged(event, client: sender as? IMKTextInput)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                // 按住 Shift 点鼠标（Shift+点击选区）不算单按 Shift
                shiftPressedAt = nil
                return false
            default:
                return handleKeyDown(event, client: sender as? IMKTextInput)
            }
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            guard composer.isComposing, let client = sender as? IMKTextInput else { return reset() }
            commit(composer.forceCommitText(), to: client)
        }
    }

    nonisolated override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            syncSettings()
            DictionaryUpdater.shared.updateIfDue()
            if let notice = DictionaryUpdater.shared.takeNotice(), let client = sender as? IMKTextInput {
                panel.flash(notice, symbol: "books.vertical", cursorRect: cursorRect(of: client))
            }
        }
    }

    nonisolated override func menu() -> NSMenu! {
        // NSMenu 不是 Sendable，不能直接作为 assumeIsolated 的返回值
        nonisolated(unsafe) var menu: NSMenu?
        MainActor.assumeIsolated { menu = buildMenu() }
        return menu
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        MainActor.assumeIsolated { reset() }
        super.deactivateServer(sender)
    }

    // MARK: 按键

    private func handleFlagsChanged(_ event: NSEvent?, client: IMKTextInput?) -> Bool {
        guard let event, let client else { return false }
        switch event.keyCode {
        case Self.keyCodeShiftLeft, Self.keyCodeShiftRight:
            handleShift(event, client: client)
            return false
        case Self.keyCodeCapsLock:
            // Electron App（Termius、1Password）每按一次会把事件交给输入法两次，相隔几十毫秒，短时间内的后续事件忽略
            guard event.timestamp - Self.lastCapsLockPress > Self.capsLockIgnoreWindow else { return true }
            Self.lastCapsLockPress = event.timestamp
            cycleMode(client)
            return true
        default:
            shiftPressedAt = nil
            return false
        }
    }

    private enum Mode {
        case translate, lowercase, uppercase
    }

    /// Caps Lock 循环切换：字游 → 英文小写 → 英文大写。灯只有亮灭两态，对不上三个状态，所以不看灯、自己记。
    /// 在所有输入会话间共享，不持久化
    private static var mode = Mode.translate
    private static var directEnglish: Bool { mode != .translate }
    private static var lastCapsLockPress: TimeInterval = 0
    private static let capsLockIgnoreWindow: TimeInterval = 0.4

    /// 单按 Shift（按下后 0.5s 内松开，中间没有按其他键）切换翻译方向；直接英文下忽略
    private func handleShift(_ event: NSEvent, client: IMKTextInput) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if modifiers == .shift {
            shiftPressedAt = event.timestamp
            return
        }
        defer { shiftPressedAt = nil }
        guard modifiers.isEmpty, !Self.directEnglish, let pressedAt = shiftPressedAt,
              event.timestamp - pressedAt < Self.shiftTapMaxDuration else { return }
        toggleDirection(client)
    }

    private func toggleDirection(_ client: IMKTextInput) {
        if composer.isComposing { commit(composer.forceCommitText(), to: client) }
        Self.direction = composer.direction == .chineseToForeign ? .foreignToChinese : .chineseToForeign
        switchDirection(to: Self.direction, client: client)
        panel.flash(badge: Self.badge(for: Self.direction), cursorRect: cursorRect(of: client))
    }

    /// 从字游切到英文时，正在输入的原样按键上屏（拼音模式误打的英文单词可以这样直接出）
    private func cycleMode(_ client: IMKTextInput) {
        let rect = cursorRect(of: client)
        switch Self.mode {
        case .translate:
            if composer.isComposing { commit(composer.rawInput, to: client) }
            Self.mode = .lowercase
            panel.flash(symbol: "textformat.abc", cursorRect: rect)
        case .lowercase:
            Self.mode = .uppercase
            panel.flash(symbol: "capslock.fill", cursorRect: rect)
        case .uppercase:
            Self.mode = .translate
            panel.flash(badge: Self.badge(for: composer.direction), cursorRect: rect)
        }
    }

    /// 方向提示只显示当前在打的语言：中→外显示「中」，外→中显示外语名首字（英、法…）
    private static func badge(for direction: Direction) -> String {
        switch direction {
        case .chineseToForeign: "中"
        case .foreignToChinese:
            String(Preferences.languageName(Preferences.inputLanguage(for: Preferences.foreignLanguage)).prefix(1))
        }
    }

    private func handleKeyDown(_ event: NSEvent?, client: IMKTextInput?) -> Bool {
        shiftPressedAt = nil
        guard let event, event.type == .keyDown, let client else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Self.directEnglish {
            return insertDirectEnglish(event, modifiers: modifiers, client: client)
        }
        if !modifiers.isDisjoint(with: [.command, .control, .option]) {
            // 组合键交给 App 处理；正在输入时先把当前内容上屏，避免快捷键作用在 marked text 上
            if composer.isComposing { commit(composer.forceCommitText(), to: client) }
            return false
        }

        guard let key = Self.key(for: event, modifiers: modifiers) else {
            return composer.isComposing
        }
        if composer.direction == .chineseToForeign, !RimeRuntime.shared.isReady,
           case let .character(c) = key, c.isASCII, c.isLetter {
            panel.flash("词库部署中，请稍候…", symbol: "hourglass", cursorRect: cursorRect(of: client))
            return true
        }
        return perform(composer.handle(key), client: client)
    }

    /// 小写模式下大小写由 Shift 决定；大写模式下和系统大写锁定一样，按不按 Shift 都是大写。
    /// 按键本身打出的字母已经符合要求时原样交还 App（vim、网页 j/k 等单字母快捷键要的是按键事件）；
    /// Caps Lock 灯的状态和小写/大写对不上，大小写不符时才由输入法 insertText
    private func insertDirectEnglish(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, client: IMKTextInput) -> Bool {
        guard modifiers.isDisjoint(with: [.command, .control, .option]),
              case let .character(c)? = Self.key(for: event, modifiers: modifiers), c.isLetter
        else { return false }
        let text = Self.mode == .uppercase ? c.uppercased() : String(c)
        if event.characters == text { return false }
        client.insertText(text, replacementRange: Self.notFound)
        return true
    }

    private static let keyCodeCapsLock: UInt16 = 57
    private static let keyCodeShiftLeft: UInt16 = 56
    private static let keyCodeShiftRight: UInt16 = 60

    private static func key(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Key? {
        let shift = modifiers.contains(.shift)
        switch event.keyCode {
        case 36, 76: return .enter
        case 48: return shift ? .shiftTab : .tab
        case 49: return .space
        case 51: return .backspace
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default:
            guard let chars = event.characters, chars.count == 1, let c = chars.first,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  // Forward Delete、Home、F1 等功能键的字符在私有区 U+F700–U+F8FF，不是可输入字符
                  !c.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })
            else { return nil }
            // Caps Lock 用来切换直接英文，不应让英文输入变成大写，大小写只由 Shift 决定
            if modifiers.contains(.capsLock), c.isLetter {
                return .character(Character(shift ? c.uppercased() : c.lowercased()))
            }
            return .character(c)
        }
    }

    @discardableResult
    private func perform(_ action: ComposerAction, client: IMKTextInput) -> Bool {
        switch action {
        case .passThrough:
            return false
        case .update:
            // 等译文期间输入变了，不能把新输入的译文自动上屏
            if composer.pendingText != requestedSource {
                commitWhenTranslated = false
                commitTimeoutTask?.cancel()
            }
            // 先调度：缓存命中时译文同步写入，只渲染一次
            scheduleTranslation()
            render(client)
        case let .commit(text):
            commit(text, to: client)
        case .commitTranslation:
            commitTranslation(client)
        case .cancel:
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.notFound)
            reset()
        }
        return true
    }

    // MARK: 上屏

    private func commit(_ text: String, to client: IMKTextInput) {
        client.insertText(text, replacementRange: Self.notFound)
        reset()
    }

    private func commitTranslation(_ client: IMKTextInput) {
        // 没有可翻译的内容（如拼音没有候选）时不上屏，否则会插入空串并丢掉输入
        guard !composer.pendingText.isEmpty else { return NSSound.beep() }
        if let text = composer.freshTranslation {
            return commit(text, to: client)
        }
        if composer.freshTranslationError != nil {
            // 上次失败了就重新请求一次：偶发失败可以恢复，语言包刚装好也能直接用；仍失败时由 didTranslate 处理
            requestedSource = nil
        }
        commitWhenTranslated = true
        scheduleTranslation(immediate: true)
        commitTimeoutTask?.cancel()
        commitTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.commitWaitTimeout)
            guard !Task.isCancelled, let self, self.commitWhenTranslated else { return }
            self.commitWhenTranslated = false
            NSSound.beep()
        }
    }

    /// 语言包缺失时打开设置窗口引导下载，其他错误只提示音
    private func translationUnavailable() {
        if languagePackMissing {
            SettingsWindowController.shared.show()
        } else {
            NSSound.beep()
        }
    }

    private func reset() {
        composer.reset()
        translationTask?.cancel()
        translationTask = nil
        requestedSource = nil
        debouncing = false
        commitWhenTranslated = false
        commitTimeoutTask?.cancel()
        commitTimeoutTask = nil
        panel.hide()
    }

    // MARK: 翻译

    /// 缓存命中时只写入译文、不渲染，由调用方渲染
    private func scheduleTranslation(immediate: Bool = false) {
        let source = composer.pendingText
        let direction = composer.direction
        // 同一原文已在请求中就不重发；但要立即提交时不能再等剩下的防抖时间
        guard source != requestedSource || (immediate && debouncing) else { return }
        requestedSource = source
        translationTask?.cancel()
        debouncing = !immediate
        if let cached = AppleTranslator.shared.cachedTranslation(source, direction: direction) {
            translationTask = nil
            debouncing = false
            applyTranslationResult(.success(cached), for: source)
            return
        }
        translationTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                self?.debouncing = false
            }
            let result: Result<String, Error>
            do {
                result = .success(try await AppleTranslator.shared.translate(source, direction: direction))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.didTranslate(result, for: source)
        }
    }

    private func didTranslate(_ result: Result<String, Error>, for source: String) {
        guard !applyTranslationResult(result, for: source), let client = client() else { return }
        render(client)
    }

    /// 写入译文；正在等译文上屏时直接上屏。返回是否已上屏
    @discardableResult
    private func applyTranslationResult(_ result: Result<String, Error>, for source: String) -> Bool {
        languagePackMissing = false
        switch result {
        case let .success(text):
            composer.applyTranslation(text, for: source)
        case let .failure(error):
            languagePackMissing = error is TranslatorError
            log.error("翻译失败: \(error.localizedDescription, privacy: .public)")
            // 系统错误描述可能是英文长句，译文行只显示简短提示，详情看日志
            let message = languagePackMissing ? error.localizedDescription : "翻译失败 · 按 ↓ 回车重试"
            composer.applyTranslationFailure(message, for: source)
        }

        guard commitWhenTranslated else { return false }
        if let text = composer.freshTranslation, let client = client() {
            commit(text, to: client)
            return true
        }
        if composer.freshTranslationError != nil {
            commitWhenTranslated = false
            translationUnavailable()
        }
        return false
    }

    // MARK: 渲染

    private func render(_ client: IMKTextInput) {
        let text = composer.markedText
        // 传纯字符串时部分 App（浏览器、Electron）会画成选中分段的蓝底，显式指定单下划线
        let marked = NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: Self.notFound
        )

        panel.onSelectCandidate = { [weak self] index in self?.selectCandidate(index) }
        panel.onCommitTranslation = { [weak self] in
            guard let self, let client = self.client() else { return }
            self.commitTranslation(client)
        }
        panel.show(panelModel(), cursorRect: cursorRect(of: client))
    }

    private func cursorRect(of client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    private func selectCandidate(_ index: Int) {
        guard let client = client() else { return }
        perform(composer.selectCandidate(at: index), client: client)
    }

    private func panelModel() -> CandidatePanelModel {
        var model = CandidatePanelModel(
            candidates: composer.candidates,
            highlightedIndex: composer.highlightedIndex,
            focus: composer.focus
        )
        if let text = composer.freshTranslation {
            model.translation = text
            model.translationDimmed = false
        } else if let message = composer.freshTranslationError {
            model.translation = message
        } else if composer.pendingText.isEmpty {
            model.translation = ""
        } else if case let .done(_, staleText) = composer.translation {
            // 新译文到达前保留旧译文并置灰，避免闪烁
            model.translation = staleText
        } else {
            model.translation = "…"
        }
        return model
    }

    // MARK: 设置

    private func makeComposer(for direction: Direction) -> Composer {
        direction == .chineseToForeign
            ? Composer(engine: rimeEngine, buffersSentence: Preferences.buffersSentence)
            : Composer()
    }

    private func switchDirection(to direction: Direction, client: IMKTextInput?) {
        guard direction != composer.direction else { return }
        if composer.isComposing {
            client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.notFound)
        }
        reset()
        composer = makeComposer(for: direction)
    }

    /// 其他 App 里可能切过方向或改过设置，激活时同步
    private func syncSettings() {
        let direction = Self.direction
        switchDirection(to: direction, client: client())
        if direction == .chineseToForeign {
            rimeEngine.selectScheme(Preferences.schemeID)
            composer.buffersSentence = Preferences.buffersSentence
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let current = switch Self.mode {
        case .translate: "\(composer.direction.label)（Shift 切换方向）"
        case .lowercase: "英文小写（Caps Lock 切换）"
        case .uppercase: "英文大写（Caps Lock 切换）"
        }
        menu.addItem(NSMenuItem(title: "当前：\(current)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
