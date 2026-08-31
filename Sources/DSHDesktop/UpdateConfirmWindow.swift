import AppKit

// MARK: - 更新确认独立窗（v1.0.2；本次重排版）
//
// 为什么用 NSWindow 而不是 SwiftUI .sheet：设置页是 macOS 分组 Form，sheet 高度
// 受表单布局制约，长更新说明显示不全（用户反馈的"小窗显示不全"正是此因）。
// 范式参照 dsh-launcher 的 CheckupWindow.swift：独立 NSWindow + NSScrollView +
// NSTextView，起步可拉伸，notes 只读可滚动、可选中复制。
// 四条更新链路（后端 rc / 后端 alpha / 前端应用 / Launcher）共用这一个壳，
// 只换文案与确认回调——更新执行逻辑全部留在 SettingsView 原有函数里，本文件不碰。
//
// 本次重做的动因（真机实测）：旧版说明区整块空白——NSTextView() 以零尺寸创建后
// 直接塞进 NSScrollView 当 documentView，且缺滚动文档视图的必备配置，导致
// textContainer 排版宽度恒为 0，一个字形都排不出来（textStorage 里其实有字，
// 无障碍能读到、肉眼看不见）。同时按反馈改竖版窗口 + 统一左对齐版式 + 警示拆行。

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
        var warning: String? = nil         // 顶部红字警示一行（仅 alpha 通道填；一句话结论）
        /// 橙色补充说明：红字只说结论，细节（影响面/回滚手段）拆到这行，避免一行塞两件事。
        /// 带默认值，旧调用点不传也照常编译。
        var warningDetail: String? = nil
        var footnote: String? = nil        // 底部灰字说明（备份策略 / 下载指引）
        var confirmTitle: String = "立即更新"
    }

    private var textView: NSTextView?
    private var versionField: NSTextField?
    private var warningField: NSTextField?
    private var warningDetailField: NSTextField?
    private var footnoteField: NSTextField?
    private var confirmButton: NSButton?

    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var callbacksPending = false   // 回调至多触发一次（确认/取消/ESC/关窗互斥）
    private var shownVersions: (from: String, to: String) = ("", "")
    private var notesGeneration = 0        // 代际号：只接受最新一次弹窗的 notes 刷新

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持 storyboard 初始化")
    }

    // MARK: - 对外入口

    /// 打开确认窗。notes 传 nil = 预取未就绪（先显示"加载中…"），
    /// fetch 完成后用返回的代际号调 updateNotes(token:_:) 刷新文本。
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
        renderVersionSpan(notes: notes)
        warningField?.stringValue = config.warning ?? ""
        warningField?.isHidden = (config.warning == nil)          // 栈视图自动收起隐藏行
        warningDetailField?.stringValue = config.warningDetail ?? ""
        warningDetailField?.isHidden = (config.warningDetail == nil)
        footnoteField?.stringValue = config.footnote ?? ""
        footnoteField?.isHidden = (config.footnote == nil)
        confirmButton?.title = config.confirmTitle
        renderNotes(notes)

        self.onConfirm = onConfirm
        self.onCancel = onCancel
        callbacksPending = true

        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return token
    }

    /// notes 预取完成后的刷新入口（token 不匹配 = 迟到的旧结果，直接丢弃）
    func updateNotes(token: Int, _ notes: [ReleaseNotes]?) {
        guard token == notesGeneration, window?.isVisible == true else { return }
        renderVersionSpan(notes: notes)
        renderNotes(notes)
    }

    // MARK: - 窗体搭建

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
        win.level = .floating
        win.minSize = NSSize(width: 420, height: 480)
        win.escapeAction = { [weak self] in self?.performCancel() }
        win.delegate = self
        self.window = win

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 620))
        win.contentView = content

        // —— 版本跨度行（v本地 → v最新（跨 N 个版本））——
        let versionField = NSTextField(labelWithString: "")
        versionField.font = .systemFont(ofSize: 13, weight: .semibold)
        versionField.alignment = .natural          // 左对齐（LTR 下即靠左）
        versionField.lineBreakMode = .byWordWrapping
        self.versionField = versionField

        // —— 顶部红字警示：只放一句话结论（仅 alpha 通道填文案）——
        let warningField = NSTextField(labelWithString: "")
        warningField.font = .systemFont(ofSize: 12, weight: .medium)
        warningField.textColor = .systemRed
        warningField.alignment = .natural
        warningField.lineBreakMode = .byWordWrapping
        self.warningField = warningField

        // —— 橙字补充：红字的细节展开（影响面 / 回滚手段），与红字各占一行 ——
        let warningDetailField = NSTextField(labelWithString: "")
        warningDetailField.font = .systemFont(ofSize: 12)
        warningDetailField.textColor = .systemOrange
        warningDetailField.alignment = .natural
        warningDetailField.lineBreakMode = .byWordWrapping
        self.warningDetailField = warningDetailField

        // —— notes 只读滚动区 ——
        // 【陷阱：为何要下面六行配置】NSTextView() 零尺寸创建后直接当 documentView，
        // textContainer 的 containerSize 宽度保持 0，且 widthTracksTextView 默认
        // false——container 不会跟随 view 变宽，布局系统拿到的排版宽度恒 0，
        // 一个字形都排不出来：textStorage 里有内容所以无障碍读得到，视觉全空白
        // （旧版"说明区空白"bug 的根因）。滚动文档的正确姿势是：宽度跟随、
        // 高度无限（交给 scroller 滚），autoresizingMask 同步配 .width，
        // 三者缺一都会退化回"零宽排版"或"横向滚动"。
        let textView = NSTextView()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // 注：高度用 CGFloat.greatestFiniteMagnitude 而非裸 .greatestFiniteMagnitude——
        // 本机 CLT(swiftc 6.0.3) 在此位置把裸写法判成 CGFloat/Double 二义性，显式标注基类型。
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

        // —— 底部灰字说明（备份策略 / Launcher 下载指引）——
        let footnoteField = NSTextField(labelWithString: "")
        footnoteField.font = .systemFont(ofSize: 11)
        footnoteField.textColor = .secondaryLabelColor
        footnoteField.alignment = .natural
        footnoteField.lineBreakMode = .byWordWrapping
        self.footnoteField = footnoteField

        // —— 底部按钮：右侧 [取消] [立即更新]，ESC 挂在取消键上（原生等价键惯例）——
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let confirmButton = NSButton(title: "立即更新", target: self, action: #selector(confirmClicked))
        confirmButton.bezelStyle = .rounded
        self.confirmButton = confirmButton

        let spacer = NSView()   // 撑开左侧弹性空隙，把按钮推到右缘
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        // 纵向栈：隐藏的警示/补充/说明行会被自动收起，无需手工挪布局。
        // alignment 用 .width 让各行随窗口等宽拉伸（正文与警示需要整行宽度换行）；
        // 各文本字段自身 alignment 已钉在 .natural，视觉上一律左起，不再混排。
        let stack = NSStackView(views: [versionField, warningField, warningDetailField,
                                        scroll, footnoteField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        // 窗口拉伸时增量高度全给 notes 区（其余行按固有高度钉死）：
        // 低优先级 heightAnchor 约束给出基础高度，超出部分由它"让路"吸收。
        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 340)
        scrollHeight.priority = .init(750)   // 低于 required，拉伸时由此约束吸收变化
        scrollHeight.isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    // MARK: - 文案渲染

    /// 版本跨度行；跨多版本（notes 就绪且 >1 节）时附"跨 N 个版本"
    private func renderVersionSpan(notes: [ReleaseNotes]?) {
        let from = shownVersions.from.isEmpty ? "当前版本未解析" : "v\(shownVersions.from)"
        var text = "\(from) → v\(shownVersions.to)"
        if let notes, notes.count > 1 { text += "（跨 \(notes.count) 个版本）" }
        versionField?.stringValue = text
    }

    private func renderNotes(_ notes: [ReleaseNotes]?) {
        guard let textView else { return }
        textView.textStorage?.setAttributedString(notesAttributedString(notes))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))   // 新内容从顶部看起
    }

    /// notes 三态：预取中 / 官方未提供 / 分节正文（每版一节 `── vX.Y.Z ──`）。
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
        let out = NSMutableAttributedString()
        for (idx, note) in notes.enumerated() {
            if idx > 0 { out.append(NSAttributedString(string: "\n\n", attributes: bodyAttr)) }
            out.append(NSAttributedString(string: "── v\(note.version) ──", attributes: headerAttr))
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
