# DSH Desktop

> DeepSeek Harness（`dsh`）的 macOS 极致轻量桌面外壳

## 前言

这是一个独立的社区开源项目，**并非 DeepSeek 官方出品**，与 DeepSeek 及其关联方无任何隶属、合作或背书关系。它把官方的 dsh Web 界面装进一个约 850 KB 的原生 macOS 窗口里，并代为管理后端服务器进程——不重写官方界面的任何一部分，因此官方的功能演进与 Cordis 插件生态在这里 100% 可用。

## 目录

| 章节 | 内容 |
|---|---|
| [一键安装](#一键安装) | 三段式部署：环境预检 → 安装 → 状态回馈 |
| [桌面效果](#桌面效果) | 浅色 / 深色模式实拍 |
| [它是什么](#它是什么) | 功能清单与定位 |
| [它是如何工作的](#它是如何工作的) | 四层架构与设计决策速览 |
| [安全与风险](#安全与风险) | 公网暴露警示与本项目的安全边界 |
| [注意事项](#注意事项) | 使用前提与已知边界 |
| [免责声明](#免责声明) | 法律与担保条款 |
| [查看更多](#查看更多) | Wiki 文档导航 |
| [友情链接](#友情链接) | 官方上游仓库 |
| [许可证](#许可证) | 开源协议 |

## 一键安装

打开终端，复制粘贴这一条命令：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-MacOS/main/install.sh | bash
```

也可以**复制这段命令发给你正在使用的 AI agent**，它会自动完成安装部署并处理过程中的所有提示。

脚本执行的三段式流程：

1. **环境预检**——macOS 版本、架构、Node.js、必备工具、既有安装、端口占用状况逐项检查并给出 ✓/! 标记
2. **下载安装**——从 Releases 拉取最新版，温和退出运行中的旧实例后替换升级
3. **状态回馈**——自动启动应用，探测后端就绪状态，末尾输出 `KEY=VALUE` 摘要行（供 agent 直接解析）

另有**只读体检模式**，随时给本机做一套应用体检（报告同样可发给 agent 自动处理）：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-MacOS/main/install.sh | bash -s -- doctor
```

体检覆盖：系统版本、应用安装与签名、Node.js、3080 端口身份与健康、桥接接口、npx 缓存副本数、失效解析缓存。追加 `--fix` 可执行白名单内的安全修复（如清理失效缓存）。

## 桌面效果

浅色模式：

![浅色模式](docs/screenshots/light-mode.png)

深色模式：

![深色模式](docs/screenshots/dark-mode.png)

## 它是什么

- **内嵌官方 Web GUI**：WKWebView 加载本地 dsh 服务，沉浸式窗口跟随系统深浅色
- **后端进程全托管**：启动时以「HTTP 200 + 官方标记」双重身份探测已有实例并直接接管（绝不双开后端），六级命令解析链摆脱 PATH 依赖，健康轮询 + 断连横幅自动重试且不丢页面状态
- **会话导出**：自动保存到「下载」文件夹并弹系统通知、定位文件
- **桌面布局 overlay**：红绿灯锚定的沉浸式标题栏、折叠侧栏居中适配——纯 CSS 实现，跟随官方界面更新
- **DSH 后端更新**：设置里一键检查，镜像源加速下载、完整性校验、自动清理旧缓存（跳过使用中的目录）并重启
- **桥接插件**：向系统注入服务器状态接口（pid / 版本 / 运行时长），并为插件生态预留原生通知通道
- **可选菜单栏插件 DSH Launcher**：独立小应用，鲸鱼常驻菜单栏一键唤起

## 它是如何工作的

四层薄壳架构，每一层都只做最少的事：

```text
UI 层      SwiftUI/AppKit —— 状态面板 ⇄ WebView 切换、原生菜单、设置
Web 层     WKWebView 内嵌官方 GUI + 纯 CSS 布局 overlay
进程层     ServerManager —— 身份探测/唯一性保证/解析链/轮询/更新链
桥接层     dsh-desktop-bridge 插件（status / notify 路由）
```

核心思路：**官方 UI 是 Cordis 插件集，装进 WebView 就能自动获得全部桌面能力**。外壳只负责三件事——把网页装进原生窗口（含导出拦截、通知、断连保护）、替用户管好 node 后端的生命周期、用纯 CSS 把官方界面的几何对齐到 macOS 窗口规范（红绿灯锚定、侧栏居中）。完整分层说明与设计决策见 Wiki 的 Architecture 页。

## 安全与风险

dsh 的 Web 控制平面**没有内置认证层**（无 token / cookie / TLS）。上游仓库的安全讨论（[deepseek-ai/deepseek-harness #853](https://github.com/deepseek-ai/deepseek-harness/discussions/853)）指出：其唯一的 Host/Origin 栅栏被源码自述为"不是认证层"，若把服务端口暴露到回环地址之外（端口转发、隧道、绑定 0.0.0.0 等），存在**未经身份验证的代码执行风险**——默认回环部署定级 High，非回环部署定级 Critical。奇安信等安全厂商亦有公开报道。

本项目的设计边界与你的使用准则：

- ✅ 本应用**固定将后端绑定在 127.0.0.1（仅本机回环）**，不提供任何改绑公网接口的选项，天然规避公网暴露面
- ✅ 请勿通过路由器端口映射、frp/ngrok 等隧道、反向代理把 3080 端口暴露到局域网或公网；确需远程使用，请自行叠加带认证的反代与 TLS，并自担风险
- ✅ 及时通过设置内的「检查 DSH 更新」保持后端为最新版本，跟进上游安全修复
- ⚠️ 与任何本地服务一样，本机其他恶意程序理论上可访问回环端口；请保持正常的 macOS 安全习惯

## 注意事项

- 需要 **macOS 13+** 与 **Node.js**；端口固定使用 3080
- 关闭窗口 ≠ 退出（Dock 常驻），彻底退出用 Cmd+Q；默认退出时会带走由应用启动的后端
- 升级不影响系统授权（稳定化 ad-hoc 签名，identifier 规则跨构建有效）
- 本项目按"现状"提供，更新后端依赖第三方镜像源与网络环境，请遵守所在地区法规及上游服务协议

## 免责声明

本项目是独立的社区开源项目，**并非 DeepSeek 官方出品**，与 DeepSeek 及其关联方不存在任何隶属、合作或背书关系。"DeepSeek""DeepSeek Harness"及相关名称、标识的权利归其权利人所有，本项目仅在指代意义上使用。

本软件按"现状"（AS IS）提供，不含任何明示或默示的担保。使用者需自行承担因安装、使用本软件所产生的全部风险与责任，包括但不限于数据丢失、服务中断或第三方平台条款问题。如本项目有任何侵权或不当之处，请联系仓库维护者，我们将及时处理。

## 查看更多

完整文档托管于本仓库 Wiki（两镜像仓库内容一致）：

| 页面 | 内容 |
|---|---|
| [Architecture（架构）](https://github.com/Farverge/DSH-MacOS/wiki/Architecture) | 分层设计、六级解析链、overlay v3 策略、设计决策全记录 |
| [Build（构建）](https://github.com/Farverge/DSH-MacOS/wiki/Build) | 从源码构建、稳定化签名原理、发版资产约定 |
| [Usage（使用）](https://github.com/Farverge/DSH-MacOS/wiki/Usage) | 安装、界面、设置、通知、导出全指南 |
| [Update（更新）](https://github.com/Farverge/DSH-MacOS/wiki/Update) | 后端更新与应用更新的准确流程与排障 |
| [Security（安全与风险）](https://github.com/Farverge/DSH-MacOS/wiki/Security) | 上游安全事件详情、本项目边界、加固清单 |
| [Doctor（体检命令）](https://github.com/Farverge/DSH-MacOS/wiki/Doctor) | doctor 子命令的检查项、--fix 白名单与 agent 集成示例 |
| [FAQ](https://github.com/Farverge/DSH-MacOS/wiki/FAQ) | 常见问题排查 |
| [Changelog（版本历史）](https://github.com/Farverge/DSH-MacOS/wiki/Changelog) | v1.0.0 变更全记录 |

## 友情链接

- DeepSeek Harness（官方上游）：https://github.com/deepseek-ai/deepseek-harness

## 许可证

本项目当前以 MIT License 发布（详见 [LICENSE](LICENSE)），与其依赖的上游 DSH 保持一致。许可证选型的进一步讨论进行中，如有调整会在本节同步更新。
