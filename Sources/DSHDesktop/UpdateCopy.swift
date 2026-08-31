import Foundation

// MARK: - 更新确认窗文案目录（v1.0.5）
//
// 四条更新链路（后端 rc / 后端 alpha / 应用自更新 / Launcher）确认窗的全部
// 固定文案集中于此。此前这些字符串散在 SettingsView 各 presenter 里——改一句
// 话要翻三处代码，且"已知影响"这类跟官方版本走的策略性文案和通道逻辑缠在
// 一起。策略性文案（如 alpha 认证链影响）用版本谓词门控：官方版本演进后
// 只需要改这一个文件。
//
// 与 UpdateNotesEngine 的分工：那边负责"官方发布内容"（GitHub Release body，
// 运行时拉取）；这边是"壳自己的话"（通道策略、备份说明），本地集中管理。

enum UpdateCopy {
    // MARK: 后端（dsh）

    static func backendTitle(prerelease: Bool) -> String {
        prerelease ? "更新 DSH Desktop 后端（预发布）" : "更新 DSH Desktop 后端"
    }

    /// 通道结论（红字）：不随版本变的一句话
    static let backendPrereleaseWarning = "预发布版本可能不稳定，生产环境请使用稳定版。"

    /// 影响面细节（橙字）：按目标版本门控——浏览器认证链自 0.1.2-alpha.1 起
    /// 启用且无开关（alpha.2 认证代码与 alpha.1 零差异，见 2026-08-31 源码调查）。
    /// 壳 v1.0.5+ 已适配该链路：自有实例自动捕获启动输出的 token 完成授权，
    /// 外部 attach 实例用其终端里的授权 URL——故文案只作变更告知，不再是
    /// "未适配会 401"的风险警告。目标版本更旧（如未来的 0.1.1-rc.3 重装）时
    /// 不显示，避免误导。
    static func backendPrereleaseWarningDetail(for version: String) -> String? {
        // SemVer 对同号不同预发布细号返回 0（只比预发布有无），>=0 恰好覆盖
        // "同号任意 alpha 及其后的正式版"
        guard SemVer.compare(version, "0.1.2-alpha.1") >= 0 else { return nil }
        return "已知影响：新版启用浏览器认证链（launch token + 签名 Cookie）；"
            + "本壳 v1.0.6+ 已适配——自有实例自动从启动输出捕获 token 并完成授权，"
            + "外部 attach 实例需其终端里的授权 URL。"
    }

    static func backendFootnote(prerelease: Bool) -> String {
        prerelease
            ? "安装后将自动运行兼容性自检；未通过可一键回滚到当前版本。"
            : "下载在后台独立进程进行——即使关闭应用，下载进程也不会中断，会继续完成。"
    }

    static func backendConfirmTitle(prerelease: Bool) -> String {
        prerelease ? "仍要安装" : "立即更新"
    }

    // MARK: 应用本体（DSH Desktop）

    static func appTitle() -> String { "更新 DSH Desktop 应用" }

    static func appFootnote(version: String) -> String {
        "将下载 DSH.MacOS.Desktop.zip（v\(version)），校验通过后自动替换并重启。\n"
            + "旧版本会备份到 ~/Library/Application Support/DSH Backups/ 以便回退。"
    }

    static let appConfirmTitle = "下载并自动更新重启"

    // MARK: Launcher

    static let launcherTitle = "更新 DSH Launcher"

    static func launcherFootnote(version: String) -> String {
        "将下载 DSH.Launcher.zip（v\(version)），校验通过后自动同步 mini-dialog 插件并换壳重启 Launcher。\n"
            + "旧版本会备份到 ~/Library/Application Support/DSH Backups/ 以便回退。"
    }

    static let launcherConfirmTitle = "下载并自动更新重启"
}
