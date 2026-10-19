# 第一阶段开发状态快照

> 快照时间：2026-10-19。本文档随 git 上传，供阶段交接与 review 使用。
> 需求与决策的完整记录见 `REQUIREMENTS.md`（含 Q1–Q15 决策链），视觉规范见 `DESIGN.md`。

## 一句话定位

iOS 冥想闹钟：设定时长与间隔提示后开始，前台 / 后台 / 锁屏全场景可靠播放提示音与结束音，计时期间屏幕常亮。

## 第一阶段已完成

### 1. 计时与音频（核心）
- **方案 B 调度链**：主 RunLoop Timer → 私有队列 `DispatchSourceTimer`（leeway 100ms）；「下一次事件」= min(下一间隔提示, 结束时刻)，到点自愈重排；handler 内 `Task { @MainActor }` 回主线程播放。锁屏不再被系统节流（主 RunLoop Timer 在锁屏下会被 throttling）
- **结束音分流**：手动结束 = 单声；自然到头（前后台锁屏一视同仁）= 三声渐强 0.45 / 0.72 / 1.0
- **结束收尾**：尾声播完淡出停背景音、停静音守护、释放音频会话（`windDownSession`，`isInSession` 双重守卫）
- **静音守护**：选「无背景音」时退后台循环播放数字静音（`keepalive-silence.wav`，volume 0），守住音频会话防 App 被挂起，保证 GCD 链在后台继续跑
- **试听规则**：选提示音 / 背景音即播；拖提示音音量放手时播一次；拖背景音音量按「正在放的是不是这个音」切换或只改音量（80ms 防抖）

### 2. 设置页
- 冥想时长：**一行横滑胶囊**（5/10/20/30/45 分、1/2/5 时、自定义），交互同间隔提示，**选中项 13→18pt 增高 + 青瓷底**，选中项进场 / 点选后自动滚到居中
- 自定义：胶囊排下方淡出分钟输入（numberPad + 键盘工具栏「完成」+ 点任意处收起）；空 / 0 禁用开始按钮；重复点「自定义」不清空已输入
- 间隔提示：横向胶囊组（无 / 15 秒 / 1 / 3 / 5 / 10 / 30 分钟）
- 提示音 / 背景音选择 + 双音量滑杆
- 「永久运行」开关（同高占位，拨动不跳页）
- 联动规则：时长 < 间隔时开始自动扩为间隔 5 倍（`DurationPolicy.resolve`，MeditationCore 纯函数，5 个单测覆盖）

### 3. 系统集成
- 灵动岛 / 锁屏 Live Activity（计时显示，深色变体）
- 屏幕常亮：`isIdleTimerDisabled == (phase == .running)` 不变量，无开关——仅运行中常亮，暂停 / 结束 / 退后台恢复自动锁屏
- 本地通知：**已停用**（用户决策，见 Q14）——方案 B 之后全场景走音频，不再申请权限、不再排程；`ReminderScheduler` 与 `chimes-caf` 素材保留不用

### 4. 视觉资产
- 「圆相」Logo + AppIcon（浅 / 深色），由 `Resources/Logo/make_logo.py` 生成
- 设计语言：宣纸底 `#F7F5F1`、青瓷 `#7E9E92` / 选中底 `#E6EFEB`、超细字重、胶囊选择器、空心圆环开始按钮（详见 `DESIGN.md`）

## 代码结构

```
MeditationAlarmApp/
  App/MeditationAlarmApp.swift     入口；scenePhase 前后台同链；#if DEBUG -selfTest 钩子（2min/25s）
  Session/SessionController.swift  方案 B 调度链、结束分流、常亮不变量
  Audio/AudioEngine.swift          播放、静音守护、windDownSession 收尾
  Features/Setup/SetupView.swift   设置页
  Features/Setup/DurationCapsulePicker.swift  时长胶囊（DurationOption 档位表 + 组件）
  Features/Root/RootView.swift     根视图
Packages/MeditationCore/           计时 / IntervalSchedule / DurationPolicy（App 与 Widget 两 target 直编，不走 SwiftPM 依赖）
Shared/Palette.swift               色板与排版（两 target 共用）
Resources/Audio/                   提示音 + 背景音 + keepalive-silence + chimes-caf（保留不用）
project.yml                        XcodeGen 配置（iOS 17.0，team 524VAG6LTE）
```

## 构建与测试

```bash
xcodegen generate                                          # 新增/删除文件后必须重跑
xcodebuild -project MeditationAlarm.xcodeproj -scheme MeditationAlarm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath Build/DerivedData build
```

- 内核单测：`cd Packages/MeditationCore && swift test`（IntervalSchedule / DurationPolicy）
- 调度链自测：Debug 构建带 `-selfTest` 启动参数，压缩为 2 分钟会话 + 25 秒间隔，看日志验证 GCD 链触发

## 待真机验证 ⏳

模拟器已过（构建 + 四态截图 + selfTest 日志），以下需真机：

1. 前台回归：间隔音 / 背景音正常
2. 后台未锁屏：间隔音正常播放且**无通知**
3. 锁屏跨 ≥2 个间隔都响
4. 锁屏自然到头：三声渐强 + 灵动岛消失
5. 选「无背景音」+ 锁屏（静音守护路径）
6. 暂停 / 继续后再锁屏
7. 自动锁屏设 30s 验证常亮
8. 时长胶囊：横滑跟手性、松手截断位置、点选后自动居中的节奏
9. 键盘收起：点任意处（尤其滚动区空白处）是否顺手

## 已知边界

- 划掉 App 后 iOS 不允许进程再发声（通知除外，而通知已按用户决策停用）——这是方案 B 的唯一边界
- `isIdleTimerDisabled` 拦不住侧边按钮手动锁屏（无公开 API）
- 部署目标 iOS 17.0，最低屏宽 375pt（SE3），无 320pt 老屏适配
