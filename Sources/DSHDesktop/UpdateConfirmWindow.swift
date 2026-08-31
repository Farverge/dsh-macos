import AppKit

// MARK: - 更新确认独立窗（v1.0.2 立 / v1.0.3 重排 / v1.0.4 修动态与居中 / 本次弃栈）
//
// 为什么用 NSWindow 而不是 SwiftUI .sheet：设置页是 macOS 分组 Form，sheet 高度
// 受表单布局制约，长更新说明显示不全（用户反馈的"小窗显示不全"正是此因）。
// 范式参照 dsh-launcher 的 CheckupWindow.swift：独立 NSWindow + NSScrollView +
// NSTextView，notes 只读可滚动、可选中复制。四条更新链路（后端 rc / 后端 alpha /
// 前端应用 / Launcher）共用这一个壳，只换文案与确认回调。
//
// 【为什么不再用 NSStackView 排纵向布局（三次翻车的教训）】
// v1.0.4 前后真机实测踩满三坑：① 默认"重力区"分布把窗口增量的高度变成行间空白；
// ② 行内 340@750 高度锚与栈拉伸打架，宽高同拉时约束无解、空白落进脚注与按钮间；
// ③ alignment=.width 对单行换行标签的行宽/行位语义不可控——AX 实测版本行/红行/
// 脚注整体右贴边（右缘=内容右缘），橙行却全宽，三行各挂各的。本次改为手写约束：
// 每行显式钉满内容宽，头部三行合并为一个全宽字段，居中由段样式唯一决定，
// 不再依赖任何字段的 frame 排布。

/// ESC 即取消：NSWindow 本身不响应 Escape（没有 sheet 的 cancel 语义），
/// 借 cancelOperation 响应链补齐（首个响应者未处理时会冒泡到窗口）。
final class UpdateConfirmWindow: NSWindow {
    var escapeAction: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        escapeAction?()
    }
}

