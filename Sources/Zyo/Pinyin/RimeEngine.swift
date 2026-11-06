import CRime
import Foundation
import ZyoCore

let rimeAPI = rime_get_api()!.pointee

private func rimeStructSize<T>(_: T.Type) -> Int32 {
    Int32(MemoryLayout<T>.size - MemoryLayout<Int32>.size)
}

/// 进程级 rime 初始化与部署。部署（编译词库）在后台线程进行，完成前 isReady 为 false。
@MainActor
final class RimeRuntime {
    static let shared = RimeRuntime()

    private(set) var isReady = false
    private var started = false
    /// rime 已成功初始化；启动失败时 isReady 永远不会变为 true
    private var initialized = false

    static let userDataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Zyo/rime", isDirectory: true)

    func start() {
        guard !started else { return }
        started = true

        guard let resources = Bundle.main.resourceURL else {
            log.error("找不到 App 资源目录，rime 未启动")
            return
        }
        let sharedData = resources.appendingPathComponent("rime-data", isDirectory: true)
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Zyo")
        do {
            try FileManager.default.createDirectory(at: Self.userDataURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            try installCustomConfig(from: resources)
            DictionaryUpdater.removeStaleDictionaries()
        } catch {
            log.error("准备 rime 目录失败: \(error.localizedDescription, privacy: .public)")
            return
        }

        // traits 中的字符串在进程生命周期内只设置一次，strdup 不释放
        var traits = RimeTraits()
        traits.data_size = rimeStructSize(RimeTraits.self)
        traits.shared_data_dir = UnsafePointer(strdup(sharedData.path))
        traits.user_data_dir = UnsafePointer(strdup(Self.userDataURL.path))
        traits.log_dir = UnsafePointer(strdup(logDir.path))
        traits.distribution_name = UnsafePointer(strdup("Zyo"))
        traits.distribution_code_name = UnsafePointer(strdup("Zyo"))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        traits.distribution_version = UnsafePointer(strdup(version))
        traits.app_name = UnsafePointer(strdup("rime.zyo"))
        traits.min_log_level = 1

        rimeAPI.setup(&traits)
        rimeAPI.initialize(&traits)
        initialized = true

        guard rimeAPI.start_maintenance(1) != 0 else {
            isReady = true
            return
        }
        Task { await finishMaintenance() }
    }

    /// 词典文件变化后重新部署。已有 session 会被清掉，RimeEngine 下次按键时重建
    func redeploy() async {
        guard initialized else { return }
        while !isReady {
            try? await Task.sleep(for: .seconds(1))
        }
        isReady = false
        rimeAPI.cleanup_all_sessions()
        guard rimeAPI.start_maintenance(1) != 0 else {
            isReady = true
            return
        }
        await finishMaintenance()
    }

    /// 部署期间 isReady 为 false，打字时提示「词库部署中」
    private func finishMaintenance() async {
        log.info("rime 部署开始")
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                rimeAPI.join_maintenance_thread()
                continuation.resume()
            }
        }
        isReady = true
        log.info("rime 部署完成")
    }

    /// 把 App 内置的 default.custom.yaml 同步到用户目录（rime 只从用户目录读取补丁）
    private func installCustomConfig(from resources: URL) throws {
        let source = resources.appendingPathComponent("default.custom.yaml")
        let target = Self.userDataURL.appendingPathComponent("default.custom.yaml")
        let content = try Data(contentsOf: source)
        guard (try? Data(contentsOf: target)) != content else { return }
        try content.write(to: target)
    }
}

/// 每个 InputController 持有一个 rime session。
@MainActor
final class RimeEngine: ConversionEngine {
    private(set) var state = EngineState()
    private var session: RimeSessionId = 0
    private var schemeID: String?

    deinit {
        if session != 0 {
            _ = rimeAPI.destroy_session(session)
        }
    }

    func selectScheme(_ id: String) {
        guard ensureSession(), id != schemeID else { return }
        applyScheme(id)
    }

