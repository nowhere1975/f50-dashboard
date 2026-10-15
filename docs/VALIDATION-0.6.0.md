# 0.6.0 原生菜单与材质验证

日期：2026-10-15。环境：Apple Silicon、macOS 27，macOS 12 部署目标。

## 修正方向

0.5.0 使用独立 NSPopover、固定高度 ScrollView 和实色底板，导致内部滚动条，外观与 CodexBar 的原生菜单存在明显差异。

本版参照 CodexBar 的承载方式，使用 NSMenuItem.view 放置信息卡片。卡片背景透明，普通操作、详情和历史使用原生菜单项与子菜单，移除独立弹出面板和内部滚动容器。系统负责菜单的背景材质、圆角和投影，实际透明度随系统外观及辅助功能设置变化。

参考源码：

- [CodexBar 菜单卡片组装](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBar/StatusItemController%2BMenuCardItems.swift)
- [CodexBar 承载与测量](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBar/StatusItemController%2BMenuPresentation.swift)

本机 SDK 的 NSGlassEffectView 从 macOS 26 起可用，可用于需要独立玻璃表面的其他设计。本版采用原生菜单材质，没有额外叠加玻璃层，也不修改系统外观设置。

## 验证

- 152 项 Swift 数据回归、118 项菜单回归、238 项卡片回归及 10 项脚本检查通过。
- 渲染模式增加 26 项检查，共 264 项卡片与渲染检查通过，实际进入 NSMenu 跟踪循环并取得 NSPopupMenuWindow 渲染。
- 验证生产卡片不包含 NSScrollView，背景非实色，主、次级文字色明确，卡片高度按内容测量。
- 柱图几何信息通过原生子视图注册，悬停检查映射至对应日期；离开图表恢复当日值。
- 连续 100 次刷新复用菜单项、子菜单和承载视图，并保持展开时的行高及日期选择；菜单结构在下次打开时更新。
- 另用生产 AppDelegate 的菜单构建代码检查五个操作目标、右箭头子菜单、连续 100 次刷新、读取失败与切网后的内容。
- 原有型号确认、部分计数、错误配置、采样缺口、已校准用量、真实零值与未记录日期等数据边界继续通过回归。

实际安装与签名验证通过，唯一进程与运行快照一致，真实 F50 Pro 板块为 ready。配置完全一致，逐条核对 13 条既有网络累计、日记录和月度记录，统计起点、名称、校准时间、采样质量及提醒记录保留。升级前已有的月度采样缺口状态也保留，未擅自补数或重新校准。

本地证据位于 `build/tests/native-card/`、`build/tests/v060-integration/` 和 `build/tests/v060-runtime-acceptance.json`。截图使用测试数据，运行配置和累计文件不提交 Git。

## 验证边界

原生菜单窗口、生产构建路径和刷新状态已验证。完整物理鼠标操作、通知送达、其他固件、Intel 和旧 macOS 实机仍未新增验证。截图不能证明所有壁纸和系统透明度设置下的玻璃视觉效果；主菜单超出屏幕高度时由 macOS 自行处理溢出。
