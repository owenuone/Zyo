import CryptoKit
import Foundation

/// 后台每天自动更新雾凇的中文词典（cn_dicts），没有界面。只换词典、不换方案和 lua，方案跟随 App 版本，避免兼容问题。
/// 新词典放在 rime 用户目录的 cn_dicts/，rime 优先读用户目录，从而覆盖 App 自带的同名文件。
@MainActor
final class DictionaryUpdater {
    static let shared = DictionaryUpdater()

    private var isUpdating = false
    private var notice: String?

    /// 雾凇的 nightly 发布随 master 由 CI 重新构建
    private static let releaseURL = URL(string: "https://api.github.com/repos/iDvel/rime-ice/releases/tags/nightly")!
    private static let assetName = "cn_dicts.zip"
    private static let checkInterval: TimeInterval = 24 * 3600
    /// nightly 资源在对应提交后几分钟才构建好，比较自带版本时留出余量，避免把同一版本误判为更新
    private static let buildLag: TimeInterval = 3600
    private static let requiredFiles = ["8105", "base", "ext", "tencent", "others"].map { "\($0).dict.yaml" }

    static var dictsURL: URL { RimeRuntime.userDataURL.appendingPathComponent("cn_dicts", isDirectory: true) }

    /// App 自带词典对应的雾凇提交时间，构建时写入 Info.plist
    static let bundledDate: Date? = (Bundle.main.object(forInfoDictionaryKey: "ZyoDictionaryDate") as? String)
        .flatMap { ISO8601DateFormatter().date(from: $0) }

    /// App 升级后自带词典可能比下载的新，这时删掉下载的词典。须在 rime 初始化前调用
    static func removeStaleDictionaries() {
        if let installed = Preferences.dictionaryUpdatedAt, let bundled = bundledDate, bundled < installed { return }
        guard FileManager.default.fileExists(atPath: dictsURL.path) || Preferences.dictionaryUpdatedAt != nil else { return }
        try? FileManager.default.removeItem(at: dictsURL)
        Preferences.dictionaryUpdatedAt = nil
        Preferences.dictionaryDigest = nil
        log.info("自带词典较新，已删除下载的词典")
    }

    /// 自动更新完成后的提示，只取一次
    func takeNotice() -> String? {
        defer { notice = nil }
        return notice
    }

    /// 输入法激活时调用：距上次检查超过一天才检查，失败也等到第二天再试
    func updateIfDue() {
        guard !isUpdating else { return }
        if let last = Preferences.dictionaryLastCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await update() }
    }

    private func update() async {
        isUpdating = true
        defer { isUpdating = false }
        Preferences.dictionaryLastCheck = Date()
        do {
            let asset = try await Self.fetchAsset()
            guard isNewer(asset) else { return }
            let extracted = try await Self.download(asset)
            defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
            try Self.install(extracted)
            await RimeRuntime.shared.redeploy()
            Preferences.dictionaryUpdatedAt = asset.updatedAt
            Preferences.dictionaryDigest = asset.digest
            notice = "词库已更新"
            log.info("词典已更新到 \(asset.updatedAt, privacy: .public)")
        } catch {
            log.error("词典更新失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isNewer(_ asset: Asset) -> Bool {
        if let digest = asset.digest, digest == Preferences.dictionaryDigest { return false }
        if let installed = Preferences.dictionaryUpdatedAt { return asset.updatedAt > installed }
        guard let bundled = Self.bundledDate else { return true }
        return asset.updatedAt > bundled.addingTimeInterval(Self.buildLag)
    }

    // MARK: 下载与安装

    private struct Asset: Decodable {
        let name: String
        let url: URL
        let updatedAt: Date
        /// 形如 "sha256:…"，GitHub 较新的资源才有
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, digest
            case url = "browser_download_url"
            case updatedAt = "updated_at"
        }
    }

    private struct Release: Decodable {
        let assets: [Asset]
    }

    private static func fetchAsset() async throws -> Asset {
        var request = URLRequest(url: releaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let asset = try decoder.decode(Release.self, from: data).assets.first(where: { $0.name == assetName })
        else { throw UpdateError.assetMissing }
        return asset
    }

    /// 下载并解压到临时目录，返回解压出的 cn_dicts 目录
    private static func download(_ asset: Asset) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: asset.url, timeoutInterval: 60))
        // 异步 download 的临时文件不会自动删除
        defer { try? FileManager.default.removeItem(at: file) }
        try checkStatus(response)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("Zyo-dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try await Task.detached {
            if let digest = asset.digest {
                let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                guard digest == "sha256:\(hash)" else { throw UpdateError.digestMismatch }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", file.path, workDir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError.unzipFailed }
        }.value

        let dicts = workDir.appendingPathComponent("cn_dicts", isDirectory: true)
        for name in requiredFiles {
            let size = (try? dicts.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0 else { throw UpdateError.fileMissing(name) }
        }
        return dicts
    }

    /// 用新词典替换用户目录下的 cn_dicts，移动失败时恢复原目录
    private static func install(_ extracted: URL) throws {
        let fm = FileManager.default
        let backup = RimeRuntime.userDataURL.appendingPathComponent("cn_dicts.old", isDirectory: true)
        try? fm.removeItem(at: backup)
        let hadOld = fm.fileExists(atPath: dictsURL.path)
        if hadOld { try fm.moveItem(at: dictsURL, to: backup) }
        do {
            try fm.moveItem(at: extracted, to: dictsURL)
        } catch {
            if hadOld { try? fm.moveItem(at: backup, to: dictsURL) }
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    private static func checkStatus(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
    }
}

private enum UpdateError: LocalizedError {
    case http(Int), assetMissing, digestMismatch, unzipFailed
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case let .http(code): "服务器返回 \(code)"
        case .assetMissing: "发布中没有 cn_dicts.zip"
        case .digestMismatch: "下载的文件校验失败"
        case .unzipFailed: "解压失败"
        case let .fileMissing(name): "词典缺少 \(name)"
        }
    }
}
