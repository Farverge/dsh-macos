import Foundation

// MARK: - 数据结构

/// 三级查询结果：稳定线 + 预发布线 + 实际命中的来源（诊断用）
struct UpdateAvailability {
    let stable: String?      // npm latest（三级兜底后所得；nil = 全部来源失败）
    let alpha: String?       // npm alpha dist-tag（GitHub 兜底不解析预发布 → nil）
    let source: QuerySource
}

enum QuerySource: String {
    case official = "npm 官方源"
    case mirror = "npmmirror 镜像"
    case github = "GitHub tags 兜底"
}

/// 自检单项结果
struct CheckResult: Identifiable {
    let id: String
    let name: String
    let ok: Bool
    let detail: String
}

/// 自检未通过时抛出的聚合错误（UI 据此弹回滚对话框）
struct SelfCheckFailure: Error {
    let results: [CheckResult]
    var failures: [CheckResult] { results.filter { !$0.ok } }
}

/// 语义化版本比较：逐段数字；同号时预发布(-rc/-alpha) < 正式版。
/// 例：0.1.1-rc.2 < 0.1.1；0.1.2-alpha.2 > 0.1.1-rc.2；0.1.10 > 0.1.9
enum SemVer {
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let isPre = { (v: String) -> Bool in v.lowercased().contains("-") }
        let core = { (v: String) -> [Int] in
            let head = v.split(separator: "-").first.map(String.init) ?? v
            return head.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = core(lhs), b = core(rhs)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        if isPre(lhs) != isPre(rhs) { return isPre(lhs) ? -1 : 1 }
        return 0
    }
}

// MARK: - 三级版本查询

/// 版本真相三级链：npm 官方 → npmmirror → GitHub tags。
/// 设计取舍：逐级仅在失败/超时后降级，不做双源比对——镜像同步滞后只会导致
/// "晚发现新版"，不会误报（安装阶段还有版本一致性校验兜底）。
enum UpdateEngine {
    static let npmOfficial = "https://registry.npmjs.org"
    static let npmMirror = "https://registry.npmmirror.com"
    static let githubTags = "https://api.github.com/repos/deepseek-ai/deepseek-harness/tags?per_page=100"
    static let tarballBase = "https://registry.npmjs.org/@deepseek-ai/dsh/-"

    static func fetchAvailability() async -> UpdateAvailability {
        // T1 / T2：registry 元数据（全量 JSON 较大但一次性，取 dist-tags 两个字段）
        for (base, source) in [(npmOfficial, QuerySource.official), (npmMirror, QuerySource.mirror)] {
            if let tags = await fetchDistTags(base) {
                return UpdateAvailability(stable: tags.latest, alpha: tags.alpha, source: source)
            }
        }
        // T3：GitHub tags 兜底（只保稳定线；tag 形如 dsh-v0.1.2-alpha.2）
        if let stable = await fetchLatestGitHubTag() {
            return UpdateAvailability(stable: stable, alpha: nil, source: .github)
        }
        return UpdateAvailability(stable: nil, alpha: nil, source: .official)
    }

    private static func fetchDistTags(_ base: String) async -> (latest: String?, alpha: String?)? {
        guard let url = URL(string: "\(base)/@deepseek-ai/dsh") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tags = obj["dist-tags"] as? [String: String] else { return nil }
            return (tags["latest"], tags["alpha"])
        } catch {
            return nil
        }
    }

    private static func fetchLatestGitHubTag() async -> String? {
        guard let url = URL(string: githubTags) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub API 惯例：标注 UA 与 JSON Accept
        request.setValue("DSH-Desktop-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            // dsh-v 前缀剥掉后做 SemVer 取最大；alpha tag 混在同列里也天然小于同号正式版
            let versions = arr.compactMap { row -> String? in
                guard let name = row["name"] as? String, name.hasPrefix("dsh-v") else { return nil }
                return String(name.dropFirst("dsh-v".count))
            }
            return versions.max { SemVer.compare($0, $1) < 0 }
        } catch {
            return nil
        }
    }
}

