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
            #if ROLLBACK_TEST
            throw NSError(domain: "test", code: 99)
            #else
            let v = try await ServerManager.pullViaNpx(registry: UpdateEngine.npmOfficial,
                                                       distTag: distTag, progress: progress)
            if SemVer.compare(v, version) == 0 { return v }
            progress("  官方源返回 v\(v) 与目标不符（同步异常），降级镜像重试…")
            #endif
        } catch {
            progress("  官方源失败：\(error.localizedDescription)，降级镜像重试…")
        }
        // T2：镜像源 npx（历史稳定路径）
        progress("② 尝试 npmmirror 镜像（npx @deepseek-ai/dsh@\(distTag)）…")
        do {
            #if ROLLBACK_TEST
            throw NSError(domain: "test", code: 99)
            #else
            let v = try await ServerManager.pullViaNpx(registry: UpdateEngine.npmMirror,
                                                       distTag: distTag, progress: progress)
            if SemVer.compare(v, version) == 0 { return v }
            progress("  镜像同步滞后（返回 v\(v)），降级官方 tarball 直链…")
            #endif
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
            try await curl(version: version, to: tgz)
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

    private nonisolated static func curl(version: String, to dest: URL) async throws -> Int32 {
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
    #if ROLLBACK_TEST
    /// 无头测试桩注入的沙盒根（仅测试构建）
    static var testRoot: URL?
    #endif
    static var snapshotRoot: URL {
        #if ROLLBACK_TEST
        if let testRoot { return testRoot.appendingPathComponent("_npx-preupdate-snapshot") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx-preupdate-snapshot")
    }
    static var npxRootForOps: URL {
        #if ROLLBACK_TEST
        if let testRoot { return testRoot.appendingPathComponent("_npx") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx")
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
            if let bin = runningBin {
                let binPkg = bin.hasSuffix("/lib/bin.js") ? String(bin.dropLast("/lib/bin.js".count)) : bin
                if binPkg == pkg.path {
                    return (pkg, version)   // 运行中实例优先，直接命中
                }
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
        try? fm.removeItem(at: snapshotRoot)         // 幂等：清掉上次快照（首跑目录不存在不视为错误）
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

    /// 一键回滚：移除新增目录 → 清除版本不符残留 → 原子恢复快照 → 自愈校验。
    /// progress 逐行回报（经 ServerManager 转发到终端日志区）。
    static func rollback(progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw NSError(domain: "update", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "找不到更新前快照（manifest 缺失）"])
        }
        let fm = FileManager.default
        let npxRoot = npxRootForOps

        // ① 移除新增目录（FileManager 失败时 /bin/rm 兜底——实测有静默失败场景）
        for dir in manifest.installedNewDirs {
            try? fm.removeItem(at: npxRoot.appendingPathComponent(dir))
            forceRemove(npxRoot.appendingPathComponent(dir))
        }
        // ①' 清除版本不符残留：回滚语义=回到快照版本。残留异版本目录会被解析器
        // 按 mtime 优先命中 → 回滚失效（实测踩坑）
        if let entries = try? fm.contentsOfDirectory(atPath: npxRoot.path) {
            for entry in entries {
                let pkg = npxRoot.appendingPathComponent(entry)
                    .appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
                guard let data = try? Data(contentsOf: pkg),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let v = obj["version"] as? String, v != manifest.version else { continue }
                progress("  清除异版本残留目录 \(entry)（v\(v)）")
                try? fm.removeItem(at: npxRoot.appendingPathComponent(entry))
                forceRemove(npxRoot.appendingPathComponent(entry))
            }
        }

        // ② 原子恢复：先拷到同级临时位 → 校验完整性 → 再换入原位。
        // 【实测教训】"先删原位再拷"在快照内容异常时会留下空壳目录（入口丢失、
        // 依赖被清），且尾部无条件清快照导致无法二次恢复。
        let dest = URL(fileURLWithPath: manifest.sourcePath)
        let staging = dest.deletingLastPathComponent().appendingPathComponent("__dsh_restore_staging")
        try? fm.removeItem(at: staging)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [snapshotRoot.appendingPathComponent("package").path, staging.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              fm.fileExists(atPath: staging.appendingPathComponent("lib/bin.js").path) else {
            // 恢复材料不完整：保留快照供人工抢救，绝不清原位
            throw NSError(domain: "update", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "快照内容不完整（缺 lib/bin.js），已保留快照目录未动原位：\(snapshotRoot.path)"])
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)

        // ③ 自愈校验：恢复位完整即可收尾；不完整则联网重装快照版本（pinned distTag
        // = 具体版本号，npx 支持精确版本安装）
        if !fm.fileExists(atPath: dest.appendingPathComponent("lib/bin.js").path) {
            #if ROLLBACK_TEST
            progress("  [测试] 恢复位不完整（跳过联网自愈）")
            #else
            progress("  恢复位不完整，联网自愈重装 v\(manifest.version)…")
            _ = try? await ServerManager.pullViaNpx(
                registry: UpdateEngine.npmOfficial,
                distTag: manifest.version,
                progress: progress)
            #endif
        }
        // ④ 快照收尾：仅在恢复/自愈完成后清除
        try? fm.removeItem(at: snapshotRoot)
        return manifest.version
    }

    /// 强删兜底：FileManager.removeItem 对运行中进程占用的目录偶发静默失败，
    /// 退回 /bin/rm -rf（POSIX 语义对打开中的文件同样生效）
    private static func forceRemove(_ target: URL) {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/rm")
        proc.arguments = ["-rf", target.path]
        try? proc.run(); proc.waitUntilExit()
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

// MARK: - 前端应用自更新（v1.0.1）

/// 应用自身更新：GitHub Release 查询（防降级）→ 下载校验 → 暂存换壳 → 分离脚本换入并重启。
/// 与后端更新同一安全哲学：任一步失败不动现有安装；换壳动作由脱离本进程的脚本完成
/// （应用不能可靠地替换正在运行的自身）。
enum AppSelfUpdater {
    struct Release {
        let tag: String            // 形如 v1.0.1
        let version: String        // 去掉 v 前缀
        let zipURL: URL?           // 稳定名资产 DSH.MacOS.Desktop.zip
    }

    static func fetchLatestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/Farverge/DSH-MacOS/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("DSH-Desktop-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            var zipURL: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                zipURL = assets.compactMap { asset -> URL? in
                    guard let name = asset["name"] as? String, name == "DSH.MacOS.Desktop.zip",
                          let link = asset["browser_download_url"] as? String else { return nil }
                    return URL(string: link)
                }.first
            }
            return Release(tag: tag, version: version, zipURL: zipURL)
        } catch {
            return nil
        }
    }

    /// 下载 zip → 解包校验（.app 结构 + Info.plist 版本与 Release 一致）。
    /// 返回解包出的 .app 目录；任何不符抛错且不触碰 /Applications。
    static func downloadAndVerify(release: Release,
                                  progress: @escaping (String) -> Void) async throws -> URL {
        guard let zipURL = release.zipURL else {
            throw NSError(domain: "appupdate", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Release 缺少 DSH.MacOS.Desktop.zip 资产"])
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshapp-\(UUID().uuidString.prefix(8))")
        let zip = tmp.appendingPathExtension("zip")
        progress("→ \(zipURL.lastPathComponent)")
        let (data, response) = try await URLSession.shared.data(from: zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw NSError(domain: "appupdate", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）"])
        }
        try data.write(to: zip)
        progress("✓ 下载完成（\(data.count / 1024)KB）")

        // 解包与结构校验放后台线程
        let unpacked = try await Task.detached(priority: .userInitiated) { () -> URL in
            let fm = FileManager.default
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zip.path, tmp.path]   // ditto 解 zip 保权限
            try proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "appupdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "zip 解包失败"])
            }
            let app = tmp.appendingPathComponent("DSH Desktop.app")
            let plist = app.appendingPathComponent("Contents/Info.plist")
            guard fm.fileExists(atPath: plist.path),
                  fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/DSHDesktop").path),
                  let info = NSDictionary(contentsOf: plist),
                  let v = info["CFBundleShortVersionString"] as? String else {
                throw NSError(domain: "appupdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "包结构异常（缺 .app/Info.plist/可执行文件）"])
            }
            guard v == release.version else {
                throw NSError(domain: "appupdate", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "包内版本 \(v) 与 Release \(release.version) 不符，拒装"])
            }
            return app
        }.value
        progress("✓ 校验通过：DSH Desktop.app v\(release.version)")
        return unpacked
    }

    /// 换壳三部曲：新包暂存入 /Applications → 旧包移入备份区 → 分离脚本完成换入并重启。
    /// 本进程在脚本派生后立即退出（脚本 sleep 1 等本进程退干净）。
    static func swapAndRelaunch(newApp: URL,
                                progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/DSH Desktop.app")
        let staging = URL(fileURLWithPath: "/Applications/DSH Desktop.app.new")
        let backups = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DSH Backups")
        try? fm.removeItem(at: staging)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [newApp.path, staging.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "appupdate", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "暂存拷贝失败"])
        }
        // 暂存已完整，下载/解包的临时目录可清（/tmp 系统兜底，此处主动收尾）
        try? fm.removeItem(at: newApp.deletingLastPathComponent())
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let script = """
        #!/bin/bash
        sleep 1
        mv '/Applications/DSH Desktop.app' '\(backups.path)/DSH Desktop.app.bak-\(stamp)' 2>/dev/null
        mv '/Applications/DSH Desktop.app.new' '/Applications/DSH Desktop.app' || { mv '\(backups.path)/DSH Desktop.app.bak-\(stamp)' '/Applications/DSH Desktop.app'; exit 1; }
        open '/Applications/DSH Desktop.app'
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-swap-\(UUID().uuidString.prefix(6)).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // 分离执行：nohup 让脚本脱离本进程生命周期；应用随后退出
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [scriptURL.path]
        runner.qualityOfService = .userInitiated
        try runner.run()
        progress("✓ 换壳脚本已派生，应用即将退出并由新版接管")
    }
}
