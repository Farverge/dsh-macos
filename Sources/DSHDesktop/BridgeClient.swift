import Foundation

/// 与 dsh-desktop-bridge 插件通信的客户端。
/// 该插件是 DSH 生态内的一个普通 Cordis 宿主插件，
/// 注册了 /api/desktop/status 路由。
@MainActor
final class BridgeClient {
    static let shared = BridgeClient()

    private var task: Task<Void, Never>?

    func start(appState: AppState, server: ServerManager) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                guard server.status == .running else {
                    // 只在状态变化时赋值，避免无意义的重渲染导致 WebView 反复重载
                    if appState.bridgeConnected { appState.bridgeConnected = false }
                    if !appState.bridgeDetail.isEmpty { appState.bridgeDetail = "" }
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                if let info = await fetchStatus(appState.url) {
                    // 只有连接状态变化才发 objectWillChange；明细分秒级变动，
                    // 写普通属性即可（详见 AppState.bridgeDetail 注释）
                    if !appState.bridgeConnected { appState.bridgeConnected = true }
                    appState.bridgeDetail = info
                } else {
                    if appState.bridgeConnected { appState.bridgeConnected = false }
                    appState.bridgeDetail = ""
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func fetchStatus(_ base: URL) async -> String? {
        var request = URLRequest(url: base.appendingPathComponent("api/desktop/status"))
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let version = obj["version"] as? String ?? "?"
            let pid = obj["pid"] as? Int ?? 0
            let uptime = obj["uptimeMs"] as? Int ?? 0
            return "dsh v\(version) · pid \(pid) · 运行 \(uptime / 1000)s"
        } catch {
            return nil
        }
    }
}
