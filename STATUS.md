# 开发状态快照

> 快照时间：2026-10-20（第一阶段 + 第二阶段记录 + 第三阶段 v3a 健康数据）。本文档随 git 上传，供阶段交接与 review 使用。
> 需求与决策的完整记录见 `REQUIREMENTS.md`（含 Q1–Q16 决策链），视觉规范见 `DESIGN.md`。

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

### 4. 冥想记录（第二阶段，2026-10-20）

- **落库**（`SessionJournal` 唯一写入口）：开始建 open 记录 → 暂停/继续写时钟快照 → 结束结算。实际时长 = segments 累加（暂停不计）；结束方式 natural / manual
- **短会话弹框**：实际时长 < 阈值（`#if DEBUG` 60s / 正式 180s）结束时问「是否记录」，默认记录。结束流程与记录决策完全解耦（setup 是 setup，记录是记录）
- **LA 结束按钮改造**：点结束 → 打开 App → 弹二次确认 → 才执行结束（FR-2.3）。指令走 App Group 标志位（Darwin 通知冷启动必丢）；暂停/继续保持静默 Intent
- **跨启动恢复**：App 被杀后重启读 open 记录还原时钟/配置/音频/实时活动
- **记录页**：统计头部（次数 / 累计时长 / 连续天数）+ 月历热力图（青瓷四档色阶）+ 按天分组列表 + 详情卡片 + 左滑删除（二次确认）
- **防御性设计**：作废记录用 `isDiscarded` 标记而非 delete（SwiftData 对带 relationship 的模型 delete + save 在本环境稳定失效，save 静默失败记录原样留库）；开新会话前闭合残留 open 记录；恢复只认有运行数据的 open 记录

### 6. 健康数据（第三阶段 v3a，2026-10-20）

- **授权**（`HealthKitService`，无开关无配置）：首次会话开始请求一次（UserDefaults 标记去重）；`WCSession.isPaired` 分流——有手表读（心率/HRV）+写（正念），无手表只写；被拒静默到底
- **正念写入**：承接记录逻辑——写记录才写（静默落库 / commitPending 时）、作废不写；写入前查 `authorizationStatus(for:)`（写状态可查），未授权挂起待前台重试（`retryMindfulWrites`）
- **采样**（`VitalSampler` 三层叠加）：`HKAnchoredObjectQuery` 即时回调（主）+ `HKObserverQuery` 后台 delivery 唤醒（补）+ 30s 兜底轮询（保底）；样本按 HealthKit uuid 去重（`VitalsBook`，启动时用库内全量键预热）后落 `VitalRecord`
- **呈现**：小结页（结束弹框后轻推一格，无健康数据不呈现）+ 详情页嵌入；`VitalPresentation` 三态——hidden 整块消失 / single 单值大字 / series 画图（心率连线+点，HRV 只画竖线+点不连线）
- **数据模型**：`VitalRecord` 挂 `SessionRecord`（级联删除）；演示 seed 含三态体征样本

### 7. 视觉资产
- 「圆相」Logo + AppIcon（浅 / 深色），由 `Resources/Logo/make_logo.py` 生成
- 设计语言：宣纸底 `#F7F5F1`、青瓷 `#7E9E92` / 选中底 `#E6EFEB`、超细字重、胶囊选择器、空心圆环开始按钮（详见 `DESIGN.md`）

## 代码结构

