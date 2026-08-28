import Foundation
import AppKit
import Combine

/// 菜单栏插件清单（由插件.app 自带，主应用只读取展示，不硬编码任何插件内容）
struct PluginManifest: Decodable {
    let name: String
    let version: String
    var summary: String? = nil
    var bundleID: String? = nil
    var executable: String? = nil
}

/// 通用"已安装菜单栏插件"管理（空壳，不依赖任何具体插件实现）
///
/// 仅在设置页打开或点"刷新"时读取一次 —— 无后台任务、无轮询、零功耗。
/// 找不到插件时返回 nil，设置页不显示任何相关 UI。
///
/// 插件安装到 ~/Library/Application Support/ 下，与主应用并列。
/// 该目录不在 Launchpad 扫描范围（Launchpad 只索引 /Applications），
/// 因此插件在启动台不显示图标，仅作为菜单栏常驻工具。
@MainActor
final class MenuBarPluginManager: ObservableObject {
    static let shared = MenuBarPluginManager()

    /// 私有插件目录（~/Library/Application Support）
    private let pluginDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support")

    /// 当前检测到的插件清单；nil = 未安装
    @Published var manifest: PluginManifest?

    private init() {}

    /// 在插件目录中定位某个 bundleID 对应的 .app 路径的完整绝对 URL。
    /// 精确匹配 CFBundleIdentifier，避免误命中目录下其它带 manifest.json 的 app。
    private func appURL(bundleID: String) -> URL? {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(at: pluginDir, includingPropertiesForKeys: nil) else { return nil }
        for app in apps where app.pathExtension == "app" {
            guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { continue }
            if (plist["CFBundleIdentifier"] as? String) == bundleID {
                return app
            }
        }
        return nil
    }

    /// 兜底读取插件 .app 的 CFBundleShortVersionString（manifest.json 缺失时用；
    /// 设置页"检查 Launcher 更新"的本地版本即来源于此）
    func localAppVersion(bundleID: String) -> String {
        guard let app = appURL(bundleID: bundleID),
              let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = plist["CFBundleShortVersionString"] as? String else { return "" }
        return version
    }

    /// 打开设置时调用：读一次插件目录里「该 bundleID」对应 .app 的 manifest.json
    func refresh(bundleID: String = "com.deepseek-ai.dsh-launcher") {
        guard let app = appURL(bundleID: bundleID) else {
            manifest = nil
            return
        }
        let manifestURL = app
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            manifest = nil
            return
        }
        // 补全派生字段（manifest.json 可能未声明，用 Info.plist 兜底）
        var info = m
        if info.bundleID == nil,
           let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) {
            info.bundleID = plist["CFBundleIdentifier"] as? String
            info.executable = plist["CFBundleExecutable"] as? String
        }
        manifest = info
    }

    /// 是否在运行（按 bundle identifier 查）
    func isRunning(_ identifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    /// 启动插件进程
    func launchPlugin(_ identifier: String) {
        guard let app = appURL(bundleID: identifier) else { return }
        NSWorkspace.shared.open(app)
    }

    /// 退出插件进程
    func quitPlugin(_ identifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            app.terminate()
        }
    }
}