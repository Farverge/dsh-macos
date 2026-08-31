import AppKit

// MARK: - 更新确认独立窗（v1.0.2）
//
// 为什么用 NSWindow 而不是 SwiftUI .sheet：设置页是 macOS 分组 Form，sheet 高度
// 受表单布局制约，长更新说明显示不全（用户反馈的"小窗显示不全"正是此因）。
// 范式参照 dsh-launcher 的 CheckupWindow.swift：独立 NSWindow + NSScrollView +
// NSTextView，560×480 起步可拉伸，notes 只读可滚动、可选中复制。
// 四条更新链路（后端 rc / 后端 alpha / 前端应用 / Launcher）共用这一个壳，
// 只换文案与确认回调——更新执行逻辑全部留在 SettingsView 原有函数里，本文件不碰。

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
        var warning: String? = nil         // 顶部红字警示一行（alpha 通道专用）
        var footnote: String? = nil        // 底部灰字说明（备份策略 / 下载指引）
        var confirmTitle: String = "立即更新"
    }

    private var textView: NSTextView?
    private var versionField: NSTextField?
    private var warningField: NSTextField?
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
        warningField?.isHidden = (config.warning == nil)   // 栈视图自动收起隐藏行
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
        let win = UpdateConfirmWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],   // 规格定稿：560×480 起步可拉伸
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false    // 单例复用，关窗只 orderOut 不销毁
        win.level = .floating
        win.minSize = NSSize(width: 520, height: 420)
        win.escapeAction = { [weak self] in self?.performCancel() }
        win.delegate = self
        self.window = win

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        win.contentView = content

        // —— 版本跨度行（v本地 → v最新（跨 N 个版本））——
        let versionField = NSTextField(labelWithString: "")
        versionField.font = .systemFont(ofSize: 13, weight: .semibold)
        versionField.lineBreakMode = .byWordWrapping
        self.versionField = versionField

        // —— 顶部红字警示（仅 alpha 通道填文案）——
        let warningField = NSTextField(labelWithString: "")
        warningField.font = .systemFont(ofSize: 12, weight: .medium)
        warningField.textColor = .systemRed
        warningField.lineBreakMode = .byWordWrapping
        self.warningField = warningField

        // —— notes 只读滚动区（等宽 12pt，解决"小窗显示不全"）——
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.isSelectable = true          // 允许选中复制
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = NSFont(name: "Menlo", size: 12)
            ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        self.textView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView

        // —— 底部灰字说明（备份策略 / Launcher 下载指引）——
        let footnoteField = NSTextField(labelWithString: "")
        footnoteField.font = .systemFont(ofSize: 11)
        footnoteField.textColor = .secondaryLabelColor
        footnoteField.lineBreakMode = .byWordWrapping
        self.footnoteField = footnoteField

        // —— 底部按钮：右侧 [确认] [取消]，ESC 挂在取消键上（原生等价键惯例）——
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

        // 纵向栈：隐藏的警示/说明行会被自动收起，无需手工挪布局
        let stack = NSStackView(views: [versionField, warningField, scroll, footnoteField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .width          // 各行随窗口等宽拉伸
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        // 窗口拉伸时增量高度全给 notes 区（其余行按固有高度钉死）
        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 260)
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

    /// notes 三态：预取中 / 官方未提供 / 分节正文（每版一节 `── vX.Y.Z ──`）
    private func notesAttributedString(_ notes: [ReleaseNotes]?) -> NSAttributedString {
        let bodyFont = NSFont(name: "Menlo", size: 12)
            ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let bodyAttr: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.labelColor,
        ]
        // 两种空态必须区分：前者稍后会自动刷新，后者是终态
        guard let notes else {
            return NSAttributedString(string: "正在加载更新说明…",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
        guard !notes.isEmpty else {
            return NSAttributedString(string: "官方未提供本次更新说明",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let headerFont = NSFont(name: "Menlo-Bold", size: 12)
            ?? .monospacedSystemFont(ofSize: 12, weight: .semibold)
        let out = NSMutableAttributedString()
        for (idx, note) in notes.enumerated() {
            if idx > 0 { out.append(NSAttributedString(string: "\n\n", attributes: bodyAttr)) }
            out.append(NSAttributedString(string: "── v\(note.version) ──", attributes: [
                .font: headerFont, .foregroundColor: NSColor.labelColor,
            ]))
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
