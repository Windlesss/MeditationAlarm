# 项目长期记忆（MeditationAlarm）

跨会话有效的项目事实与约定。日常流水见 `memory/YYYY-MM-DD.md`；需求决策全记录在项目根 `REQUIREMENTS.md`（Q1–Q16），视觉规范在 `DESIGN.md`，阶段状态在 `STATUS.md`。

## 架构要点（2026-10-20 定稿）

- **音频调度走方案 B**：主 RunLoop Timer → 私有队列 `DispatchSourceTimer`（leeway 100ms），「下一次事件」= min(下一间隔, 结束时刻)，到点自愈重排；handler 里 `Task { @MainActor }` 回主线程播放。根因：主 RunLoop Timer 锁屏被节流；背景音由音频会话驱动所以全场景正常
- **静音守护**：无背景音时退后台循环 `keepalive-silence.wav`（volume 0）守音频会话
- **结束音分流**：手动结束单声；自然到头三声渐强（0.45/0.72/1.0），前后台锁屏一视同仁；尾声播完 `windDownSession` 收尾
- **常亮不变量**：`isIdleTimerDisabled == (phase == .running)`，无开关
- **通知已停用**（用户决策）：不申请权限不排程，`ReminderScheduler` / `chimes-caf` 保留不用
- **记录链（第二阶段）**：`SessionJournal` 唯一写入口；SessionRecord 一身兼两职（已闭合记录 + open 恢复记录）；短会话（DEBUG 60s / 正式 180s）弹框问是否记录，默认记录；作废用 `isDiscarded` 标记**不用 delete**（SwiftData delete+save 在本环境稳定失效）；连续天数 = 当天任意时长算 1 天、从今天往回严格数
- **LA 结束走 App**：结束按钮 = MeditationEndIntent（普通 AppIntent + openAppWhenRun + App Group 标志位）；App 激活后消费标志 → 弹二次确认 → confirmEnd；暂停/继续保持静默 LiveActivityIntent
- **跨启动恢复**：restoreIfNeeded 读 open 记录还原时钟/配置/音频/实时活动；只认 segmentStart != nil || accumulated > 0 的记录（防空壳误恢复）
- **MeditationCore 双 target 直编**（不走 SwiftPM 依赖——Xcode 包解析在受限环境不可用），但 `swift test` 仍可用（沙箱外跑）
- **构建链**：`xcodegen generate` → `xcodebuild`；本机 xcodegen 在 `/Users/windless/.workbuddy/binaries/xcodegen/bin/`

## 环境坑（跨会话有效）

- 模拟器设备 udid 会变：查 sqlite 前先 `simctl get_app_container booted <bundle-id> data`；SwiftData store 在 **App Group 容器**，不在 App 沙箱
- `swift test` 会被沙箱拦（~/.swiftpm/security 写入），需 escalate
- 查数据库/验证落库前先 `simctl terminate` + sleep 1，否则 launch 不干净会数据叠态
- `log stream` 抓 NSLog：先起流再 launch App；zsh 的 watch 模块报错时用 `bash -c` 包一层

## 用户偏好（跨阶段有效）

- 对「可滑动」有强预期：横向档位选择器（时长/间隔）必须支持横滑，纯静态点选会被认为「不适应」——即便一屏放得下
- 设计语言：浅色高雅（宣纸底、超细字重、青瓷点缀），拒绝重视觉元素；选中态要「自己跳出来」（字号差 + 青瓷底），不依赖提示文案
- 需求变更频繁且方向感强：时长选择器迭代过 5 轮，每轮决策都记录在 REQUIREMENTS.md Q15——**改这类组件前先读 Q 编号的决策链，别凭上次印象**
- 用户习惯「先讨论方案不动代码，拍板后才实施」；给方案时同时给原型图（widget mockup）效率最高
- 间隔/时长档位标签：间隔用全称（「15 秒」「1 分钟」），时长用缩写（「5 分」「1 时」）
- 「setup 是 setup，记录是记录」：结束流程与记录决策解耦，弹框归 UI 层，结束逻辑不感知
