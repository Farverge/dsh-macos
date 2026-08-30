# 版本历史

## v1.0.1（2026-08-31）

更新模块全面强化（三级链 + 自检回滚 + 双通道弹窗）：

- **三级版本查询**：npm 官方 → npmmirror → GitHub tags 兜底；返回稳定线与 alpha 线
- **三级下载安装**：npx@官方 → npx@镜像 → 官方 tarball 直链；版本一致性校验
- **更新前快照**：整目录备份 + manifest 差集登记（回滚锚点）
- **后端切换修正**：attach 模式下外部实例显式停止（此前新版起不来、自检假通过）
- **兼容性自检**：根页面/桥接/mini 三探针 + 3 秒稳定性复探；失败弹回滚对话框
- **一键回滚**：异版本残留清理、staging 原子恢复、恢复不完整联网自愈重装
- **双通道弹窗**：rc 稳定版确认框与 alpha 预发布警示框（列明已知影响）分离
- **修正**：版本提取整行倒序匹配（npm 弃用警告误抓）、currentDSHVersion 优先取桥接在线值（缓存陈旧值曾致 alpha 提示消失）
- **质量**：自审修复 P0×1/P1×3/P2×2；alpha 真机全链实测（安装→自检失败→回滚弹窗→执行）；回滚文件逻辑无头断言 10/10

## v1.0.0

首个公开版本。

### 功能

- 原生 macOS 外壳（SwiftUI / AppKit，应用本体约 850 KB）+ WKWebView 内嵌官方 Web GUI
- dsh 后端进程托管：attach 探测 → spawn 前唯一性复查 → 六级命令解析链（来源绑定缓存）→ 双频健康轮询 → 优雅停止（terminate + 超时 SIGKILL）
- attach 身份双重校验（HTTP 200 + 根页面 `__DSH_BOOT__` 官方标记），外部实例退出时不带走、「停止服务器」菜单自动禁用
- 断连韧性：瞬时断连保留 WebView 与 SPA 会话位置，页内横幅提示自动重试；手动停止/进程崩溃仍回状态面板
- 桌面布局 overlay v3（纯 CSS）：红绿灯锚定 (23,23)、折叠态 86px 外壳列 + 36px 内容盒居中、logo 行对齐顶栏底线；选择器只依赖官方字面量 data 属性（`data-sidebar-collapsed` 等）、槽位锚点（`data-slot="sidebar"`）与语义类名，抗官方重建；尊重系统减少动态效果设置
- 会话导出拦截：原生下载至 `~/Downloads` + UserNotifications 通知 + Finder 定位
- 原生通知通道：启动预请求授权；前台横幅展示
- DSH 后端更新链：联网查询 → 确认 → 镜像源拉取（PTY 实时进度）→ 完整性校验 → 清理旧/残缺缓存 → 停服 → 冷启动；`isUpdating` 防误杀；清理前保护自身与终端侧使用中的 npx 缓存目录
- 桥接插件 dsh-desktop-bridge（源码随仓库 `bridge/`，部署副本位于 `~/.dsh/profiles/node_modules/`）：status 路由供设置页展示（pid / 版本 / 运行时长），notify 路由为生态预留；版本字段经模块解析报告真实后端版本
- 可选菜单栏插件（DSH Launcher，独立仓库）：按 bundleID 精确检测、启停管理
- 稳定化 ad-hoc 签名（identifier Designated Requirement）：辅助功能等系统授权跨构建持续有效
- 一键安装脚本 `install.sh`：curl | bash，下载最新 Release 安装并启动（无隔离标记、无 Gatekeeper 拦截）

### 修复（相对开发期中间版本的演进记录）

- 启动命令解析缓存绑定配置来源：修改「启动命令」立即生效，不再被旧缓存绑架
- `stop()` 延迟 SIGKILL 以进程实例身份比对：3 秒窗口内重启不会误杀新后端
- WebView Coordinator 两处块观察者 token 存储并在 deinit 移除，消除重建泄漏
- attach 探测返回后复查进程归属，杜绝把自启服务器误标为外部实例（退出孤儿问题）
- 折叠动画改用可插值的对称内边距方案（替代不可插值的限宽跳变），消除控件闪现感
- 桥接明细移出 `@Published`：消除秒级 objectWillChange 空转，修复「窗口菜单展开期间原生项被渐进裁剪」的系统级症状
- 命令解析首 token 单次替换：`dsh --tag dsh` 类命令不再被误改
- `isDSHInstance` 采用 lossy 解码，64KB 截断多字节字符不再导致身份误判

### 已知边界（有意保留 / 记录在案）

- `stopAndWait()` 在主线程忙等 ≤4s（仅更新收尾与退出路径调用）
- 更新锁占用期间按钮静默忽略重复点击
- 启动命令经 zsh 执行属用户可信输入，未做 argv 边界拆分
- 折叠态新建会话按钮悬停为 12px 圆角方块（官方样式原样保留）
- 折叠态鲸鱼图形含 2px 视觉配重位移（可在 overlay 中调整）

---

许可：MIT · 免责声明见仓库 README