// MARK: - 三级安装

/// 下载安装三级链：npx@官方 → npx@镜像 → curl 官方 tarball 直链。
/// T3 的落位依赖 resolveCommand 第四级扫描 ~/.npm/_npx/*/node_modules/@deepseek-ai/dsh
/// ——解包出的目录天然可被启动链发现，无需触碰 npx 内部状态。
enum UpdateInstaller {
    /// 安装指定 distTag（"latest" / "alpha"）；version 用于安装后一致性校验。
    /// 返回实际安装成功的版本号。进度经 progress 回调（主线程跳转由调用方负责）。
    static func install(distTag: String, version: String,
                        progress: @escaping (String) -> Void) async throws -> String {
        // T1：官方源 npx（PTY 实时进度沿用既有模式）
        progress("① 尝试 npm 官方源（npx @deepseek-ai/dsh@\(distTag)）…")
        do {
            let v = try await ServerManager.pullViaNpx(registry: UpdateEngine.npmOfficial,
                                                       distTag: distTag, progress: progress)
            if SemVer.compare(v, version) == 0 { return v }
            progress("  官方源返回 v\(v) 与目标不符（同步异常），降级镜像重试…")
        } catch {
            progress("  官方源失败：\(error.localizedDescription)，降级镜像重试…")
        }
        // T2：镜像源 npx（历史稳定路径）
        progress("② 尝试 npmmirror 镜像（npx @deepseek-ai/dsh@\(distTag)）…")
        do {
            let v = try await ServerManager.pullViaNpx(registry: UpdateEngine.npmMirror,
                                                       distTag: distTag, progress: progress)
            if SemVer.compare(v, version) == 0 { return v }
            progress("  镜像同步滞后（返回 v\(v)），降级官方 tarball 直链…")
        } catch {
            progress("  镜像失败：\(error.localizedDescription)，降级官方 tarball 直链…")
        }
        // T3：裸 HTTP 直链 tarball（绕过 npm CLI 全链路）
        progress("③ 尝试官方 tarball 直链（curl \(version).tgz）…")
        return try await installViaTarball(version: version, progress: progress)
    }

    /// T3：下载官方 tgz 并解包到新的 _npx 缓存目录（resolveCommand 可发现）。
    private static func installViaTarball(version: String,
                                          progress: @escaping (String) -> Void) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-\(version)-\(UUID().uuidString.prefix(8))")
        let tgz = tmp.appendingPathExtension("tgz")
        let targetRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx/update-fallback-\(UUID().uuidString.prefix(8))")
        let pkgDir = targetRoot.appendingPathComponent("node_modules/@deepseek-ai/dsh")

        do {
            let code = try await curl("https://raw.tarball.invalid", version: version, to: tgz)
            _ = code
            // 解包（tgz 顶层为 package/）与校验放到后台线程执行
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                proc.arguments = ["-xzf", tgz.path, "-C", tmp.path]
                try proc.run(); proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "update", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "tarball 解包失败"])
                }
                let unpacked = tmp.appendingPathComponent("package")
                guard fm.fileExists(atPath: unpacked.appendingPathComponent("package.json").path) else {
                    throw NSError(domain: "update", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "tarball 结构异常（缺 package.json）"])
                }
                try fm.createDirectory(at: pkgDir.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: unpacked, to: pkgDir)
            }.value
            progress("  ✓ 直链安装完成：\(pkgDir.lastPathComponent)（v\(version)）")
            return version
        } catch {
            // 清理半成品
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: targetRoot)
            throw error
        }
    }

    private nonisolated static func curl(_ placeholder: String, version: String, to dest: URL) async throws -> Int32 {
        _ = placeholder
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-fSL", "--max-time", "120", "--retry", "1",
                          "-o", dest.path,
                          "\(UpdateEngine.tarballBase)/dsh-\(version).tgz"]
        try proc.run()
        // 等待 + 180s 兜底超时
        let deadline = Date().addingTimeInterval(180)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if proc.isRunning {
            proc.terminate(); proc.waitUntilExit()
            throw NSError(domain: "update", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "tarball 下载超时"])
        }
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "update", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "tarball 下载失败（HTTP \(proc.terminationStatus)）"])
        }
        return proc.terminationStatus
    }
}

