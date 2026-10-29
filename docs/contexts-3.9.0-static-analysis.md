# Contexts 3.9.0 本地样本静态分析

分析日期：2026-10-29。目标是理解窗口聚焦机制，供窗序排查参考。仅只读挂载镜像并使用系统工具分析元数据、符号和反汇编；未启动应用、动态库或镜像中的脚本，未安装或修改此样本。

## 样本与可信范围

| 项目 | 结果 |
| --- | --- |
| 输入文件 | `Contexts 3.9.0 [TNT].dmg` |
| 镜像 SHA-256 | `085e2d54127fb17e925d3f81365dce0db249133ee06711895580bd0f94cb0aca` |
| 应用版本 / 构建 | 3.9.0 / 390 |
| 架构 | 单一 x86_64 |
| 最低系统 / 构建 SDK | macOS 10.15 / macOS 11.3 |
| 标识 | `com.contextsformac.Contexts` |
| 签名 Authority / TeamIdentifier | TNT / 未设置 |
| 主程序 SHA-256 | `0a88cd94ffbf0514c992270e4fd0c3a4ca00c5c512da94be9e0d8583c3389a79` |

外层 DMG 的 `Manual install` 中还有一层同名 DMG，应用位于内层。外层附带 Gatekeeper 处理脚本，应用资源中存在 `libConfigurer64.dylib`；均未执行。严格资源签名校验未报告错误，只说明样本内容与它自己的签名一致，不能据此认定是官方原始程序或判定安全。

以下结论适用于这个样本。它经第三方重新签名，并非可确认为未修改的官方原版；无运行期追踪，不能将静态可达路径等同于某次微信操作实际走过的路径。

## 核实的聚焦实现

### 1. 独立操作对象与策略分支

Objective-C 类 `CWSActivateWindowOperation` 保留了 35 个实例方法。方法列表及其实现地址可从 `otool -ov` 获得；`otool -tvV` 可核对调用顺序。

| 方法 | 实现地址 | 直接证据 |
| --- | --- | --- |
| `_run` | `0x10001bf52` | 判断私有接口、窗口 Space、标签组、快速切换和替代切换设置，分派不同策略 |
| `activateMethodRaiseWindowActivateApplication` | `0x10001c9fe` | 先 raiseWindow，再 activateProcess；首次 Raise 返回真时再次 raiseWindow，最后完成 |
| `activateMethodSwitchSpaceAndClickWindow` | `0x10001ca59` | 切换 Space、设置状态，延迟后检查状态 |
| `activateMethodSwitchSpaceAndRaiseWindow` | `0x10001cb99` | 独立的切换 Space / Raise 路径 |
| `activateMethodFastSwitchSpaceAndClickWindow` | `0x10001cceb` | 按窗口 ID 显示其所在 Space，然后进入点击路径 |
| `activateMethodFastSwitchSpaceAndRaiseWindow` | `0x10001cd6b` | 显示所在 Space，再 Raise、激活进程、完成 |

可见设置名称包括 `workspaceEnableAlternativeSwitchingMethod` 和 `workspaceFastSpaceSwitchingEnabled`。因此不能将某一条路径称为适用于所有窗口的唯一实现。

### 2. 普通激活路径使用 Carbon 的单窗口标志

`activateProcess`（`0x10001d890`）调用进程对象的 `makeFrontProcess`。

`makeFrontProcess`（`0x10002b086`）将第二参数置为 `1`，跳转到 `SetFrontProcessWithOptions`。本机 SDK 的 Processes.h 将 `1 << 0` 定义为 `kSetFrontProcessFrontWindowOnly`。

本样本这条路径没有显式传入 CGWindowID，依赖之前的 Raise 选择应用内的目标，再使用进程激活，并在部分情况下再次 Raise。它与窗序 0.2.13 以后使用的 `_SLPSSetFrontProcessWithOptions(pid 对应 PSN, windowID, 0x200)` 并非同一个接口调用。

