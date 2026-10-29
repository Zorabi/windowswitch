# 微信窗口聚焦调研

调研日期：2026-10-29。范围：AltTab 公开源码、微信相关修复与 Contexts 官方说明。此次未修改或替换应用，未运行测试。

## 可核实的依据

### AltTab

本机安装版本为 11.9.2；源码分析固定到 11.10.1 提交 `c500294bdb01186011a5c64a412b04cef9931bef`。

- [窗口聚焦流程](https://github.com/lwouis/alt-tab-macos/blob/c500294bdb01186011a5c64a412b04cef9931bef/src/switcher/state/Window.swift#L408)：分开执行指定窗口置前、设为 key window、应用内部 Raise，并对跨 Space 切换作额外处理。
- [key window 实现](https://github.com/lwouis/alt-tab-macos/blob/c500294bdb01186011a5c64a412b04cef9931bef/src/macos/api-wrappers/SkyLight.framework.swift#L135)：通过指定窗口 ID 的 WindowServer 事件获取键盘焦点；采用远离内容区域的坐标，并省去配对鼠标抬起，处理历史误点击与缩放问题。这仍是私有接口方案，不能直接等同于本机已安全验证。
- [面板退出时机](https://github.com/lwouis/alt-tab-macos/blob/c500294bdb01186011a5c64a412b04cef9931bef/src/switcher/main-window/TilesPanel.swift#L127)：视觉隐藏与退出 key window 状态分离，目标置前后再释放面板；异常情况有 100ms 上限。
- [过期请求策略](https://github.com/lwouis/alt-tab-macos/blob/c500294bdb01186011a5c64a412b04cef9931bef/src/switcher/state/FocusIntentPolicy.swift#L39)：每次切换有独立代次，旧请求停止执行后续步骤，已迟到执行的操作有受限修复。
- [微信隐藏修复](https://github.com/lwouis/alt-tab-macos/commit/736b606)：微信隐藏时可撤销 AX 元素，但 WindowServer 表面仍存在；AX 消失不能直接判定窗口关闭。此修复不等于修复小程序随 Dock 激活。

### Contexts

- [官方更新说明](https://contexts.co/whats-new/)区分无窗口应用的 Dock 动作与仅激活应用，提供独立行为选项。
- [官网](https://contexts.co/)当前列出的支持系统为 Ventura、Sonoma、Sequoia；该信息不足以证明当前 macOS 27 环境中的微信问题已获支持。
- 本次未获得 Contexts 的公开聚焦源码，不能断言它采用了 AltTab 的接口或保证它能处理当前 Dock 问题。

## 与窗序 0.2.15 的差异

| 项目 | 当前实现 | 判断 |
| --- | --- | --- |
| 指定窗口置前 | 已有 | 完成一次系统调用不代表 key window 已交接 |
| 单独设置 key window | 缺失 | 是明确的流程缺口；与当前延迟是否直接相关仍需计时验证 |
| 面板交接 | 先 orderOut，再排队激活目标 | 存在先把焦点交还原应用的时间段，可能产生闪回或被旧应用抢回 |
| 过期聚焦请求 | 重开有令牌，普通聚焦没有统一代次 | 快速切换时旧请求仍可能执行 |
| 完整耗时证据 | 未记录各阶段时长 | 不能把延迟直接归因于 AX、WindowServer 或动画 |
| Dock 后续行为 | 用户确认仍会连带小程序 | 尚无来源证明完整 AltTab 流程能解决这个特定现象 |

## 推荐实施顺序

1. 先加入一次性计时，分别观察按键提交、主线程接收、聚焦排队、系统激活返回、目标置前与键盘焦点确认；确定用户感知的等待落在哪一段。
2. 对已有窗口建立完整的置前、key window 和应用内部层级处理流程。保留窗口 ID 与所属进程校验；若采用 WindowServer 事件，单独验证内容不被点击、窗口不移动或缩放。
3. 调整面板释放时机，加入普通切换的代次与取消处理。保留有界退出，避免聚焦失败时面板永久占用键盘。
4. 将已有窗口切换、最小化恢复、隐藏应用恢复、窗口已关闭后的 reopen 分开判断，减少误发 reopen。
5. Dock 跟随单独验收：在相同微信与系统版本、重新创建的小程序窗口上，对比原生操作、AltTab 操作及窗序操作。未取得这一对照前，不承诺修改窗序聚焦流程就能改变原生 Dock 的后续行为。

上述方案不涉及窗口截图能力。继续使用现有稳定应用身份和辅助功能授权，私有接口的运行兼容性需独立确认。
