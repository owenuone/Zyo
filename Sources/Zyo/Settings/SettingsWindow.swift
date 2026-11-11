import AppKit
import SwiftUI
import Translation
import ZyoCore

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // 每次打开重建视图，确保显示的是最新设置（输入法菜单里也能改方案）
        let hosting = NSHostingController(rootView: SettingsView())
        window.contentViewController = hosting
        // 先按 SwiftUI 内容定好尺寸再居中，否则用的是 0×0 的初始尺寸
        window.setContentSize(hosting.view.fittingSize)
        // 不用 center()：它会刻意放在中心偏上的位置
        if let visible = NSScreen.main?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        // 从输入法菜单打开时前台是别的 App：协作式的 NSApp.activate() 会被拒绝（窗口显示了但不是 key），
        // 所以等菜单收起后用 ignoringOtherApps 强制激活；orderFrontRegardless 兜底保证窗口在最前
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "字游设置"
        // 标题栏透明，毛玻璃背景延伸到标题栏下面
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // 后台应用激活时系统不会切换桌面空间，所以让窗口出现在当前空间（包括全屏应用之上）。
        // 不要设 hidesOnDeactivate：菜单关闭后焦点回到原 App，窗口会被立刻隐藏
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }
}

/// 透出窗口后面内容的毛玻璃；SwiftUI 的 Material 只模糊窗口内部，做不到这一点
private struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 系统设置风格的行标题：彩色圆角方块里放白色 SF Symbol
private struct IconLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// 键帽样式的按键
private struct KeyCaps: View {
    let keys: [String]

    init(_ keys: [String]) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            }
        }
    }
}

private struct SettingsView: View {
    private enum PackStatus {
        case checking, installed, missing, downloading
    }

    @State private var schemeID = Preferences.schemeID
    @State private var buffersSentence = Preferences.buffersSentence
    @State private var foreignLanguage = Preferences.foreignLanguage
    @State private var packStatus = PackStatus.checking
    @State private var downloadConfiguration: TranslationSession.Configuration?
    @State private var missingLanguages: (source: Locale.Language, target: Locale.Language)?

    var body: some View {
        Form {
            Section {
                Picker(selection: $schemeID) {
                    ForEach(Preferences.schemes, id: \.id) { scheme in
                        Text(scheme.name).tag(scheme.id)
                    }
                } label: {
                    IconLabel("中文输入", symbol: "keyboard", color: .blue)
                }
                .onChange(of: schemeID) { _, id in Preferences.schemeID = id }
                Toggle(isOn: $buffersSentence) {
                    IconLabel("整句翻译", symbol: "text.append", color: .purple)
                }
                .onChange(of: buffersSentence) { _, on in Preferences.buffersSentence = on }
            } header: {
                Text("输入方案")
            }

            Section {
                HStack {
                    Picker("外语", selection: $foreignLanguage) {
                        ForEach(Preferences.foreignLanguages, id: \.self) { code in
                            Text(Preferences.languageName(code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: foreignLanguage) { _, code in Preferences.foreignLanguage = code }
                    Spacer()
                    packStatusView
                }
            } header: {
                Text("翻译语言")
            }

            Section("快捷键") {
                LabeledContent("切换方向") { KeyCaps(["⇧ Shift"]) }
                LabeledContent("切换 ABC") { KeyCaps(["⇪ Caps Lock"]) }
                LabeledContent("切换译文") { KeyCaps(["↓", "Tab"]) }
                LabeledContent("切换高亮") { KeyCaps(["←", "→"]) }
                LabeledContent("翻页") { KeyCaps(["-", "="]) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WindowBlur().ignoresSafeArea())
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: foreignLanguage) { await refreshPackStatus() }
        .translationTask(downloadConfiguration) { session in
            // prepareTranslation 会弹出系统的语言包下载确认
            do {
                try await session.prepareTranslation()
            } catch {
                log.error("下载语言包失败: \(error.localizedDescription, privacy: .public)")
                return await refreshPackStatus()
            }
            let downloaded = downloadConfiguration
            await refreshPackStatus()
            // 非拉丁外语可能要下两组（中→外、英→中），装好一组后接着下另一组
            if let missing = missingLanguages,
               missing.source != downloaded?.source || missing.target != downloaded?.target {
                startDownload()
            }
        }
    }

    @ViewBuilder
    private var packStatusView: some View {
        switch packStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .installed:
            Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            ProgressView().controlSize(.small)
        case .missing:
            Button("下载") { startDownload() }
        }
    }

    /// 下载第一个未安装的语言对
    private func startDownload() {
        guard let (source, target) = missingLanguages else { return }
        packStatus = .downloading
        if downloadConfiguration?.source == source, downloadConfiguration?.target == target {
            downloadConfiguration?.invalidate()
        } else {
            downloadConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    @MainActor
    private func refreshPackStatus() async {
        packStatus = .checking
        missingLanguages = await AppleTranslator.shared.missingLanguages(foreign: foreignLanguage)
        packStatus = missingLanguages == nil ? .installed : .missing
    }
}
