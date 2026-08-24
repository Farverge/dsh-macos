# DSH Desktop

> DeepSeek Harness（`dsh`）的 macOS 极致轻量桌面外壳 · 社区项目 · 非官方出品

原生 SwiftUI/AppKit 壳（应用本体约 850 KB），把 DSH 官方 Web GUI 装进原生窗口，并自动管理 dsh 服务器进程。**不重写官方界面**——Cordis 插件生态 100% 保留，官方 UI 更新即刻可用。

```text
双击 → 冷启动（约 1 秒）→ dsh 后端自动拉起 → 窗口内呈现官方 Web GUI
```

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/iiiiiei/DSH-MacOS/main/install.sh | bash
```

- 自动下载最新 Release、安装到 `/Applications` 并启动（curl 安装不带隔离标记，无 Gatekeeper 拦截）
- 前提：**macOS 13+**、已安装 **Node.js**（终端 `node -v` 有输出）
- 镜像仓库用户：把命令中的 `iiiiiei` 换成 `Farverge` 即可

## 功能

- **内嵌官方 Web GUI**：WKWebView 加载 `http://127.0.0.1:3080/`，沉浸式窗口跟随系统深色模式
- **后端进程全托管**
  - 启动时双重身份探测（HTTP 200 + 官方 `__DSH_BOOT__` 标记）：已有健康实例则 attach，绝不重复拉起第二个后端
  - 零 PATH 依赖：六级命令解析链 + 来源绑定缓存，双击场景（launchd 极简 PATH）照常工作
  - 健康轮询：启动阶段 0.5s、稳态 5s；外部实例下「停止服务器」菜单自动禁用
  - 断连韧性：瞬时断连保留页面状态，顶部横幅提示自动重试，不销毁 WebView
- **会话导出**：拦截 `/api/session.export` → 原生保存到 `~/Downloads` + 系统通知 + Finder 定位
- **原生菜单与通知**：「服务器」菜单集全部操作；UserNotifications 原生通知（首次启动预请求授权）
- **桌面布局 overlay（v3 纯 CSS）**：红绿灯锚定参考系、折叠态 86px 外壳列居中 56px 轨、logo 行对齐顶栏底线；选择器只挂官方字面量 data 属性与语义类名，抗官方重建
- **桥接插件（dsh-desktop-bridge，已内置部署）**：`GET /api/desktop/status` 供设置页展示 pid / 版本 / 运行时长；`POST /api/desktop/notify` 为生态预留的原生通知通道
- **DSH 后端更新**：先查后问 → 镜像源拉取（PTY 实时进度）→ 完整性校验 → 清理旧缓存（跳过使用中目录）→ 自动重启；任何一步失败都不碰现有服务器
- **稳定化签名**：ad-hoc + identifier 规则的 Designated Requirement，系统授权（辅助功能等）跨构建持续有效

## 快速开始（从源码构建）

需要 macOS 13+ 与 Command Line Tools（无需完整 Xcode）：

```bash
bash scripts/build.sh
open "build/DSH Desktop.app"
```

产物：`build/DSH Desktop.app`。若本机 CLT 处于半更新状态报 `redefinition of module 'SwiftBridging'`，脚本会经 `-vfsoverlay` 自动绕过。

## 设置项（Cmd+,）

| 设置 | 默认 | 说明 |
|---|---|---|
| 端口 | 3080 | 只读。后端固定监听端口 |
| 启动命令 | `dsh --profile web` | 解析为绝对路径后执行，端口自动追加；修改后缓存即时失效 |
| 启动应用时自动启动服务器 | 开 | 无健康实例时自动冷启动 |
| 退出应用时保持服务器运行 | 关 | 默认退出即带走自启的后端 |
| 开机自动启动 | 关 | SMAppService 实现 |

## 更新机制

设置 → 关于 → 检查 DSH 更新：

1. 联网查询 `@deepseek-ai/dsh@latest` 并与当前版本对比；无新版不停服
2. 确认后执行：镜像源拉取（registry.npmmirror.com，PTY 实时进度）→ 完整性校验 → 清理旧缓存 → 停服 → 冷启动新后端
3. 任一步失败不动旧版；更新中退出有 `isUpdating` 保护，不会误杀新后端

