import AppKit
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
    @State private var updateLog: [String] = []
    @State private var showUpdateLog = false
    // v1.0.1：alpha 通道与自检回滚
    @State private var pendingAlpha: String?
    @State private var selfCheckFailures: [CheckResult]?
    @State private var showRollbackConfirm = false
    // 应用自更新（v1.0.1）：确认弹窗 + 执行态
    @State private var pendingAppRelease: AppSelfUpdater.Release?
    @State private var isUpdatingApp = false
    // 菜单栏插件管理（轻量：仅打开设置/点刷新时读一次，无后台任务）
    @State private var pluginRunning = false
    // Launcher 更新（卡3→v1.0.3）：点按钮联网查询；确认后全自动安装（对齐前后端链路）
    @State private var isCheckingLauncher = false
    @State private var isUpdatingLauncher = false
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
                    // 卡3 定稿：Launcher 的版本源 = iiiiiei/dsh-launcher 的 Release
                    // （与主应用的"检查 DSH 更新"是两条独立链路，不共用版本源）
                    // 真机 R2：分组表单给每个按钮各分配一行，相邻也留空——两个按钮
                    // 并排进同一 HStack，空白行从结构上消失
                    HStack(spacing: 12) {
                        Button("重新检测插件") {
                            MenuBarPluginManager.shared.refresh()
                            syncPluginState()
                        }
                        Button(isCheckingLauncher ? "检查中…" : "检查 Launcher 更新") {
                            guard !isCheckingLauncher, !isUpdatingLauncher else { return }
                            isCheckingLauncher = true
                            launcherUpdateMessage = "正在联网检查两个发布源（\(LauncherSelfUpdater.primaryRepo) / \(LauncherSelfUpdater.mirrorRepo)）的最新 Release…"
                            Task { @MainActor in
                                defer { isCheckingLauncher = false }
                                launcherUpdateMessage = await checkLauncherUpdate(
                                    currentVersion: launcherLocalVersion())
                            }
                        }
                        .disabled(isCheckingLauncher || isUpdatingLauncher)
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
                Button(isUpdatingApp ? "应用更新中…" : (isCheckingApp ? "检查中…" : "检查应用更新")) {
                    guard !isCheckingApp, !isUpdatingApp else { return }
                    isCheckingApp = true
                    updateMessage = "正在检查两个发布源的最新版本…"
                    Task { @MainActor in
                        defer { isCheckingApp = false }
                        // 双发布源：主源（iiiiiei）= 抢先发布；镜像源（Farverge）= Actions
                        // 自动同步的稳定镜像，存在分钟级延迟。先主后镜，两源都失败才报
                        // 「无法检查」——只要还有一个源活着，检查就有结果可用。
                        let primary = await AppSelfUpdater.fetchLatestRelease()
                        let mirror = await AppSelfUpdater.fetchLatestRelease(repo: AppSelfUpdater.mirrorRepo)
                        guard primary != nil || mirror != nil else {
                            updateMessage = "无法检查应用更新（GitHub 请求失败）"
                            return
                        }
                        // 两源 tag 一致 → 完全静默走既有流程（不打扰用户，镜像延迟的
                        // 分钟级窗口内两源本来就常见短暂不一致，一致才是常态）；
                        // 不一致（含单源缺失/失败）→ 先弹双源说明弹窗，再进更新确认窗。
                        let release: AppSelfUpdater.Release
                        if let p = primary, let m = mirror, p.tag == m.tag {
                            release = p
                        } else {
                            guard let chosen = await presentSourceMismatch(
                                component: "DSH Desktop",
                                primaryRepo: AppSelfUpdater.primaryRepo, primary: primary,
                                mirrorRepo: AppSelfUpdater.mirrorRepo, mirror: mirror,
                                versionOf: { $0.version }, publishedAtOf: { $0.publishedAt },
                                compare: SemVer.compare)
                            else {
                                updateMessage = "已取消：两发布源版本不一致，本次检查中止，未做任何改动。"
                                return
                            }
                            release = chosen
                        }
                        let cmp = SemVer.compare(appVersion, release.version)
                        if cmp >= 0 {
                            updateMessage = cmp == 0
                                ? "应用已是最新版本：v\(appVersion)"
                                : "应用已是最新版本：v\(appVersion)（远端 \(release.tag) 较旧，已忽略）"
                            return
                        }
                        guard release.zipURL != nil else {
                            updateMessage = "发现新版本 \(release.tag)（当前 v\(appVersion)），但 Release 缺少安装包，请前往 GitHub 手动下载"
                            return
                        }
                        pendingAppRelease = release
                        updateMessage = "发现新版本 \(release.tag)（当前 v\(appVersion)）。"
                        presentAppUpdateConfirm(release)
                    }
                }
                .disabled(isCheckingApp || isUpdatingApp)
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
        if let alpha = pendingAlpha {
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

    /// 检查按钮（rc 稳定版确认改走独立窗：handleCheckResult 命中后调 presentBackendUpdateConfirm）
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
    }

    /// alpha 安装按钮（v1.0.2：确认改走独立窗，警示文案移入窗顶红字一行）
    private func alphaInstallButton(_ alpha: String) -> some View {
        Button("安装预发布版 \(alpha)…") {
            presentBackendUpdateConfirm(
                from: server.currentDSHVersion ?? "",
                to: alpha, prerelease: true)
        }
        .disabled(isUpdatingDSH)
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
                presentBackendUpdateConfirm(from: current, to: stable, prerelease: false)
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

    // MARK: - 更新确认独立窗接线（v1.0.2）
    // 三条更新链路的执行逻辑（startUpdate / applyDSHUpdate / performAppSelfUpdate）
    // 原样复用，这里只换"确认壳"：开窗 → 并行预取 notes → 到达后刷新窗内文本
    // （预取未就绪先显示"加载中…"，失败静默降级为"官方未提供"）。

    /// 后端确认窗（rc 稳定版 / alpha 预发布共用）：确认回调才触发原更新管线
    /// 后端确认窗（rc 稳定版 / alpha 预发布共用）：确认回调才触发原更新管线。
    /// 全部固定文案取自 UpdateCopy 目录（v1.0.5 去硬编码）。
    private func presentBackendUpdateConfirm(from current: String, to latest: String, prerelease: Bool) {
        let token = UpdateConfirmWindowController.shared.show(
            config: .init(
                title: UpdateCopy.backendTitle(prerelease: prerelease),
                fromVersion: current,
                toVersion: latest,
                warning: prerelease ? UpdateCopy.backendPrereleaseWarning : nil,
                // 影响面按目标版本门控（认证链自 0.1.2-alpha.1 起才有）
                warningDetail: prerelease
                    ? UpdateCopy.backendPrereleaseWarningDetail(for: latest)
                    : nil,
                footnote: UpdateCopy.backendFootnote(prerelease: prerelease),
                confirmTitle: UpdateCopy.backendConfirmTitle(prerelease: prerelease)),
            notes: nil) {
            startUpdate(distTag: prerelease ? "alpha" : "latest", version: latest)
        }
        prefetchNotes(repo: UpdateNotesEngine.dshUpstream, from: current, to: latest, token: token)
    }

    /// 前端应用确认窗（文案取自 UpdateCopy 目录）
    private func presentAppUpdateConfirm(_ release: AppSelfUpdater.Release) {
        let token = UpdateConfirmWindowController.shared.show(
            config: .init(
                title: UpdateCopy.appTitle(),
                fromVersion: appVersion,
                toVersion: release.version,
                footnote: UpdateCopy.appFootnote(version: release.version),
                confirmTitle: UpdateCopy.appConfirmTitle),
            notes: nil) {
            performAppSelfUpdate(release)
        }
        prefetchNotes(repo: UpdateNotesEngine.appRepo, from: appVersion, to: release.version, token: token)
    }

    /// notes 并行预取：不阻塞开窗；任何网络/解析失败都降级为"官方未提供"，绝不阻断更新
    private func prefetchNotes(repo: String, from: String, to: String, token: Int) {
        Task { @MainActor in
            let notes = await UpdateNotesEngine.fetch(repo: repo, from: from, to: to)
            UpdateConfirmWindowController.shared.updateNotes(token: token, notes)
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

    /// 应用自更新执行：下载→校验→暂存换壳→退出由脚本接管重启
    private func performAppSelfUpdate(_ release: AppSelfUpdater.Release) {
        isUpdatingApp = true
        updateLog = []
        showUpdateLog = true
        updateMessage = "正在自动更新应用到 \(release.tag)…"
        Task { @MainActor in
            do {
                let newApp = try await AppSelfUpdater.downloadAndVerify(release: release) { line in
                    updateLog.append(line)
                }
                try AppSelfUpdater.swapAndRelaunch(newApp: newApp) { line in
                    updateLog.append(line)
                }
                updateMessage = "应用已更新到 \(release.tag)，正在重启…"
                try? await Task.sleep(nanoseconds: 800_000_000)
                NSApp.terminate(nil)   // 换壳脚本随即将新版拉起
            } catch {
                isUpdatingApp = false
                updateMessage = "应用更新失败（未做任何改动）：\(error.localizedDescription)"
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

    // MARK: - 双发布源一致性弹窗（应用 / Launcher 两条检查链路共用）

    /// 双源版本不一致弹窗：与"更新后自检未通过"回滚弹窗同款 NSAlert（.informational）。
    /// 时机：在检查按钮的 Task 内主线程弹出，且必须先于更新确认窗——用户得先知道
    /// "两源各是什么版本、装的是哪个"，再谈装不装。泛型 + 取值闭包把两种 Release
    /// （AppSelfUpdater.Release / LauncherSelfUpdater.Release）抹平，弹窗逻辑只写一份；
    /// compare 约定与 SemVer.compare 相同（>0 = 第一参数更新）。
    /// 返回：用户选定要安装的源（版本较新的一方）；nil = 用户点「取消」，中止本次检查。
    @MainActor
    private func presentSourceMismatch<T>(component: String,
                                          primaryRepo: String, primary: T?,
                                          mirrorRepo: String, mirror: T?,
                                          versionOf: @escaping (T) -> String,
                                          publishedAtOf: @escaping (T) -> Date?,
                                          compare: @escaping (String, String) -> Int) async -> T? {
        // 选边：版本较新的一方为安装目标。仅单源存活时唯一解；版本打平但 tag 不一致
        // （写法差异等罕见情形）保守取主源——抢先源是发布的第一现场。
        let chosen: T
        let chosenRepo: String
        switch (primary, mirror) {
        case (let p?, let m?):
            let c = compare(versionOf(p), versionOf(m))
            if c > 0 { chosen = p; chosenRepo = primaryRepo }
            else if c < 0 { chosen = m; chosenRepo = mirrorRepo }
            else { chosen = p; chosenRepo = primaryRepo }
        case (let p?, nil): chosen = p; chosenRepo = primaryRepo
        case (nil, let m?): chosen = m; chosenRepo = mirrorRepo
        default: return nil   // 双源皆空不会走到这（调用方已提前拦截），防御性返回取消
        }
        // 逐源行：版本（发布于 YYYY-MM-DD）；缺失源标注、时间解析失败兜底
        let line = { (repo: String, release: T?) -> String in
            guard let release else { return "\(repo)：无 Release 或查询失败" }
            let when = ReleaseTimeParser.dayString(publishedAtOf(release))
                .map { "发布于 \($0)" } ?? "发布时间未知"
            return "\(repo)：v\(versionOf(release))（\(when)）"
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发布源版本不一致：\(component)"
        alert.informativeText = [line(primaryRepo, primary), line(mirrorRepo, mirror)]
            .joined(separator: "\n")
            + "\n\n将安装较新的 v\(versionOf(chosen))（来源 \(chosenRepo)）。镜像同步存在延迟属正常。"
        alert.addButton(withTitle: "安装较新版本 v\(versionOf(chosen))")   // 首按钮 = default
        alert.addButton(withTitle: "取消")
        // sheet 锚定当前设置窗优先（形态与回滚弹窗一致）；拿不到 window 引用（窗口未
        // key 等边缘态）退回 runModal。检查态布尔值在弹窗期间保持 true，按钮维持禁用。
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn ? chosen : nil
    }

    // MARK: - Launcher 更新（v1.0.3：对齐前后端——自动查询 + 全自动安装）

    /// Launcher 检查更新：双发布源（iiiiiei 抢先源 + Farverge 稳定镜像）最新 Release，
    /// 与本地 manifest.json 的 version 做"本地 vs 双源"三方比较；发现新版直接走确认窗。
    /// currentVersion 由调用方先取好——MenuBarPluginManager 是 @MainActor。
    ///
    /// 组合逻辑（本地 × 双源）：
    /// · 双源 tag 一致 → 退化为单源语义：本地最新 / 远端较新（进确认窗）/ 本地较新
    ///   （可能是本地构建），完全静默不弹窗；
    /// · 双源不一致（含单源缺失/失败）→ 先弹双源说明弹窗，以用户认可的"较新源"结果
    ///   作为远端版本，再回到上述本地 vs 远端比较——即使镜像较新、本地又比两个源都新
    ///   （极端情形），也会落到"本地较新，无需更新"分支，天然防降级。
    private func checkLauncherUpdate(currentVersion: String) async -> String {
        guard !currentVersion.isEmpty else {
            return "未找到已安装的 Launcher，请先安装后再检查。"
        }
        let primary = await LauncherSelfUpdater.fetchLatestRelease()
        let mirror = await LauncherSelfUpdater.fetchLatestRelease(repo: LauncherSelfUpdater.mirrorRepo)
        guard primary != nil || mirror != nil else {
            return "无法检查 Launcher 更新（GitHub 请求失败或尚未发布 Release）"
        }
        let release: LauncherSelfUpdater.Release
        if let p = primary, let m = mirror, p.tag == m.tag {
            release = p
        } else {
            guard let chosen = await presentSourceMismatch(
                component: "DSH Launcher",
                primaryRepo: LauncherSelfUpdater.primaryRepo, primary: primary,
                mirrorRepo: LauncherSelfUpdater.mirrorRepo, mirror: mirror,
                versionOf: { $0.version }, publishedAtOf: { $0.publishedAt },
                compare: compareLauncherVersions)
            else {
                return "已取消：两发布源版本不一致，本次检查中止，未做任何改动。"
            }
            release = chosen
        }
        switch compareLauncherVersions(currentVersion, release.version) {
        case 0:
            return "Launcher 已是最新版本：v\(currentVersion)"
        case -1:
            presentLauncherUpdateConfirm(release, from: currentVersion)
            return "发现新版 \(release.tag)（当前 v\(currentVersion)），更新说明见弹窗。"
        default:
            return "当前 v\(currentVersion) 比远端 \(release.tag) 更新（可能是本地构建），无需更新。"
        }
    }

    /// Launcher 确认窗：确认后全自动下载校验 + 插件同步 + 换壳重启（不再跳转 GitHub；
    /// 文案取自 UpdateCopy 目录）
    private func presentLauncherUpdateConfirm(_ release: LauncherSelfUpdater.Release,
                                              from current: String) {
        let token = UpdateConfirmWindowController.shared.show(
            config: .init(
                title: UpdateCopy.launcherTitle,
                fromVersion: current,
                toVersion: release.version,
                footnote: UpdateCopy.launcherFootnote(version: release.version),
                confirmTitle: UpdateCopy.launcherConfirmTitle),
            notes: nil) {
            performLauncherSelfUpdate(release)
        }
        prefetchNotes(repo: UpdateNotesEngine.launcherRepo, from: current, to: release.version, token: token)
    }

    /// Launcher 全自动更新执行（对齐 performAppSelfUpdate 模式）。
    /// 与应用自更新的关键差异：本应用不退出——被 terminate 的是 Launcher 进程，
    /// 换壳脚本负责把新版拉起；插件同步在换壳之前完成，失败即整体中止并恢复原状。
    private func performLauncherSelfUpdate(_ release: LauncherSelfUpdater.Release) {
        isUpdatingLauncher = true
        launcherUpdateMessage = "正在自动更新 Launcher 到 \(release.tag)…"
        Task { @MainActor in
            do {
                let payload = try await LauncherSelfUpdater.downloadAndVerify(release: release) { line in
                    launcherUpdateMessage = (launcherUpdateMessage ?? "") + "\n" + line
                }
                try LauncherSelfUpdater.swapAndRelaunch(payload: payload) { line in
                    launcherUpdateMessage = (launcherUpdateMessage ?? "") + "\n" + line
                }
                launcherUpdateMessage = (launcherUpdateMessage ?? "")
                    + "\nLauncher 已更新到 \(release.tag)，新版即将自动启动。"
            } catch {
                launcherUpdateMessage = (launcherUpdateMessage ?? "")
                    + "\nLauncher 更新失败（已恢复原状）：\(error.localizedDescription)"
            }
            isUpdatingLauncher = false
        }
    }
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

// 应用更新检查/执行已由 AppSelfUpdater 接管（v1.0.1）