// MARK: - 快照 / 自检 / 回滚

/// 更新安全网：装前快照、装后自检、失败一键回滚。
/// 快照固定落位 ~/.npm/_npx-preupdate-snapshot/（manifest.json 记录来源与新增目录）。
enum UpdateSafety {
    static var snapshotRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx-preupdate-snapshot")
    }
    static var manifestURL: URL { snapshotRoot.appendingPathComponent("manifest.json") }

    struct Manifest: Codable {
        var sourcePath: String     // 更新前 dsh 包所在目录（回滚恢复目标）
        var version: String        // 更新前版本
        var installedNewDirs: [String]  // 本次安装新产生的缓存目录（回滚时移除）
        var createdAt: Double
    }

    /// 定位当前在用的 dsh 缓存目录：优先匹配运行中进程的命令行引用，
    /// 退回 _npx 下 mtime 最新的 @deepseek-ai/dsh。
    static func locateCurrentPackageDir() -> (dir: URL, version: String)? {
        let fm = FileManager.default
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        // 运行中后端进程的命令行（含 bin.js 绝对路径）
        var runningBin: String?
        if let out = runCapture("/usr/bin/pgrep", ["-fl", "@deepseek-ai/dsh/lib/bin.js"]) {
            // 形如 "123 /opt/.../node /Users/.../_npx/xxxx/node_modules/@deepseek-ai/dsh/lib/bin.js ..."
            if let range = out.range(of: "(/[^ ]+)/node_modules/@deepseek-ai/dsh/lib/bin.js") {
                runningBin = String(out[range]).description
            }
        }
        var best: (URL, Date)?
        guard let entries = try? fm.contentsOfDirectory(atPath: npxRoot.path) else { return nil }
        for entry in entries {
            let pkg = npxRoot.appendingPathComponent(entry)
                .appendingPathComponent("node_modules/@deepseek-ai/dsh")
            guard fm.fileExists(atPath: pkg.appendingPathComponent("package.json").path),
                  let data = try? Data(contentsOf: pkg.appendingPathComponent("package.json")),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else { continue }
            if let bin = runningBin, pkg.path.hasPrefix(bin) {
                return (pkg, version)   // 运行中实例优先，直接命中
            }
            let mtime = (try? fm.attributesOfItem(atPath: pkg.path)[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime > best!.1 { best = (pkg, mtime) }
        }
        guard let (pkg, _) = best,
              let data = try? Data(contentsOf: pkg.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { return nil }
        return (pkg, version)
    }

    /// 更新前快照：ditto 当前包目录 + 记录基线（含安装前已存在的缓存目录清单，
    /// 供安装后差集出 installedNewDirs）。
    static func snapshotCurrent() throws -> Manifest? {
        guard let (pkg, version) = locateCurrentPackageDir() else { return nil }
        let fm = FileManager.default
        try fm.removeItem(at: snapshotRoot)          // 幂等：清掉上次快照
        let copyDest = snapshotRoot.appendingPathComponent("package")
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [pkg.path, copyDest.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "update", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "快照失败（ditto 退出码 \(proc.terminationStatus)）"])
        }
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        let existing = (try? fm.contentsOfDirectory(atPath: npxRoot.path)) ?? []
        let manifest = Manifest(sourcePath: pkg.path, version: version,
                                installedNewDirs: existing, createdAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        return manifest
    }

    /// 安装后差集登记：把新出现的缓存目录写回 manifest（回滚移除名单）。
    static func recordNewDirs(_ manifest: inout Manifest) {
        let fm = FileManager.default
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        let current = (try? fm.contentsOfDirectory(atPath: npxRoot.path)) ?? []
        let before = Set(manifest.installedNewDirs)
        manifest.installedNewDirs = current.filter { !before.contains($0) }
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }

    /// 兼容性自检（三项，各 10s 超时）。后端需已重启并开始监听。
    static func selfCheck() async -> [CheckResult] {
        var results: [CheckResult] = []
        results.append(await probeRoot())
        results.append(await probeBridge())
        results.append(await probeMini())
        return results
    }

    private static func probe(_ path: String, name: String,
                              validate: @escaping ([String: Any], Int) -> CheckResult) async -> CheckResult {
        guard let url = URL(string: "http://127.0.0.1:3080\(path)") else {
            return CheckResult(id: name, name: name, ok: false, detail: "URL 构造失败")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return validate(obj, code)
        } catch {
            return CheckResult(id: name, name: name, ok: false, detail: "不可达：\(error.localizedDescription)")
        }
    }

    private static func probeRoot() async -> CheckResult {
        await probe("/", name: "根页面") { _, code in
            switch code {
            case 200:
                return CheckResult(id: "根页面", name: "根页面", ok: true, detail: "HTTP 200")
            case 401, 403:
                return CheckResult(id: "根页面", name: "根页面", ok: false,
                    detail: "HTTP \(code)：新版启用了浏览器认证（launch token + Cookie），当前壳尚未适配该流程")
            default:
                return CheckResult(id: "根页面", name: "根页面", ok: false, detail: "HTTP \(code)")
            }
        }
    }

    private static func probeBridge() async -> CheckResult {
        await probe("/api/desktop/status", name: "桥接状态") { obj, code in
            if code == 200, obj["ok"] as? Bool == true {
                return CheckResult(id: "桥接状态", name: "桥接状态", ok: true, detail: "ok")
            }
            return CheckResult(id: "桥接状态", name: "桥接状态", ok: false,
                detail: "HTTP \(code)（桥接插件路由未按预期响应）")
        }
    }

    private static func probeMini() async -> CheckResult {
        await probe("/api/mini/options", name: "迷你框插件") { _, code in
            if code == 200 {
                return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: true, detail: "ok")
            }
            if code == 404 {
                return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: false,
                    detail: "HTTP 404（mini-dialog 插件未随新后端加载）")
            }
            return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: false, detail: "HTTP \(code)")
        }
    }

    /// 一键回滚：移除本次安装新增的缓存目录 → 快照恢复回原位 → 杀后端并等健康。
    static func rollback() async throws -> String {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw NSError(domain: "update", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "找不到更新前快照（manifest 缺失）"])
        }
        let fm = FileManager.default
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        // ① 移除新增目录
        for dir in manifest.installedNewDirs {
            try? fm.removeItem(at: npxRoot.appendingPathComponent(dir))
        }
        // ② 恢复快照到原位（原目录可能被安装流程清理过，先确保父目录存在）
        let dest = URL(fileURLWithPath: manifest.sourcePath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)   // 原位若有残留（同版本重装场景）先清
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [snapshotRoot.appendingPathComponent("package").path, dest.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "update", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "快照恢复失败（ditto 退出码 \(proc.terminationStatus)）"])
        }
        try? fm.removeItem(at: snapshotRoot)
        return manifest.version
    }

    /// 回滚后由 ServerManager 调用：杀 3080 后端进程（外部实例也杀——回滚场景必须
        /// 让旧版本重新接管），等端口空闲后交由 forwardStart 冷启动。
    static func killBackendForRollback() async {
        guard let out = runCapture("/usr/sbin/lsof", ["-tiTCP:3080", "-sTCP:LISTEN"]),
              !out.isEmpty else { return }
        let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { kill(pid, SIGTERM) }
        // 最多等 5s 优雅退出，超时 SIGKILL
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let still = runCapture("/usr/sbin/lsof", ["-tiTCP:3080", "-sTCP:LISTEN"]) ?? ""
            if still.isEmpty { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for pid in pids { kill(pid, SIGKILL) }
    }

    private nonisolated static func runCapture(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning { proc.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
