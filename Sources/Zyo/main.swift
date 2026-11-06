import AppKit
import InputMethodKit

guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String else {
    fatalError("Info.plist 缺少 InputMethodConnectionName")
}

MainActor.assumeIsolated { RimeRuntime.shared.start() }
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
log.info("Zyo 已启动")
NSApplication.shared.run()
