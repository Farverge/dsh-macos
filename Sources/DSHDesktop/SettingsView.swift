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
    // 菜单栏插件管理（轻量：仅打开设置/点刷新时读一次，无后台任务）
    @State private var pluginRunning = false

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
                    Button("重新检测插件") {
                        MenuBarPluginManager.shared.refresh()
                        syncPluginState()
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
                if let updateMessage {
                    Text(updateMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 终端风格的更新日志（进度实时追加）
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
                Button(isUpdatingDSH ? "更新中…" : "检查 DSH 更新（联网拉最新版）") {
                    guard !isUpdatingDSH else { return }
                    isUpdatingDSH = true
                    updateMessage = "正在联网检查最新 dsh…"
                    // 先查询并对比版本：无新版直接结束，绝不停服
                    server.checkDSHUpdate { result in
                        switch result {
                        case .success(let latest):
                            if let latest {
                                isUpdatingDSH = false
                                pendingLatest = latest
                                updateMessage = "发现新版本 \(latest)（当前 \(server.currentDSHVersion ?? "未解析")）。确认后才会更新重启。"
                                showUpdateConfirm = true
                            } else {
                                isUpdatingDSH = false
                                updateMessage = "DSH 已是最新版本"
                            }
                        case .failure(let e):
                            isUpdatingDSH = false
                            updateMessage = "检查失败：\(e.localizedDescription)"
                        }
                    }
                }
                .disabled(isUpdatingDSH)
                .alert("发现新版本", isPresented: $showUpdateConfirm, presenting: pendingLatest) { latest in
                    Button("现在更新并重启") {
                        isUpdatingDSH = true
                        updateLog = []
                        showUpdateLog = true
                        updateMessage = "正在更新到 \(latest)，下载进度见下方终端…"
                        // 挂实时进度回调
                        server.onUpdateProgress = { line in
                            updateLog.append(line)
                        }
                        server.applyDSHUpdate { r in
                            server.onUpdateProgress = nil
                            isUpdatingDSH = false
                            switch r {
                            case .success(let v):
                                updateMessage = "DSH 已更新到 \(v)，正在自动启动新的后端…"
                            case .failure(let e):
                                updateMessage = "更新失败：\(e.localizedDescription)"
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: { latest in
                    Text("是否下载 dsh \(latest) 并自动重启后端？\n\n下载在后台独立进程进行——即使关闭应用，下载进程也不会中断，会继续完成。")
                }
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
