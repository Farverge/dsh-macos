# DSH Desktop v1.0.1 更新模块规格书（三级链 + 自检回滚 + 双弹窗）

> 开发代理按本规格实施。只改 `/Users/iiiiiei/Desktop/dsh-macos-dev`，禁止部署、禁止碰 `/Applications`、禁止重启任何进程。

## 现状锚点（先读后改）
- `Sources/DSHDesktop/ServerManager.swift`（794 行）：`fetchLatestDSHVersion`(npm view 单源) / `_pull`(npx @latest 钉死镜像) / `checkDSHUpdate` / `applyDSHUpdate` / `npmMirror` 常量
- `Sources/DSHDesktop/SettingsView.swift`：`showUpdateConfirm` 弹窗（= rc 弹窗）、`checkDSHUpdate` 调用处、`server.onUpdateProgress`
- 事实：npm dist-tags = {latest:0.1.1-rc.2, alpha:0.1.2-alpha.2}；GitHub tags 形如 `dsh-v0.1.2-alpha.2`；官方 tarball 直链 `https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-<version>.tgz`

## 交付一：新文件 `Sources/DSHDesktop/UpdateEngine.swift`

全部 `@MainActor` 除非标注 nonisolated；中文注释含【语义陷阱备忘】风格；URLSession 一律 `cachePolicy=.reloadIgnoringLocalCacheData` + `timeoutInterval=8`。

### 1. 版本与结构
```swift
struct UpdateAvailability { let stable: String?; let alpha: String?; let source: QuerySource }
enum QuerySource: String { case official, mirror, github }
struct CheckResult: Identifiable { let id: String; let name: String; let ok: Bool; let detail: String }
enum SemVer { static func compare(_ a: String, _ b: String) -> Int }  // 逐段数字比较；prerelease(-rc/-alpha) 同号时 < 正式版
```

### 2. 三级查询 `UpdateEngine.fetchAvailability() async -> UpdateAvailability`
- T1 URLSession GET `https://registry.npmjs.org/@deepseek-ai/dsh` → 解析 `dist-tags.latest` 与 `dist-tags.alpha`（完整 JSON 较大，可用 `https://registry.npmjs.org/@deepseek-ai/dsh/latest` 拿 latest？——不行，该端点不含 alpha。就用全量 JSON + JSONSerialization 取 dist-tags，可接受一次性下载）
- T1 失败/超时 → T2 同法 `https://registry.npmmirror.com/@deepseek-ai/dsh`。设计取舍写注释：逐级只在失败时降级，不做双源比对——镜像滞后仅导致"晚发现"，不会误报（安装校验兜底）
- 双双失败 → T3 `https://api.github.com/repos/deepseek-ai/deepseek-harness/tags?per_page=100`（匿名额度足够）→ 过滤 `dsh-v` 前缀取 SemVer 最大者为 stable；**alpha=nil**（GitHub 兜底只保稳定线真相）
- 全失败 → stable=nil（UI 提示网络故障）

### 3. 三级安装 `UpdateInstaller.install(distTag:version:progress:) async throws -> String`
- T1：复用现有 PTY 模式：`/usr/bin/script -q /dev/null <npx> --registry=https://registry.npmjs.org --yes @deepseek-ai/dsh@<distTag> --version`，180s 总超时；成功判据=退出码 0 + 输出版本正则 `\d+\.\d+\.\d+([-.][^\s]*)?` 且 SemVer.compare(输出,version)==0（防镜像滞后装到旧版）
- T1 超时(>60s 无输出亦可早断)或失败 → T2 同命令 `--registry=https://registry.npmmirror.com`（现行为）
- T2 失败 → T3 裸 HTTP 直链：`curl -fSL --max-time 120 -o $TMP/dsh.tgz https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-<version>.tgz` → 校验非空 + gzip 魔数 → `tar -xzf` 到 `~/.npm/_npx/update-fallback-<uuid>/node_modules/@deepseek-ai/dsh`（tgz 内有 package/ 前缀，解包后改名；resolveCommand 第四级扫描 _npx 任意子目录，天然可发现）
- 返回实际版本；进度经 progress 回调（与现有 onUpdateProgress 管线对接）

### 4. 快照/自检/回滚 `UpdateSafety`
- `snapshotCurrent() -> URL?`：定位当前 dsh 缓存目录（复用 ServerManager 解析结果或自查 `~/.npm/_npx/*/node_modules/@deepseek-ai/dsh` 取 mtime 最新且被当前进程引用者）→ `ditto` 到 `~/.npm/_npx-preupdate-snapshot/`；同目录写 `manifest.json` {sourcePath, version, installedNewDirs:[]}（installedNewDirs 由 install 阶段登记 T3 的新目录）
- `selfCheck() async -> [CheckResult]` 三项（每项 10s 超时）：
  ① 根页面 `GET /`：200=过；401/302=败（detail 注明"新版启用了浏览器认证，当前壳尚未适配"）
  ② 桥接 `GET /api/desktop/status`：200 且 ok:true=过
  ③ 插件路由 `GET /api/mini/options`：200=过；404=败（detail"mini-dialog 插件未随新后端加载"）
- `rollback() async throws`：读 manifest → 移除 installedNewDirs → 恢复快照回 sourcePath → 清快照目录 → 杀 3080 进程并等健康（≤15s）

## 交付二：ServerManager.swift 手术式改造
- `checkDSHUpdate` 结果类型改为携带 `UpdateAvailability`（保持 async 回调风格）；内部改调 `UpdateEngine.fetchAvailability()`
- `applyDSHUpdate` 增加 `distTag` 参数（默认 "latest"）：流程=快照→install(distTag)→重启后端→`UpdateSafety.selfCheck()`→全过回调 success；有败项回调 `needsRollback(failures:[CheckResult])`
- 新增 `rollbackFromFailedUpdate()` 供 UI 调用

## 交付三：SettingsView.swift 手术式改造（双弹窗）
- **rc 弹窗**（沿用现有 alert，文案补"稳定版通道"）：仅当 stable>current 时出现
- **alpha 提示与弹窗**：updateMessage 区附一行"发现预发布 `<alpha>`（体验通道）" + 独立按钮「安装预发布版」→ 专用 alert：警示图标文案（预发布可能不稳定；列出已知影响：浏览器认证链将启用，旧版壳可能出现 401，自检不过可一键回滚）+ [仍要安装][取消]
- **自检失败弹窗**：列失败项 name+detail，按钮 [重试自检] [回滚到更新前版本并重启] [暂不处理]；回滚后 updateMessage 显示"已回滚至 v<old>"
- 全部主线程 UI；进度区沿用 showUpdateLog 终端样式

## 验收（代理自测）
1. `swiftc -O -target arm64-apple-macosx13.0 -vfsoverlay <dev>/.build/toolchain-fix/overlay.yaml Sources/DSHDesktop/*.swift -o /tmp/v101-build` 零 error（vfsoverlay 由 scripts/build.sh 首跑生成，或手写同款 JSON）
2. `git diff --stat` 报告；新增文件行数 <450；ServerManager/SettingsView 改动 <120 行
3. 不运行任何后端/网络安装实测（我负责后续真机环节）

## 风格红线
注释中文；不改无关代码；不引入第三方依赖；Process/URLSession 均设置超时；错误走 throws/回调，不 fatalError