    func process(_ key: Key) -> Bool {
        guard ensureSession(), let keycode = Self.keysym(for: key) else { return false }
        let handled = rimeAPI.process_key(session, keycode, 0) != 0
        refresh()
        return handled
    }

    func takeCommit() -> String? {
        guard session != 0 else { return nil }
        var commit = RimeCommit()
        commit.data_size = rimeStructSize(RimeCommit.self)
        guard rimeAPI.get_commit(session, &commit) != 0 else { return nil }
        defer { _ = rimeAPI.free_commit(&commit) }
        return commit.text.map { String(cString: $0) }
    }

    func selectCandidate(at index: Int) {
        guard ensureSession() else { return }
        _ = rimeAPI.select_candidate_on_current_page(session, index)
        refresh()
    }

    func highlightCandidate(at index: Int) {
        guard ensureSession() else { return }
        _ = rimeAPI.highlight_candidate_on_current_page(session, index)
        refresh()
    }

    func changePage(backward: Bool) {
        guard ensureSession() else { return }
        _ = rimeAPI.change_page(session, backward ? 1 : 0)
        refresh()
    }

    func commitComposition() -> String? {
        guard ensureSession() else { return nil }
        _ = rimeAPI.commit_composition(session)
        let text = takeCommit()
        refresh()
        return text
    }

    func clear() {
        if session != 0 {
            rimeAPI.clear_composition(session)
        }
        state = EngineState()
    }

    // MARK: 私有

    private func ensureSession() -> Bool {
        if RimeRuntime.shared.isReady, session != 0, rimeAPI.find_session(session) != 0 { return true }
        // 重新部署会清掉所有 session，旧的输入状态随之失效，不清掉的话 marked text 会卡住
        state = EngineState()
        guard RimeRuntime.shared.isReady else { return false }
        session = rimeAPI.create_session()
        guard session != 0 else {
            log.error("创建 rime session 失败")
            return false
        }
        applyScheme(Preferences.schemeID)
        return true
    }

    private func applyScheme(_ id: String) {
        if rimeAPI.select_schema(session, id) == 0 {
            log.error("切换输入方案失败: \(id, privacy: .public)")
        }
        schemeID = id
        refresh()
    }

    private func refresh() {
        var context = RimeContext()
        context.data_size = rimeStructSize(RimeContext.self)
        guard rimeAPI.get_context(session, &context) != 0 else {
            state = EngineState()
            return
        }
        defer { _ = rimeAPI.free_context(&context) }

        var next = EngineState()
        if let input = rimeAPI.get_input(session) {
            next.rawInput = String(cString: input)
        }
        if let preedit = context.composition.preedit {
            next.preedit = String(cString: preedit)
            // sel_start 是 UTF-8 字节偏移，之前的部分是已确认的分段
            let bytes = UnsafeBufferPointer(
                start: UnsafeRawPointer(preedit).assumingMemoryBound(to: UInt8.self),
                count: min(Int(context.composition.sel_start), strlen(preedit))
            )
            next.confirmedText = String(decoding: bytes, as: UTF8.self)
        }
        let menu = context.menu
        if let candidates = menu.candidates {
            next.candidates = (0..<Int(menu.num_candidates)).map { String(cString: candidates[$0].text) }
        }
        next.highlightedIndex = Int(menu.highlighted_candidate_index)
        next.isLastPage = menu.is_last_page != 0
        state = next
    }

    /// 转成 X11 keysym，rime 以此识别按键
    private static func keysym(for key: Key) -> Int32? {
        switch key {
        case let .character(c):
            guard let value = c.asciiValue, value >= 0x20, value < 0x7F else { return nil }
            return Int32(value)
        case .space: return 0x20
        case .backspace: return 0xFF08
        case .enter: return 0xFF0D
        case .escape: return 0xFF1B
        case .tab, .shiftTab, .up, .down, .left, .right: return nil
        }
    }
}
