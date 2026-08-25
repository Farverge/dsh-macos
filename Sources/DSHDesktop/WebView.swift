import SwiftUI
@preconcurrency import WebKit
import UserNotifications

/// 内嵌 DSH Web GUI 的 WKWebView 封装
struct HarnessWebView: NSViewRepresentable {
    let url: URL
    var onLoadState: (LoadState) -> Void = { _ in }

    enum LoadState {
        case loaded(title: String)
        case failed
        // 注意：刻意没有 .loading —— didStartProvisional 只驱动内部的
        // isLoading 守卫，不对外发事件；历史上曾有过从未被发射的死分支
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "DSHDesktop/1.0"
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        // 沉浸式：页面背景透明（配合 fullSizeContentView 顶到顶；WKWebView 的
        // isOpaque 只读，透明由 underPageBackgroundColor 提供）
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        context.coordinator.observeReload()
        context.coordinator.observeEnhancements()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 只在首次加载时由我们发起；此后 SPA 的路由变化（pushState 等）
        // 会改变 webView.url，不能再按地址差异重载根页面，否则会打断应用。
        // 手动刷新走菜单栏“刷新页面”（reload）。
        guard !context.coordinator.hasLoadedOnce else { return }
        guard !context.coordinator.isLoading else { return }
        if webView.url?.absoluteString != url.absoluteString {
            // 同步置位 isLoading，避免 didStartProvisional 异步到达前
            // 被另一次 updateNSView 重复发起加载
            context.coordinator.isLoading = true
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HarnessWebView
        weak var webView: WKWebView?
        private var reloadObserver: NSObjectProtocol?
        private var enhancementsObserver: NSObjectProtocol?
        var isLoading = false
        private(set) var hasLoadedOnce = false

        init(_ parent: HarnessWebView) {
            self.parent = parent
        }

        deinit {
            // 块观察者必须显式移除；否则每次 WebView 重建（状态面板 ⇄ 页面
            // 切换）都会在 NotificationCenter 里留下一个永久触发的空转 token
            if let reloadObserver {
                NotificationCenter.default.removeObserver(reloadObserver)
            }
            if let enhancementsObserver {
                NotificationCenter.default.removeObserver(enhancementsObserver)
            }
        }

        /// 菜单栏“刷新页面”支持
        func observeReload() {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .dshReloadRequested, object: nil, queue: .main
            ) { [weak self] _ in
                self?.webView?.reload()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncEnhancements(webView)
            // 通知宿主：网页已加载（AppDelegate 借此把拖拽带重新置顶——
            // SwiftUI 晚于拖拽带插入 WKWebView 会盖住拖拽带）
            NotificationCenter.default.post(name: .dshWebViewLoaded, object: webView)
            isLoading = false
            hasLoadedOnce = true
            parent.onLoadState(.loaded(title: webView.title ?? "DeepSeek Harness"))
        }

        // MARK: - 增强 Overlay 同步（桌面外壳布局）

        private func syncEnhancements(_ webView: WKWebView) {
            // 本地桌面外壳 Overlay（幂等注入：固定 style id）。
            // 它只约束根 Frame 的外层列/行，不测量或改写官方功能组件。
            if let layoutPath = Bundle.main.path(forResource: "desktop-layout", ofType: "js", inDirectory: "overlays"),
               let layout = try? String(contentsOfFile: layoutPath, encoding: .utf8) {
                webView.evaluateJavaScript(layout) { _, _ in }
            }
        }

        /// 设置变化时联动（UserDefaults 通知）
        func observeEnhancements() {
            enhancementsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let webView = self?.webView, webView.url != nil else { return }
                self?.syncEnhancements(webView)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        // MARK: - 导航策略

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.path.contains("/api/session.export") {
                decisionHandler(.cancel)
                Task {
                    await Self.download(url: url)
                }
                return
            }

            // 外部域名的主框架导航交给系统默认浏览器：官方界面里点击的任何
            // 站外链接都不应占据壳窗口（否则整窗被外部页面接管且无可见退路）。
            // 仅拦截主框架；页面内的外部子资源（字体/图片等）照常放行渲染。
            // 本机 127.0.0.1 / localhost 的所有导航照常放行。
            if navigationAction.targetFrame?.isMainFrame == true,
               let url = navigationAction.request.url,
               let host = url.host?.lowercased(),
               host != "127.0.0.1", host != "localhost", !host.hasSuffix(".localhost") {
                decisionHandler(.cancel)
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                }
                return
            }

            decisionHandler(.allow)
        }

        /// 原生下载 session 导出 ZIP 到 ~/Downloads，并用 UserNotifications 提示
        @MainActor
        static func download(url: URL) async {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            // 文件名：session-log-<id>.zip
            let sessionId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "sessionId" })?.value ?? "session"
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let file = downloads.appendingPathComponent("session-log-\(sessionId).zip")
            try? data.write(to: file)
            // 原生通知（同应用内通道，不使用 osascript）
            let content = UNMutableNotificationContent()
            content.title = "DSH Desktop 会话导出"
            content.body = "已保存 \(file.lastPathComponent)"
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            parent.onLoadState(.failed)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            parent.onLoadState(.failed)
        }

        /// 新窗口请求（target=_blank / window.open）：外部站点交系统浏览器，
        /// 本机地址仍在壳内打开——与主框架导航策略保持一致
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url,
                   let host = url.host?.lowercased(),
                   host != "127.0.0.1", host != "localhost", !host.hasSuffix(".localhost") {
                    Task { @MainActor in
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        /// 麦克风 / 摄像头权限（DSH 可能用于语音输入等）
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}