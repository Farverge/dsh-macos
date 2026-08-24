# 更新

本应用有两个独立更新入口，都在 **设置 → 关于**。

---

## 1. DSH 后端更新（核心）

**入口**：设置 → 关于 → **检查 DSH 更新**

### 准确流程

1. **联网查询** `@deepseek-ai/dsh@latest`（npm view，纯查询，不停服、不下载）
2. **无新版** → 提示"已是最新版本"，结束
3. **有新版** → 弹确认框；点「现在更新并重启」后依次执行：
   - 镜像源拉取最新 dsh（registry.npmmirror.com，PTY 实时进度，后台进程不受关窗影响）
   - 完整性校验（退出码 + 版本号合规 + package.json 存在）
   - 清理 `~/.npm/_npx` 旧/残缺缓存——**使用中的目录一律跳过**：包括当前解析命令指向的目录、以及任何运行中进程命令行引用的目录（保护终端侧并行会话）
   - 停掉旧服务器 → 冷启动新后端
4. 任一步失败都不碰现有服务器，继续运行旧版
5. 更新进行中退出应用有 `isUpdating` 保护，不会误杀刚换上的新后端

### 桥接版本显示的生效时机

更新后的首次冷启动会让桥接插件重新加载，设置页「桥接信息」即显示真实后端版本（如 `dsh v0.1.1-rc.2`）。仅重启桌面应用而后端存活（attach）时不会刷新插件，属预期。

## 2. 应用本体更新（DSH Desktop）

- 重新运行一键安装命令即可覆盖到最新版：

```bash
curl -fsSL https://raw.githubusercontent.com/iiiiiei/DSH-MacOS/main/install.sh | bash
```

- 或到 [Releases](https://github.com/iiiiiei/DSH-MacOS/releases) 手动下载 `DSH MacOS Desktop.zip`
- 应用内「检查应用更新」读取 GitHub Releases 最新 tag 与本地版本比对，只提示不自动安装；需仓库已有 Release

### 权限说明

本项目采用稳定化 ad-hoc 签名（identifier Designated Requirement），**正常情况下升级不影响系统授权**。若从极早期版本升级后遇到辅助功能类授权失效，执行一次：

```bash
tccutil reset Accessibility com.deepseek-ai.dsh-desktop
```

然后到系统设置重新勾选 `/Applications` 里的 DSH Desktop.app 即可，此后跨版本永久稳定。

## 3. 排障

| 现象 | 处理 |
|---|---|
| "检查 DSH 更新"查询失败 | 确认能访问 npm registry 与镜像源 |
| "检查应用更新"请求失败 | 仓库需已有 Release |
| 更新很久没动静 | 观察进度区；镜像源偶发慢属正常，稍等或重试 |
| 更新后服务器没自动起来 | 菜单「启动服务器」，或走设置重试一次检查更新 |

---

免责声明见仓库 [README](../../README.md#免责声明)