```
MeditationAlarmApp/
  App/MeditationAlarmApp.swift     入口；scenePhase 前后台同链；#if DEBUG -selfTest / -seedRecords 钩子
  Session/SessionController.swift  方案 B 调度链、结束分流、常亮不变量、结束确认状态机、跨启动恢复
  Audio/AudioEngine.swift          播放、静音守护、windDownSession 收尾
  Persistence/SessionStore.swift   SwiftData 模型（SessionRecord 一身兼两职：记录 + 恢复）
  Persistence/SessionJournal.swift 记录写入服务（begin / checkpoint / finish / commit / discard / delete / seed）
  Features/Setup/SetupView.swift   设置页
  Features/Setup/DurationCapsulePicker.swift  时长胶囊（DurationOption 档位表 + 组件）
  Features/Session/SessionView.swift  计时页
  Features/Records/RecordsView.swift   记录页（统计 / 日历 / 列表 / 详情 / 删除）
  Features/Records/VitalSectionView.swift   健康区块（hidden/single/series 三态渲染）
  Features/Records/SessionSummaryView.swift  小结页（结束后轻推一格）
  Health/HealthKitService.swift    授权分流 + 正念写入 + 前台重试
  Health/WatchPresence.swift       WCSession.isPaired 手表在位检测
  Health/VitalSampler.swift        三层采样（anchored / observer / 30s 兜底）+ 去重落库
  Features/Root/RootView.swift     根视图 + 结束确认 / 短会话记录两个 alert 状态机
  LiveActivity/LiveActivityController.swift  实时活动生命周期
  Notifications/ReminderScheduler.swift  通知调度（已停用，仅 disarm 清理残留）
MeditationAlarmWidget/             灵动岛与锁屏 Live Activity
Packages/MeditationCore/           计时 / IntervalSchedule / DurationPolicy（App 与 Widget 两 target 直编，不走 SwiftPM 依赖）
Shared/                            两 target 共用：Palette / MeditationControlIntent / MeditationEndIntent / ControlBus / ActivityAttributes / DebugLog
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

- 内核单测：`cd Packages/MeditationCore && swift test`（IntervalSchedule / SessionClock / VitalsBook，47 个）
- 调度链自测：Debug 构建带 `-selfTest` 启动参数（35 秒会话 + 12 秒间隔 + 雨声），看日志验证 GCD 链触发；短于 60s 阈值会顺带验证记录弹框；同时验证健康链路（授权请求 / 采样三层启动 / 去重预热）
- 记录页自测：`-seedRecords` 造 9 条跨日期演示记录（含一个断档验证连续天数，前 3 条带三态体征样本）；`defaults write <bundle-id> debug.openRecords -bool true` 直接进记录页；`debug.openSummary -bool true` 直接弹最新记录的小结页

## 待真机验证 ⏳

模拟器已过（构建 + 记录页四态 + 短/长会话落库 + 40 单测），以下需真机：

1. 前台回归：间隔音 / 背景音正常
2. 后台未锁屏：间隔音正常播放且**无通知**
3. 锁屏跨 ≥2 个间隔都响
4. 锁屏自然到头：三声渐强 + 灵动岛消失
5. 选「无背景音」+ 锁屏（静音守护路径）
6. 暂停 / 继续后再锁屏
7. 自动锁屏设 30s 验证常亮
8. 时长胶囊：横滑跟手性、松手截断位置、点选后自动居中的节奏
9. 键盘收起：点任意处（尤其滚动区空白处）是否顺手
10. **LA 结束按钮**：点结束 → App 打开到前台 → 弹二次确认 → 确认后单声收尾 + 落库（含 App 已被杀时的冷启动路径）
11. **短会话弹框**：真机上开一场 <3 分钟的会话自然结束，确认弹框默认「记录」
12. **跨启动恢复**：会话运行中划掉 App → 重新打开 → 计时/配置/实时活动恢复；再点结束能正常结算

v3a 健康数据（需真机 + 手表）：

13. **授权链路**：首次会话开始弹系统授权页（配对手表时应含读权限项）；拒绝后不再弹、健康区块整体隐藏
14. **正念写入**：授权后开一场 >3 分钟会话并记录 → 健康 App 出现正念分钟数；选「不记录」的会话不写入
15. **心率/HRV 采样**：会话期间手表写入样本 → 结束小结页出现曲线；手表整场没写样本 → 区块隐藏（这是正常现象：静息 5–10 分钟才一条）
16. **后台补录**：会话退后台期间手表写样本 → 回前台后样本补进曲线

## 已知边界

- 划掉 App 后 iOS 不允许进程再发声（通知除外，而通知已按用户决策停用）——这是方案 B 的唯一边界
- `isIdleTimerDisabled` 拦不住侧边按钮手动锁屏（无公开 API）
- 部署目标 iOS 17.0，最低屏宽 375pt（SE3），无 320pt 老屏适配
- SwiftData 对带 relationship 的模型 `delete + save` 在本环境稳定失效（save 静默失败、记录原样留库）——已用「作废标记」等价方案绕过，删功能本身可用（`SessionJournal.delete` 走同一 context，真机需复核）
- 偶发「双 start」竞态（install/launch 时序相关，4 轮复现 2 轮）：已由 begin() 闭合残留 open 记录 + restore 空壳跳过 + @Query 过滤三重防护兜底（最坏 = 一条不可见的作废记录）
- **HKQuery 对象不可二次 execute**：对同一个 `HKAnchoredObjectQuery` 再调 `store.execute` 会抛 NSException 直接崩溃（2026-10-20 模拟器实测 SIGABRT）——观察者唤醒改为走兜底全量拉取，anchored 的 updateHandler 常驻负责即时回调
- 模拟器 HealthKit 可用但无法用 `simctl privacy` 预授权（service 列表无 health），授权 completion 在用户点弹窗前不回调；真机首次会话开始会弹一次授权页
- 正念分钟数在模拟器无法端到端验证（授权弹窗无法自动化点掉），待真机；写入代码路径由 `authorizationStatus` 守卫，未授权时挂起待前台重试
