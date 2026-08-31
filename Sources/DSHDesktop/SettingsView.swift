import SwiftUI
import ServiceManagement

/// 设置窗口
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var server: ServerManager

    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var updateMessage: String?
    @State private var isUpdatingDSH = false
    @State private var isCheckingApp = false
    @State private var pendingLatest: String?
    @State private var showUpdateConfirm = false
    @State private var updateLog: [String] = []
    @State private var showUpdateLog = false
    // v1.0.1：alpha 通道与自检回滚
    @State private var pendingAlpha: String?
    @State private var showAlphaConfirm = false
    @State private var selfCheckFailures: [CheckResult]?
    @State private var showRollbackConfirm = false
    // 菜单栏插件管理（轻量：仅打开设置/点刷新时读一次，无后台任务）
    @State private var pluginRunning = false
    // Launcher 检查更新（卡3）：只在点按钮时联网，无常驻任务
    @State private var isCheckingLauncher = false
    @State private var launcherUpdateMessage: String?

    var body: some View {
        Form {
            Section("服务器") {
                // 端口由 DSH 后端固定监听，只读展示，避免误改导致连不上后端
                LabeledContent("端口", value: "\(AppState.defaultPort)")
                TextField("启动命令", text: $appState.serverCommand)
                    .font(.system(.body, design: .monospaced))
                Text("例如：dsh --profile web。命令会被解析为绝对路径后执行，端口自动追加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("启动应用时自动启动服务器", isOn: $appState.autoStartServer)
                Toggle("退出应用时保持服务器运行", isOn: $appState.keepServerOnQuit)
            }

            Section("桌面集成") {
                Toggle("开机自动启动 DSH Desktop", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { value in
                        setLaunchAtLogin(value)
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("需要把应用放在 /Applications 目录下才能生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // —— 菜单栏插件（可选装；未安装则整栏不出现）——
            if let plugin = MenuBarPluginManager.shared.manifest {
                Section("菜单栏插件") {
                    LabeledContent("插件", value: plugin.name)
                    LabeledContent("版本", value: plugin.version)
                    if let summary = plugin.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let bundleID = plugin.bundleID {
                        Toggle("启用（菜单栏常驻）", isOn: Binding(
                            get: { pluginRunning },
                            set: { on in
                                pluginRunning = on
                                if on {
                                    MenuBarPluginManager.shared.launchPlugin(bundleID)
                                } else {
                                    MenuBarPluginManager.shared.quitPlugin(bundleID)
                                }
                            }
                        ))
                    }
                    // 卡3 定稿：Launcher 的版本源 = Farverge/DSH-Launcher 的 Release
                    // （与主应用的"检查 DSH 更新"是两条独立链路，不共用版本源）
                    // 真机 R2：分组表单给每个按钮各分配一行，相邻也留空——两个按钮
                    // 并排进同一 HStack，空白行从结构上消失
                    HStack(spacing: 12) {
                        Button("重新检测插件") {
                            MenuBarPluginManager.shared.refresh()
                            syncPluginState()
                        }
                        Button(isCheckingLauncher ? "检查中…" : "检查 Launcher 更新") {
                            guard !isCheckingLauncher else { return }
                            isCheckingLauncher = true
                            launcherUpdateMessage = "正在联网检查 Farverge/DSH-Launcher 最新 Release…"
                            checkLauncherUpdate(currentVersion: launcherLocalVersion()) { message in
                                isCheckingLauncher = false
                                launcherUpdateMessage = message
                            }
                        }
                        .disabled(isCheckingLauncher)
                    }
                    if let launcherUpdateMessage {
                        Text(launcherUpdateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .onAppear { syncPluginState() }
            }

            Section("状态") {
                LabeledContent("服务器状态", value: server.status.label)
                LabeledContent("连接地址", value: appState.url.absoluteString)
                LabeledContent("桥接插件（dsh-desktop-bridge）", value: appState.bridgeConnected ? "已连接" : "未检测到")
                if appState.bridgeConnected, !appState.bridgeDetail.isEmpty {
                    // 明细非 @Published：打开设置页时读到的是最新轮询值，
                    // 页面停留期间不逐秒刷新（见 AppState.bridgeDetail 注释）
                    LabeledContent("桥接信息", value: appState.bridgeDetail)
                }
            }

            Section("关于") {
                LabeledContent("DSH Desktop", value: appVersion)
                LabeledContent("DSH 版本", value: server.currentDSHVersion ?? "待服务器启动后显示")
                LabeledContent("最低系统", value: "macOS 13+")
                dshUpdateControls
                Button(isCheckingApp ? "检查中…" : "检查应用更新") {
                    guard !isCheckingApp else { return }
                    isCheckingApp = true
                    updateMessage = "正在检查 GitHub 最新版本…"
                    checkAppUpdate { newest in
                        isCheckingApp = false
                        updateMessage = newest
                    }
                }
                .disabled(isCheckingApp)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            launchAtLogin = isLaunchAtLoginEnabled()
            // 打开设置时读一次插件目录（无后台任务）
            MenuBarPluginManager.shared.refresh()
            syncPluginState()
        }
        .onDisappear {
            appState.saveSettings()
        }
    }

    /// DSH 更新 UI（v1.0.1：拆为小组件，规避 SwiftUI 大表达式类型检查超时）
    @ViewBuilder
    private var dshUpdateControls: some View {
        updateStatusArea
        updateCheckButton
        if let alpha = pendingAlpha, !showUpdateConfirm {
            alphaInstallButton(alpha)
        }
    }

    /// 进度文案 + 终端风格日志
    @ViewBuilder
    private var updateStatusArea: some View {
        if let updateMessage {
            Text(updateMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if showUpdateLog {
            Text("下载在后台独立进程进行；关闭应用不会中断下载。下载完成并通过完整性校验后，会自动清理旧版与破损缓存并重启后端。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(updateLog, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 检查按钮（rc 稳定版确认弹窗挂在此处）
    private var updateCheckButton: some View {
        Button(isUpdatingDSH ? "更新中…" : "检查 DSH 更新（联网拉最新版）") {
            guard !isUpdatingDSH else { return }
            isUpdatingDSH = true
            updateMessage = "正在联网检查最新 dsh…"
            server.checkDSHUpdate { result in
                handleCheckResult(result)
            }
        }
        .disabled(isUpdatingDSH)
        .background(rollbackAlertAnchor)   // 回滚弹窗锚点改挂背景（独立 Form 行曾渲染成空行）
        .alert("发现新版本", isPresented: $showUpdateConfirm, presenting: pendingLatest) { latest in
            Button("现在更新并重启") {
                startUpdate(distTag: "latest", version: latest)
            }
            Button("取消", role: .cancel) {}
        } message: { latest in
            Text("是否下载 dsh \(latest) 并自动重启后端？（稳定版通道）\n\n下载在后台独立进程进行——即使关闭应用，下载进程也不会中断，会继续完成。")
        }
    }

    /// alpha 安装按钮（独立确认弹窗，警示样式）
    private func alphaInstallButton(_ alpha: String) -> some View {
        Button("安装预发布版 \(alpha)…") {
            showAlphaConfirm = true
        }
        .disabled(isUpdatingDSH)
        .alert("安装预发布版？", isPresented: $showAlphaConfirm) {
            Button("仍要安装", role: .destructive) {
                startUpdate(distTag: "alpha", version: alpha)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("预发布版本可能不稳定，生产环境请使用稳定版。\n\n已知影响（\(alpha)）：\n· 浏览器认证链启用——旧版壳可能出现页面 401\n\n安装后将自动运行兼容性自检；未通过可一键回滚到当前版本。")
        }
    }

    /// 回滚弹窗（锚定在隐藏视图上，与其它弹窗互不嵌套）
    private var rollbackAlertAnchor: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("更新后自检未通过", isPresented: $showRollbackConfirm, presenting: selfCheckFailures) { failures in
                Button("回滚到更新前版本并重启", role: .destructive) {
                    performRollback()
                }
                Button("暂不处理") {}
                Button("重试自检") {
                    retrySelfCheck()
                }
            } message: { failures in
                Text(failures.map { "· \($0.name)：\($0.detail)" }.joined(separator: "\n")
                     + "\n\n建议回滚；也可暂不处理（保持新版本继续运行）或重试自检。")
            }
    }

    /// 三级查询结果 → UI 状态
    private func handleCheckResult(_ result: Result<UpdateAvailability, Error>) {
        isUpdatingDSH = false
        switch result {
        case .success(let availability):
            let current = server.currentDSHVersion ?? ""
            let upToDate = availability.stable.map { current.isEmpty || SemVer.compare(current, $0) >= 0 } ?? true
            pendingAlpha = nil
            if upToDate {
                updateMessage = "DSH 已是最新版本（\(availability.source.rawValue)）"
            } else if let stable = availability.stable {
                pendingLatest = stable
                updateMessage = "发现新版本 \(stable)（当前 \(current.isEmpty ? "未解析" : current)，稳定版通道）。确认后才会更新重启。"
                showUpdateConfirm = true
            }
            if let alpha = availability.alpha,
               current.isEmpty || SemVer.compare(current, alpha) < 0 {
                pendingAlpha = alpha
                updateMessage = (updateMessage ?? "") + "\n发现预发布 \(alpha)（alpha 通道 · 体验新特性，可能不稳定）。"
            }
        case .failure(let e):
            updateMessage = "检查失败：\(e.localizedDescription)"
        }
    }

    /// 统一启动更新/安装（rc 与 alpha 共用管线，弹窗已在上游区分）
    private func startUpdate(distTag: String, version: String) {
        isUpdatingDSH = true
        updateLog = []
        showUpdateLog = true
        updateMessage = distTag == "latest"
            ? "正在更新到 \(version)，下载进度见下方终端…"
            : "正在安装预发布版 \(version)（alpha 通道）…"
        server.onUpdateProgress = { line in updateLog.append(line) }
        server.applyDSHUpdate(distTag: distTag, version: version) { r in
            server.onUpdateProgress = nil
            isUpdatingDSH = false
            handleUpdateResult(r)
        }
    }

    private func performRollback() {
        isUpdatingDSH = true
        updateMessage = "正在回滚…"
        server.onUpdateProgress = { line in updateLog.append(line) }
        server.rollbackFromFailedUpdate { r in
            server.onUpdateProgress = nil
            isUpdatingDSH = false
            switch r {
            case .success(let v):
                updateMessage = "已回滚至 v\(v) 并重启后端。"
            case .failure(let e):
                updateMessage = "回滚失败：\(e.localizedDescription)（快照可能已损坏，建议重装稳定版）"
            }
        }
    }

    private func retrySelfCheck() {
        Task { @MainActor in
            let results = await UpdateSafety.selfCheck()
            if results.allSatisfy(\.ok) {
                updateMessage = "重试自检：3/3 通过，新版本运行正常。"
            } else {
                selfCheckFailures = results
                showRollbackConfirm = true
            }
        }
    }

    /// 更新/安装结果统一出口：自检未通过 → 回滚弹窗；普通失败 → 文案。
    private func handleUpdateResult(_ r: Result<String, Error>) {
        switch r {
        case .success(let v):
            updateMessage = "DSH 已更新到 \(v)。"
        case .failure(let e as SelfCheckFailure):
            selfCheckFailures = e.results
            showRollbackConfirm = true
            updateMessage = "更新完成但自检未通过（\(e.failures.count)/3 项失败），请选择处理方式。"
        case .failure(let e):
            updateMessage = "更新失败：\(e.localizedDescription)"
        }
    }

    // MARK: - 开机自启（SMAppService，macOS 13+）

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchError = "设置开机自启失败：\(error.localizedDescription)"
            launchAtLogin = isLaunchAtLoginEnabled()
        }
    }

    /// 同步插件运行状态到位开关（读一次，无轮询）
    private func syncPluginState() {
        guard let bundleID = MenuBarPluginManager.shared.manifest?.bundleID else {
            pluginRunning = false
            return
        }
        pluginRunning = MenuBarPluginManager.shared.isRunning(bundleID)
    }

    /// 本地 Launcher 版本：优先 manifest.json，兜底读插件 .app 的 Info.plist（主线程调用）
    private func launcherLocalVersion() -> String {
        if let v = MenuBarPluginManager.shared.manifest?.version, !v.isEmpty { return v }
        return MenuBarPluginManager.shared.localAppVersion(bundleID: "com.deepseek-ai.dsh-launcher")
    }
}

// 卡3：Launcher 检查更新——以 Farverge/DSH-Launcher 最新 Release 为版本源，
// 与本地安装副本 manifest.json 里带的 version 比较；更新逻辑与安全性能参照
// 主应用自身的"检查应用更新"模式（只提示，不代下载）。
// currentVersion 由调用方（主线程）先取好——MenuBarPluginManager 是 @MainActor。
func checkLauncherUpdate(currentVersion: String, _ completion: @escaping (String) -> Void) {
    guard !currentVersion.isEmpty else {
        completion("未找到已安装的 Launcher，请先安装后再检查。")
        return
    }
    let url = URL(string: "https://api.github.com/repos/Farverge/DSH-Launcher/releases/latest")!
    URLSession.shared.dataTask(with: url) { data, response, error in
        DispatchQueue.main.async {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newestTag = obj["tag_name"] as? String else {
                    // 404 = 仓库还没有任何 Release，属正常发布前状态，与网络故障区分开
                    completion(status == 404
                               ? "Farverge/DSH-Launcher 尚未发布任何版本（首个 Release 后即可正常检查）"
                               : "无法检查 Launcher 更新（网络请求失败）")
                    return
            }
            let newest = newestTag.hasPrefix("v") ? String(newestTag.dropFirst()) : newestTag
            switch compareLauncherVersions(currentVersion, newest) {
            case 0:
                completion("Launcher 已是最新版本：\(currentVersion)")
            case -1:
                completion("发现新版 \(newestTag)（当前 \(currentVersion)）。请前往 https://github.com/Farverge/DSH-Launcher/releases 下载更新。")
            default:
                completion("当前 \(currentVersion) 比远端 \(newestTag) 更新（可能是预发布或本地构建），无需更新。")
            }
        }
    }.resume()
}

/// 语义化版本分段比较：逐段按数字比较（1.0.10 > 1.0.9）；带 -rc/-beta 等
/// 预发布后缀的同号版本视作小于正式版（增量审计 P2-1）。返回 -1/0/1。
func compareLauncherVersions(_ lhs: String, _ rhs: String) -> Int {
    let preRelease = { (v: String) in v.lowercased().contains("-") }
    let segments = { (v: String) -> [Int] in
        let core = v.split(separator: "-").first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = segments(lhs), b = segments(rhs)
    for i in 0..<max(a.count, b.count) {
        let av = i < a.count ? a[i] : 0
        let bv = i < b.count ? b[i] : 0
        if av != bv { return av < bv ? -1 : 1 }
    }
    if preRelease(lhs) != preRelease(rhs) { return preRelease(lhs) ? -1 : 1 }
    return 0
}


// 应用版本：从 Info.plist 读取 CFBundleShortVersionString
var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
}

// 检查 GitHub 最新 release 版本并比较
func checkAppUpdate(_ completion: @escaping (String) -> Void) {
    let url = URL(string: "https://api.github.com/repos/iiiiiei/dsh-macos/releases/latest")!
    URLSession.shared.dataTask(with: url) { data, _, error in
        DispatchQueue.main.async {
            guard error == nil, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion("无法检查应用更新（请求失败）")
                return
            }
            let newest = obj["tag_name"] as? String ?? "?"
            if newest == appVersion || newest.hasSuffix(appVersion) {
                completion("已是最新版本：\(appVersion)")
            } else {
                completion("发现新版本：\(newest)（当前 \(appVersion)）。请前往 GitHub 下载。")
            }
        }
    }.resume()
}
