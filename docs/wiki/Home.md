# DSH Desktop Wiki

欢迎来到 **DSH Desktop** 的文档。DSH Desktop 是 DeepSeek Harness（`dsh`）的 macOS 社区桌面外壳。

> **定位声明**：社区项目，**非 DeepSeek 官方出品**，与官方无隶属、合作或背书关系。复用官方 `@deepseek-ai/dsh` 后端与 Web UI（MIT），以原生 macOS 技术装进桌面应用并代管服务器进程。完整免责声明见 [README](../../README.md#免责声明)。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-MacOS/main/install.sh | bash
```

前提：macOS 13+、已安装 Node.js。

## 它解决什么问题

| 场景 | 命令行 dsh | DSH Desktop |
|---|---|---|
| 启动 Web GUI | 手动 `dsh web` + 浏览器 | 双击即用，窗口内呈现官方 GUI |
| 管理服务器进程 | 手动启停 | 身份探测 attach / 唯一性保证 / 健康轮询 |
| 通知 | 无 | UserNotifications 原生通知 |
| 会话导出 | 手动 | 拦截保存到 `~/Downloads` + 通知 + Finder 定位 |
| 断连 | 页面失效 | WebView 保留 + 顶部横幅自动重试 |
| 更新 | 手动 npm | 先查后问：镜像拉取→校验→清缓存→自动重启 |

## 文档导航

| 页面 | 适合 | 内容 |
|---|---|---|
| [架构](Architecture.md) | 开发者 | 分层设计、解析链、overlay v3 策略、设计决策 |
| [构建](Build.md) | 维护者 | 编译、稳定化签名、打包发版约定 |
| [使用](Usage.md) | 所有用户 | 安装、界面、设置、插件、通知、导出 |
| [更新](Update.md) | 所有用户 | DSH 后端更新与应用更新的准确流程 |
| [常见问题](FAQ.md) | 所有用户 | 现象与排查 |
| [版本历史](Changelog.md) | 所有人 | v1.0.0 变更全记录 |

## 快速 FAQ

- **冷启动多快？** 实测约 1 秒到 Web GUI 就绪（缓存命中时）
- **要装 Node.js？** 需要，dsh 后端是 Node 程序
- **怎么退出？** Cmd+Q（关窗口不退出，Dock 常驻）
- **菜单栏插件是什么？** 可选的 DSH Launcher（独立仓库），不装不影响

更多见 [FAQ](FAQ.md)。

---

维护：DSH Desktop 社区 · 许可：MIT · 免责声明见 README