导入表包含 AX 读取、属性写入、操作、`_AXUIElementGetWindow`、`GetProcessForPID` 和 `SetFrontProcessWithOptions`。未在导入表或可见字符串中找到 `SLPSPostEventRecordTo` / `_SLPSSetFrontProcessWithOptions`；这不是对一切动态解析路径的排除证明。

### 3. 替代点击路径确实生成鼠标事件

`clickOnWindowOnSpace:`（`0x10001dc1d`）读取目标窗口几何、屏幕与 CG 窗口列表，并进行交集、包含、裁剪等计算，随后调用 `clickAtPoint:`。

`clickAtPoint:`（`0x10001e8fb`）向输入监听器设置下一次鼠标按下和抬起的位置，创建类型 1、2 的鼠标事件，再通过 `CGEventPost` 发出。可确认这是成对鼠标事件路线；不能未经额外分析就保证其点击不会触及目标窗口内容。

它与本次调研的新版 AltTab 只向指定窗口发送用于获取 key window 的单次事件有所区别。不能直接把此样本的旧点击实现照搬至 macOS 27。

### 4. 跨 Space 使用辅助窗口及私有 CGS 接口

`CWSActivateWindowOperationHelperWindow` 是 NSWindow 子类，可成为 key/main window。初始化时设置无边框、忽略鼠标、失活隐藏。

`changeToSpace:`（`0x10001d5a4`）创建辅助窗口、使其 key/置前、查询它所在的 Space、移动到目标 Space，再调整位置并激活。静态可见的动态加载名称包括 `CGSCopyManagedDisplaySpaces`、`CGSManagedDisplaySetCurrentSpace`、`CGSShowSpaces`、`CGSHideSpaces`、`CGSAddWindowsToSpaces`、`CGSRemoveWindowsFromSpaces`、`CGSSpaceSetFrontPSN`。

这些实现解释了旧版对不同桌面情形有额外处理，不构成当前系统的兼容性保证。

### 5. 状态机与旧请求失效

操作对象持有 `state`、`runId` 和 `windowSpace`。`processStateAfterDelay:forIterations:runId:` 的回调会读取当前 runId，再决定是否推进状态或重置。`processStateForIterations:` 检查应用、窗口、Space 的激活状态，并可继续 Raise、点击或回退。

`raiseWindow` 成功分支还设置 `windowItemToMakeActiveWhenProcessBecomesActive` 并安排延迟清理，表明它会结合后续的应用激活状态处理目标。不能从静态证据推导出所有重试的运行期耗时。

## 对窗序的实际启示

1. 置前、应用激活、key window 和 Space 交接应分开确认。仅依据系统调用返回成功就结束切换，不等同于目标已可输入。
2. 针对同桌面、跨桌面、隐藏、最小化、已关闭窗口使用明确策略；普通窗口切换不应自动走重开。
3. 借鉴操作状态和 runId，而非轮流调整 Raise/Activate 顺序。先记录提交、排队、系统调用及焦点交接的耗时，再判断延迟位置。
4. 本样本没有提供已核实的“微信小程序 Dock 跟随修复”。未发现明确 WeChat 标识的静态特例，也未确认它会接管 Dock 点击。此前用户观察到的好效果，应通过相同系统和微信版本的运行对照验证。
5. 可借鉴策略设计，不复制第三方程序代码、不引入样本的授权处理模块，不据此更改窗序稳定身份或新增权限。

## 复查方法

使用系统提供的 `hdiutil` 只读挂载两层镜像，再分别运行 `plutil -p`、`file`、`codesign -dvvv`、`codesign --verify --deep --strict`、`otool -L`、`nm -u`、`strings -a`、`otool -ov` 与 `otool -tvV`。通过上表的实现地址核对调用。

原始样本未修改；分析结束后卸载两个只读镜像。此次没有替换运行中的窗序，也没有提交或推送代码。