/// 通用更新确认窗控制器（单例复用窗口实例，同 CheckupWindow 模式；主线程调用）
final class UpdateConfirmWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UpdateConfirmWindowController()

    /// 一次弹窗的完整配置（四条链路只填不同字段）
    struct Config {
        var title: String                  // 窗标题：更新 DSH Desktop 后端 / 应用 / Launcher
        var fromVersion: String            // 本地当前版本（空串 = 未解析）
        var toVersion: String              // 目标版本（去 v 前缀）
        var warning: String? = nil         // 红字警示一行（仅 alpha 通道填；一句话结论）
        /// 橙色补充说明：红字只说结论，细节（影响面/回滚手段）拆到这行。
        /// 带默认值，旧调用点不传也照常编译。
        var warningDetail: String? = nil
        var footnote: String? = nil        // 底部灰字说明（备份策略 / 下载指引）
        var confirmTitle: String = "立即更新"
    }

    private var textView: NSTextView?
    private var headerField: NSTextField?     // 版本跨度+红警示+橙补充 三行合一的全宽居中块
    private var footnoteField: NSTextField?
    private var confirmButton: NSButton?

    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var callbacksPending = false   // 回调至多触发一次（确认/取消/ESC/关窗互斥）
    private var shownVersions: (from: String, to: String) = ("", "")
    private var currentWarning: String?    // show() 落定后暂存，notes 到达重渲染头部时复用
    private var currentWarningDetail: String?
    private var notesGeneration = 0        // 代际号：只接受最新一次弹窗的 notes 刷新

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持 storyboard 初始化")
    }

    // MARK: - 对外入口

    /// 打开确认窗。notes 传 nil = 预取未就绪（头部与说明区先显示占位），
    /// fetch 完成后用返回的代际号调 updateNotes(token:_:) 刷新。
    /// 返回代际号，弹窗已关或已换目标时迟到的刷新会被丢弃。
    @discardableResult
    func show(config: Config,
              notes: [ReleaseNotes]?,
              onConfirm: @escaping () -> Void,
              onCancel: (() -> Void)? = nil) -> Int {
        if window == nil { buildWindow() }
        guard let win = window as? UpdateConfirmWindow else { return notesGeneration }

        notesGeneration += 1
        let token = notesGeneration
        win.title = config.title
        shownVersions = (config.fromVersion, config.toVersion)
        currentWarning = config.warning
        currentWarningDetail = config.warningDetail
        footnoteField?.stringValue = config.footnote ?? ""
        footnoteField?.isHidden = (config.footnote == nil)
        confirmButton?.title = config.confirmTitle
        renderHeader(notes: notes)
        renderNotes(notes)

        self.onConfirm = onConfirm
        self.onCancel = onCancel
        callbacksPending = true

        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return token
    }

    /// notes 预取完成后的刷新入口（token 不匹配 = 迟到的旧结果，直接丢弃）。
    /// 头部必须一并重渲染：版本行的"跨 N 个版本"后缀只在 notes 到达后出现。
    func updateNotes(token: Int, _ notes: [ReleaseNotes]?) {
        guard token == notesGeneration, window?.isVisible == true else { return }
        renderHeader(notes: notes)
        renderNotes(notes)
    }

    // MARK: - 窗体搭建（手写约束，无 NSStackView）

    private func buildWindow() {
        // 竖版 480×620：GitHub release notes 本就是竖向阅读排版（窄栏长文），
        // 横向 560×480 一行塞的字太多、纵向又看不了几屏；窄高窗的行长更贴近
        // 网页栏宽，阅读体验更好。仍可自由拉伸，最小 420×480 防拖成细条。
        let win = UpdateConfirmWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false    // 单例复用，关窗只 orderOut 不销毁
        // 不置顶（用户反馈）：floating 级会让确认窗盖在所有应用之上；
        // show() 里保留一次性的 NSApp.activate 保证弹出时拿到焦点即可。
        win.minSize = NSSize(width: 420, height: 480)
        win.escapeAction = { [weak self] in self?.performCancel() }
        win.delegate = self
        self.window = win

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 620))
        win.contentView = content

        // —— 头部三行合一（版本跨度 / 红警示 / 橙补充）——
        // 单字段而非三个字段：字段 frame 的水平排布交给 Auto Layout 后在
        // 栈语义下不可控（真机实测三行各自右挂）；合一后整块就是一个普通
        // 全宽视图，行内居中完全由 attributed 段样式决定（见 renderHeader）。
        let headerField = NSTextField(wrappingLabelWithString: "")
        headerField.font = .systemFont(ofSize: 13, weight: .semibold)
        headerField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerField)
        self.headerField = headerField

        // —— notes 只读滚动区 ——
        // 【陷阱：为何要下面六行配置】NSTextView() 零尺寸创建后直接当 documentView，
        // textContainer 的 containerSize 宽度保持 0，且 widthTracksTextView 默认
        // false——container 不会跟随 view 变宽，布局系统拿到的排版宽度恒 0，
        // 一个字形都排不出来：textStorage 里有内容所以无障碍读得到，视觉全空白
        // （v1.0.3"说明区空白"bug 的根因）。滚动文档的正确姿势：宽度跟随、
        // 高度无限（交给 scroller 滚），autoresizingMask 同步配 .width，
        // 三者缺一都会退化回"零宽排版"或"横向滚动"。
        let textView = NSTextView()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // 注：高度用 CGFloat.greatestFiniteMagnitude 而非裸 .greatestFiniteMagnitude——
        // 本机 CLT(swiftc 6.0.3) 在此位置把裸写法判成 CGFloat/Double 二义性。
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // —— 六行必备配置到此为止 ——
        textView.isEditable = false
        textView.isRichText = false
        textView.isSelectable = true          // 允许选中复制
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: 13)   // 与下方 NSAttributedString 正文同源
        self.textView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        // —— 底部灰字说明（备份策略 / 下载指引）——
        let footnoteField = NSTextField(wrappingLabelWithString: "")
        footnoteField.font = .systemFont(ofSize: 11)
        footnoteField.textColor = .secondaryLabelColor
        footnoteField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footnoteField)
        self.footnoteField = footnoteField

        // —— 底部按钮：右侧 [取消] [确认]，ESC 挂在取消键上（原生等价键惯例）——
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let confirmButton = NSButton(title: "立即更新", target: self, action: #selector(confirmClicked))
        confirmButton.bezelStyle = .rounded
        self.confirmButton = confirmButton

        // 按钮行仍是横向小栈（水平两元素无对齐歧义，栈只负责排横排）：
        // 弹性 spacer 把按钮推到右缘。
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonRow)

        // 手写纵向链：头 → 滚动区 → 脚注 → 按钮行，全部显式钉满内容宽。
        // 滚动区是唯一低 hugging/低压缩抗性的行（249 < 其它行默认 250），
        // 窗口高度增减全由它吸收；其余行按固有高度钉死。
        let m: CGFloat = 20   // 左右/上边距；下边距 16
        NSLayoutConstraint.activate([
            headerField.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            headerField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            headerField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            scroll.topAnchor.constraint(equalTo: headerField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            footnoteField.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            footnoteField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            footnoteField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            buttonRow.topAnchor.constraint(equalTo: footnoteField.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        scroll.setContentHuggingPriority(.init(249), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(249), for: .vertical)
    }

    // MARK: - 文案渲染

    /// 头部三行合一渲染：版本跨度（黑 13 semibold）+ 红警示（12 medium）+ 橙补充（12）。
    /// 居中的可靠性来自两件事：字段被手写约束钉满内容宽；每行段样式 .center。
    /// 【坑】绝不能用 .stringValue 写这些字段——赋值会整体替换 attributed
    /// 属性（v1.0.4 曾因 notes 到达后的重设把居中段样式抹掉，出现"跨 N 个版本"
    /// 后版本行右挂）。
    private func renderHeader(notes: [ReleaseNotes]?) {
        guard let headerField else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping

        let from = shownVersions.from.isEmpty ? "当前版本未解析" : "v\(shownVersions.from)"
        var span = "\(from) → v\(shownVersions.to)"
        if let notes, notes.count > 1 { span += "（跨 \(notes.count) 个版本）" }

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: span, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]))
        if let warning = currentWarning, !warning.isEmpty {
            out.append(NSAttributedString(string: "\n" + warning, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: para,
            ]))
        }
        if let detail = currentWarningDetail, !detail.isEmpty {
            out.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: para,
            ]))
        }
        headerField.attributedStringValue = out
    }

    private func renderNotes(_ notes: [ReleaseNotes]?) {
        guard let textView else { return }
        textView.textStorage?.setAttributedString(notesAttributedString(notes))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))   // 新内容从顶部看起
    }

    /// notes 三态：预取中 / 官方未提供 / 分节正文（每版一节 `── vX.Y.Z ──`，
    /// 数组本身已按版本降序传入——新版在上，往下看历史）。
    /// 中文说明是散文体：正文用比例字体 systemFont 13（等宽 Menlo 的英文等宽
    /// 间隔落在中文上观感稀疏，且与 GitHub 网页的阅读排版不符），行距 3 补足
    /// 中文方块的呼吸感；分节头同字号 semibold 区分层级。
    private func notesAttributedString(_ notes: [ReleaseNotes]?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyAttr: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let headerAttr: [NSAttributedString.Key: Any] = [
            .font: headerFont, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        // 两种空态必须区分：前者稍后会自动刷新，后者是终态
        guard let notes else {
            return NSAttributedString(string: "正在加载更新说明…",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph])
        }
        guard !notes.isEmpty else {
            return NSAttributedString(string: "官方未提供本次更新说明",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph])
        }
        // 版本节之间的虚线分隔：固定长度的短划线串 + 段落居中。长度刻意保守
        // （约 220pt）：按窗口实时宽度自适应计算的话，宽度一变就得整篇重排；
        // 短而居中在任意窗口宽度（最小 420）下都既不出界也不显挤，这就是
        // 分隔符的"尺寸适配"。颜色用二级标签色（曾用三级太暗，宽窗+截图压缩
        // 下肉眼几乎不可见——真机审计实测误判为"没有分隔线"）。
        let dashPara = NSMutableParagraphStyle()
        dashPara.alignment = .center
        let dashAttr: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: dashPara,
        ]
        let sectionDivider = NSAttributedString(
            string: String(repeating: "– ", count: 18).trimmingCharacters(in: .whitespaces) + " ",
            attributes: dashAttr)
        let out = NSMutableAttributedString()
        for (idx, note) in notes.enumerated() {
            if idx > 0 {
                out.append(NSAttributedString(string: "\n\n", attributes: bodyAttr))
                out.append(sectionDivider)
                out.append(NSAttributedString(string: "\n\n", attributes: bodyAttr))
            }
            out.append(NSAttributedString(string: "── v\(note.version) ──", attributes: headerAttr))
            // 官方发布日期（GitHub published_at，运行时取的，非硬编码）：
            // 以本地时区显示日粒度；解析失败则整行省略——纯展示增强。
            if let date = note.publishedAt {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                out.append(NSAttributedString(string: "\n", attributes: bodyAttr))
                out.append(NSAttributedString(
                    string: "发布于 \(f.string(from: date))",
                    attributes: [.font: bodyFont,
                                 .foregroundColor: NSColor.secondaryLabelColor,
                                 .paragraphStyle: paragraph]))
            }
            out.append(NSAttributedString(string: "\n\n", attributes: bodyAttr))
            let body = note.cleanedBody.isEmpty ? "官方未提供本次更新说明" : note.cleanedBody
            out.append(NSAttributedString(string: body, attributes: bodyAttr))
        }
        return out
    }

    // MARK: - 回调与关窗

    @objc private func confirmClicked() { performConfirm() }
    @objc private func cancelClicked() { performCancel() }

    /// 点左上角关闭 = 取消语义（不触发确认回调）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        performCancel()
        return false
    }

    private func performConfirm() {
        guard callbacksPending else { return }
        callbacksPending = false
        let callback = onConfirm
        window?.orderOut(nil)
        onConfirm = nil
        onCancel = nil
        callback?()
    }

    private func performCancel() {
        guard callbacksPending else { return }
        callbacksPending = false
        let callback = onCancel
        window?.orderOut(nil)
        onConfirm = nil
        onCancel = nil
        callback?()
    }
}
