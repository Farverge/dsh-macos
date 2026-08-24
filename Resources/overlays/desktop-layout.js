/**
 * dsh-macos local desktop-shell layout (v3 —— 纯 CSS，零 JS)。
 *
 * 为什么不断演进：官方组件样式是 CSS Modules，".pI_x6G_frame" 这类
 * <构建哈希>_<语义名> 的前缀随每次官方重建而变。v2 曾用 JS 发现脚本给
 * 节点打自有标签再套样式，但防抖引入的滞后会在折叠动画中途落地/撤离
 * 样式，产生一次难以捕捉的补间错位。
 *
 * v3 的调研结论（官方仓库 docs/web-styling.zh.md + 编译产物逐层核实）：
 * 1. 官方 AppFrame 根元素输出字面量 data 属性表达状态：
 *      data-sidebar-collapsed / data-details-collapsed / data-dragging
 *    且 React 条件渲染为 `attr || void 0`（真值时输出空串），
 *    选择器统一加 :not([data-sidebar-collapsed="false"]) 防未来改显式布尔。
 * 2. 官方槽位渲染器（dsh-client-ui-renderer 的 SlotOutlet）给每个槽位的
 *    occupant 包一层 <div data-slot="<名>" style="display:contents">：
 *    data-slot 是源码字面量，display:contents 使其在布局上透明——
 *    于是 `[data-slot="sidebar"] > …` 可以零歧义命中侧栏根的直接层级。
 * 3. 类名的语义后缀（_frame/_sidebarCol/_root/_collapsed/_rail/
 *    _settingsArea/sessionRow/projectRow）来自源码命名并受官方样式规范
 *    约束，[class*="…"] 包含匹配远比完整哈希耐用。
 * 已核实的元素事实：
 *   - 折叠态侧栏根同时带 _root 与 _collapsed（.hHd-Xa_root.hHd-Xa_collapsed）
 *   - 折叠轨容器是 ui-workspace 的浏览器根，同元素带 _root 与 _rail
 *     （clsx(root, !wide && rail)；官方原生列宽即轨宽，无需居中，
 *      外壳加宽到 86px 后才需要我们补居中）
 * 全部规则与官方状态信号同帧生效/撤销，无任何 JS 时序参与。
 */
(function () {
  var STYLE_ID = "dsh-desktop-style";
  if (document.getElementById(STYLE_ID)) return;

  var style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = [
    /* ---- 根 frame 外层几何 ---- */
    'div[class*="_frame"] { box-sizing: border-box !important; }',

    /* ---- 侧栏分隔线从窗口顶贯穿到底 ---- */
    "div[class*=\"_sidebarCol\"],",
    "div[data-sidebar-collapsed] > div:first-child {",
    "  border-right: 1px solid rgba(128,128,128,0.22) !important;",
    "  border-right: 1px solid color-mix(in srgb, currentColor 14%, transparent) !important;",
    "  box-sizing: border-box !important; }",

    /* ---- 折叠态外壳列宽 86px、56px 官方轨居中其中 ---- */
    "div[data-sidebar-collapsed]:not([data-sidebar-collapsed=\"false\"]) {",
    "  grid-template-columns: 86px minmax(0, 1fr) 0px !important; }",

    /* ---- 会话/项目行与“新会话”按钮同宽同缘 ---- */
    '[class*="sessionRow"], [class*="projectRow"] { box-sizing: border-box !important;',
    "  width: calc(100% - 32px) !important;",
    "  margin-left: 16px !important; margin-right: 16px !important; }",

    /* ---- 侧栏根几何：用对称内边距实现居中，而非限宽 ----
       官方折叠布局按“根自身 56px”设计；外壳列加宽到 86px 后需要居中。
       但 width 在 auto(拉伸)↔定长之间不可插值，强行限宽会让控件在动画
       第一帧瞬变（闪现感）。改为左右各让 15px：内容盒恰为 56px、整体
       居中，且 padding 连续可插值，可与官方列滑动同步平滑形变 ---- */
    'div[data-slot="sidebar"] > [class*="_root"],',
    'div[class*="_sidebarCol"] div[data-slot="sidebar"] > [class*="_root"] {',
    "  box-sizing: border-box !important;",
    "  padding-top: 32px !important; }",

    /* 折叠态：顶部 42 对齐顶栏底线；左右各 25 使 36px 内容盒恰好在
       86px 列内居中——官方轨控件是贴内容盒左缘排列的，内容盒必须
       收窄到单控件宽度，居中才成立（(86-36)/2=25） */
    'div[data-sidebar-collapsed]:not([data-sidebar-collapsed="false"]) div[data-slot="sidebar"] > [class*="_root"],',
    'div[class*="_sidebarCol"] div[data-slot="sidebar"] > [class*="_root"][class*="_collapsed"] {',
    "  padding-top: 42px !important;",
    "  padding-left: 25px !important;",
    "  padding-right: 25px !important; }",

    /* 平滑形变：跟随官方约 300ms 的列滑动节奏；尊重系统减少动态效果 */
    "@media (prefers-reduced-motion: no-preference) {",
    '  div[data-slot="sidebar"] > [class*="_root"] {',
    "    transition: padding 260ms cubic-bezier(0.25, 0.1, 0.25, 1) !important; }",
    "}",

    /* ---- 底部固定设置区在外壳列内居中 ---- */
    '[data-slot="sidebar"] [class*="_settingsArea"] { display: flex !important;',
    "  align-items: center !important; justify-content: center !important; }",

    /* ---- 折叠轨图标容器内容居中（仅折叠态；排除侧栏主根自身）---- */
    "div[data-sidebar-collapsed]:not([data-sidebar-collapsed=\"false\"])",
    '  [data-slot="sidebar"] [class*="_rail"] { align-items: center !important; }',

    /* ---- 折叠态鲸鱼视觉配重：切换键的悬停圆与其他控件几何同轴，
            但鱼形图案自身非对称，视觉重心偏左。只平移静默面图形
            （悬停后替换出现的箭头不受影响），尺寸与命中区不变 ---- */
    "div[data-sidebar-collapsed]:not([data-sidebar-collapsed=\"false\"])",
    '  [data-slot="sidebar"] [class*="_railMark"] { transform: translateX(2px); }',
  ].join("\n");
  document.head.appendChild(style);
})();