应用本体更新：重新运行一键安装命令，或到 [Releases](https://github.com/iiiiiei/DSH-MacOS/releases) 下载。

## 架构

```text
┌──────────────────────────────────────────────────┐
│ UI 层（SwiftUI / AppKit）                         │
│   主窗口（状态面板 ⇄ WebView）· 服务器菜单 · 设置  │
├──────────────────────────────────────────────────┤
│ Web 层（WebKit）                                  │
│   WKWebView 内嵌官方 GUI · 导出拦截 · 断连横幅     │
│   desktop-layout.js（纯 CSS overlay）             │
├──────────────────────────────────────────────────┤
│ 进程层（ServerManager）                           │
│   身份探测 attach → 唯一性复查 → 六级解析(缓存)    │
│   → spawn → 双频轮询 → 优雅停止                   │
│   更新链：查询→确认→拉取→校验→清缓存→停服→重启     │
├──────────────────────────────────────────────────┤
│ 桥接层                                            │
│   dsh-desktop-bridge 插件（status / notify）      │
│   MenuBarPluginManager（可选 DSH Launcher）       │
└──────────────────────────────────────────────────┘
```

### 设计要点

1. **不重写官方 UI**：内嵌 WebView 让所有 Cordis 插件自动获得桌面 UI
2. **零 PATH 依赖**：六级解析链按确定性降级，成功后缓存并与配置来源绑定
3. **后端唯一**：spawn 前以官方标记复核身份，杜绝双后端与误 attach
4. **状态发布纪律**：秒级变化的数据不走 `@Published`，避免高频重建拖动整个 scene（曾诱发系统菜单裁剪问题）
5. **更新安全**：先查后问；失败不碰旧版；更新中退出不误杀新后端；清理缓存前保护使用中目录
6. **布局不碰官方源码**：overlay 只挂官方字面量 data 属性与语义类名，纯 CSS 零 JS

## 目录结构

```text
dsh-macos/
├── install.sh                     # 一键安装脚本（curl | bash）
├── Sources/DSHDesktop/
│   ├── DSHDesktopApp.swift        # 入口；菜单 + AppDelegate（沉浸式标题栏）
│   ├── AppState.swift             # 全局状态 + UserDefaults 设置
│   ├── ServerManager.swift        # 进程管理 · 解析链 · 更新链 · 缓存保护
│   ├── WebView.swift              # WKWebView 封装（导航/导出/权限/overlay）
│   ├── ContentView.swift          # 状态面板 ⇄ Web GUI 切换 + 断连横幅
│   ├── SettingsView.swift         # 设置窗口（含更新、插件管理）
│   ├── BridgeClient.swift         # 轮询 /api/desktop/status
│   ├── MenuBarPluginManager.swift # 可选菜单栏插件检测/控制
│   └── DesktopLayout.swift        # 布局常量 + 拖拽带
├── bridge/dsh-desktop-bridge/     # 桥接插件源码（与部署副本一致）
├── Resources/
│   ├── Info.plist                 # 版本 1.0.0
│   ├── whale.svg                  # 图标源
│   └── overlays/desktop-layout.js # 纯 CSS 布局 overlay
├── docs/
│   ├── USER-GUIDE.md              # 使用说明书
│   └── wiki/                      # Architecture / Build / Usage / Update / FAQ / Home / Changelog
└── scripts/
    ├── build.sh                   # 编译 + 打包 .app + 图标 + 稳定化签名
    └── make-icon.swift            # 图标生成（白底黑鲸）
```

## 发版约定

每个 Release 附带资产 **`DSH MacOS Desktop.zip`**（内含根级 `DSH Desktop.app`），`install.sh` 依据该命名命中最新版本。

## 常见问题

| 问题 | 处理 |
|---|---|
| 点「启动服务器」报找不到命令 | 保持默认启动命令；六级解析链会兜底到 npx 缓存或绝对 npx |
| 端口被占用（3080） | 应用会校验身份后 attach 已存在的 DSH 实例（退出时不带走）；陌生服务不会被误认 |
| 页面加载失败 | 菜单 → 刷新页面；断连时会看到横幅自动重试 |
| 折叠侧栏按钮位置不对 | 确认使用最新版 overlay（v3+）；刷新页面即可生效 |
| 升级后辅助功能授权失效 | 本项目已采用稳定化签名，正常不会再发生；历史遗留执行一次 `tccutil reset Accessibility com.deepseek-ai.dsh-desktop` 后重新勾选即可 |
| 分发给他人报"已损坏" | 请对方使用一键安装命令（curl 安装无隔离标记），或自行移除 quarantine |

更多见 [docs/wiki](docs/wiki/Home.md) 与 [使用说明书](docs/USER-GUIDE.md)。

## 免责声明

本项目是独立的社区开源项目，**并非 DeepSeek 官方出品**，与 DeepSeek 及其关联方不存在任何隶属、合作或背书关系。"DeepSeek""DeepSeek Harness"及相关名称、标识的权利归其权利人所有，本项目仅在指代意义上使用。

本软件按"现状"（AS IS）提供，不含任何明示或默示的担保。使用者需自行承担因安装、使用本软件所产生的全部风险与责任，包括但不限于数据丢失、服务中断或第三方平台条款问题。对 dsh 后端的下载与更新依赖第三方镜像源与网络环境，请在使用中遵守所在地区法律法规及上游服务的用户协议。

如本项目有任何侵权或不当之处，请联系仓库维护者，我们将及时处理。

## 许可

MIT License，与 DSH 上游保持一致，详见 [LICENSE](LICENSE)。
