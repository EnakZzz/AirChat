# AirChat

完全离线、零服务端的近距离聊天 App。同一个空间里的手机通过 **BLE GATT** 自动发现并组成一个
公共频道，同时支持点对点 **1:1 端到端加密**私聊。两端都是原生实现：

| 平台 | 语言 / UI | 最低系统 |
| --- | --- | --- |
| Android | Kotlin + Jetpack Compose | Android 12（API 31），targetSdk 36 |
| iOS | Swift + SwiftUI | iOS 26 |

## 为什么只能用 BLE

这不是实现选择，而是平台事实：

- **iOS 无法对 Android 使用蓝牙经典（RFCOMM/SPP）**。iOS 的经典蓝牙只对 MFi 认证配件开放。
- `MultipeerConnectivity`（AWDL）**只能在 iOS 之间**使用，Android 不参与。
- 因此跨平台互通只有 **BLE GATT** 一条路，两端角色对称：每台设备**同时**当 GATT Peripheral
  （广播 + GATT Server）和 GATT Central（扫描 + 连接）。

由此还带来几个必须接受的工程后果：单跳直连（不转发）、消息长度与吞吐受限（仅文本）、
iOS 后台发现能力受限（详见 `docs/protocol.md` 第 11 节）。

## 仓库结构

```
docs/protocol.md     线格式的唯一真源：UUID、帧布局、连接规则、加密、存储 schema、上限
testdata/            跨平台黄金测试向量（Kotlin 与 Swift 测试共用同一批文件）
tools/               向量生成器（Python cryptography，独立实现，避免自证）
android/             Gradle 多模块工程
ios/                 XcodeGen 工程 + 本地 SwiftPM 包 AirChatKit
```

## 协议优先

`docs/protocol.md` 是冻结的契约，两端的实现都必须与它字节级一致。为避免"自己验证自己"，
`tools/gen_testvectors.py` 用 Python 的 `cryptography` 独立生成向量：

- HKDF-SHA256 与 ChaCha20-Poly1305 使用 **RFC 5869 / RFC 8439 官方测试向量**（生成时会断言
  公开的期望值，assert 失败就直接报错）；
- P-256 ECDH、会话密钥、6 位安全码、帧与分片重组用的是固定输入下的期望输出。

Kotlin 与 Swift 的测试都读取同一批 JSON，任何一端偏离契约都会在测试里暴露。

修改协议时必须同时：改 `docs/protocol.md`、改两侧实现、重新生成向量。

## Android

```powershell
# 本机（Windows）已实测通过：clean build 含 lint，debug 与 R8 release APK 都会产出
pwsh -File android\build.ps1 :core-protocol:test      # 56 个协议测试
pwsh -File android\build.ps1 :app:assembleDebug       # 产出 android/app/build/outputs/apk/debug
pwsh -File android\build.ps1 clean build
```

**为什么用 `build.ps1` 而不是直接 `gradlew`**：本机进程的 `TEMP` 被展开成 8.3 短名路径
（形如 `C:\Users\<Account>~1\...` 的 8.3 短名路径），Windows 的 AF_UNIX `connect()` 对这种路径返回 `EINVAL`，
导致 JDK 的 `PipeImpl` / `SelectorProvider.openPipe()` 失败，所有 JVM 工具都会报
`Unable to establish loopback connection`。`build.ps1` 只是把 `TEMP`/`TMP` 指向仓库内的
`.tmp`（长路径）后调用 `gradlew`，不改变其它环境。

Android 模块划分把协议逻辑做成**纯 JVM**，因此不需要真机就能验证核心正确性：

- `core-protocol`：纯 Kotlin/JVM，零 Android 依赖（编解码、分片重组、ECDH/HKDF/AEAD、会话
  状态机、节点编排）
- `core-data`：Room 持久化，实现协议里的 `ChatStore` 契约
- `core-ble`：`BluetoothLeAdvertiser` / `BluetoothLeScanner` / GATT Server + Client
- `app`：Compose UI + `connectedDevice` 前台服务

## iOS

```bash
brew install xcodegen
cd ios && xcodegen generate && open AirChat.xcodeproj

# 不需要 Xcode、不需要模拟器、不需要真机即可跑协议测试
cd ios/AirChatKit && swift test
```

`ios/README.md` 有完整的首次构建清单与已知注意事项。

## 交互：「附近」页是怎么用的

**扫描是用户的动作**：App 启动后不找人（只广播，所以别人扫你仍然能找到你），点一次「扫描」
找 30 秒后自动停止，期间发现的人会自动连上；已建立的链路不受扫描窗口结束影响。

**连接**由后台自动完成（公共频道要发给附近所有人，所以不能等用户逐一点击），但**点谁、核对谁、
跟谁说话**都由用户决定。「附近」页因此是**一个人一行**，一行只有一个动作：

| 行状态 | 显示 | 点一下 |
| --- | --- | --- |
| 待核对 | 昵称 + 「待核对」 | 弹出 6 位安全码，与对方面对面比对 |
| 已连接 | 昵称 + 「已连接」 | 直接进入该对话 |
| 可连接 | 匿名短名 + 信号强度 | 立刻向 TA 发起连接（行变「连接中」） |
| 连接中 | 匿名短名 + 转圈 | 无（已经在连了） |
| 已拒绝 | 昵称 + 「已拒绝」 | 重新弹出安全码，可以改判 |

- 握手完成前拿不到昵称，显示 `附近设备 · 9B42`（平台句柄的稳定尾 4 位）与信号强弱；
  握手一完成就换成真实昵称，并在断连后继续记住。
- **安全码只在"你点过的那个人"连上时自动弹出一次**，其余自动连接不会打断你——一屋子人时
  否则会连续弹窗。20 秒内没连上会明确告知，而不是静默失败。
- 核对通过即视为连接成功，直接落到该对话里；未核对也能进对话发消息，顶部保留黄条警示。
- MTU、连接方向、对方是否已确认安全码这类细节放在「设置 → 连接详情」，不再挤在附近列表里。

## 验证状态

| 项目 | 状态 |
| --- | --- |
| 协议层 Kotlin（Windows / JDK 17） | ✅ 56 个测试通过，含 RFC 5869 / 8439 官方向量 |
| 协议层 Swift（macOS 27 + Xcode 27 / Swift 6.4） | ✅ 50 个测试通过，读取同一批 `testdata/` 向量 |
| Android 编译 + lint + debug/release APK | ✅ 实测通过 |
| iOS 编译（iOS SDK 27.0，模拟器 SDK） | ✅ `xcodebuild` BUILD SUCCEEDED |
| iOS 真机编译 + 安装（iPhone 12 / iOS 27） | ✅ `BUILD SUCCEEDED` + `devicectl` 安装成功 |
| iOS 真机运行 | ✅ 启动、广播+扫描已运行、身份已持久化（修复了一次启动闪退，见下） |
| Android 编译 + APK 构建 | ✅ 实测通过（Windows） |
| Android 真机安装与运行 | ✅ 安装并运行，广播+扫描正常，身份已持久化 |
| Android ↔ iOS 相互发现 | ✅ 双向发现（Android 能读到 iOS 的广播，iOS 能读到 Android 的 presence 块） |
| Android ↔ iOS 链路建立 + 握手 | ✅ **`tools/cross_device_test.py` 判定 PASS**：链路就绪、双方 identity 互指、角色镜像 |
| **Android ↔ iOS 端到端加密一致性** | ✅ 两端独立算出**相同**的 6 位安全码（实测 `476390`），证明 Kotlin/JCA 与 Swift/CryptoKit 字节级一致 |
| 扫描改为用户动作（30 秒窗口自动停） | ✅ 两端实现一致；单测覆盖"启动不扫/窗口自动关闭/提前停止不影响既有链路" |
| 「附近」页交互（点人即连 / 核对 / 进对话） | ✅ 两端实现一致；真机 `--connect-first` **PASS**（双方各自点人后 `verifyPrompts` 均为 1）；单测另覆盖点到已信任者不弹、点击过期、去重串联、上限拒绝、句柄跨角色变化、两候选不猜 |
| 消息收发（公共频道 / 1:1） | ✅ **双向均通**：公频文本互达；1:1 密文双向解密成功（`secret-from-android` / `secret-from-ios`），且双向都收到 `DELIVERY_ACK` |
| 锁屏后台收消息 | ⏳ 未验证 |

跨机自动化测试：`python3 tools/cross_device_test.py`（在接了两台手机的 Mac 上运行）。它会拉起两端、
解析二者的状态心跳、断言九项——双向发现 / 链路就绪 / 身份互指 / 角色镜像 / **两端安全码一致** /
双向公频文本 / **双向 1:1 密文解密文本** / 双向 `DELIVERY_ACK`，并在失败时直接给出卡在哪一步以及
下一步该查什么。上述结论全部由该脚本与设备侧日志得出，不是目测。

加 `--connect-first` 则改走**点击路径**：两端各自"点一下"第一个扫到的人，断言双方建链成功且双方
都收到了核对安全码的请求（实测 `verifyPrompts: iOS=1, Android=1`）。一次启动不能既发脚本消息又
点人，所以完整验证要跑两次。`--connect-first` 与脚本消息注入都会先触发一次扫描（并给足窗口），因为这两条调试路径模拟的是
"用户先点了扫描"。加 `--reset` 会先卸载两端，从"没有任何已核对记录"的状态开始 ——
安全码一旦确认过就会持久化，这正是"不再弹窗"的正确行为，因此验证*首次*连接必须从干净状态跑。

用例注入的副本（`AIRCHAT_SELFTEST` / `airchat_selftest`）使用 `,` 分隔并不能改成 `|`：
`adb shell` 会把这个值交给设备自己的 shell，未加引号的 `|` 会被当成管道，intent extra 会在管道处被截断。
两端会把收到的脚本原文写入日志，脚本也对这行日志做断言，因此参数被截断会直接报成
"脚本没传全"，而不是变成一个「神秘没收到的消息」。

真机调试中发现并修复的问题（不是猜测，都有设备侧证据）：

1. **iOS 启动即闪退**：给 `CBAdvertisementDataServiceDataKey` 传以 `CBUUID` 为 key 的字典会让
   CoreBluetooth 在编码 XPC 时对 key 调 `UTF8String` 而 abort（带符号崩溃报告已确认）。
   修复：iOS 只广播 Service UUID；Android 不再忽略「没有 presence 块」的对端。详见
   `docs/protocol.md` §4.1。
2. **SSH 下真机签名失败**（`errSecInternalComponent`）：登录钥匙串必须解锁，否则 codesign
   无法取用私钥，即使 `security show-keychain-info` 之外的构建步骤都正常。
3. **HELLO 只能走单向**：CH_CTRL 在协议里是双向的，但 iOS 侧只接收写到 CH_RX 的数据，
   因此当 iOS 是外设时对端的 HELLO 被静默丢弃、握手永远完成不了。
4. **外设发送队列只发首片**：等待一个 CoreBluetooth 根本不会给的
   “通知已送达”回调，导致 97 字节的 HELLO_ACK 只出去了前 20 字节。
   现在以 `updateValue` 的返回值作为唯一背压信号，并由 `peripheralManagerIsReady` 恢复。
5. **重连后对着陈旧的 `CBCentral` 发通知**：重连会产生一个 identifier 相同但对象不同的
   `CBCentral`，对着旧对象发通知既不报错也不会被缓存，通知就这么消失了。
6. **Android 埋点加在了 API 31 不走的重载上**：`requestMtu` / CCCD / `writeCharacteristic` 都有新旧
   两套重载，日志写在没被调用的那一个上，于是「日志里什么都没有」被误判成「什么都没发生」。
7. **自动化用例的副本被 `adb shell` 截断**：`--es airchat_selftest a|b` 中的 `|` 被设备 shell
   当成管道，App 只收到 `a`，于是「只有 Android→iOS 私聊不通」这个假象被误读了两轮。
   它不是应用缺陷，但得出结论的方式与上面同样重要：两端现在都会把收到的脚本
   原文写进日志，脚本也会断言这一行。

另有一处非缺陷但会误导排查的现象：`devicectl --console` 报
`Mercury error 1001 / connection was invalidated` 是**工具与设备的 XPC 通道断开**（设备锁屏或
网络配对不稳定），与应用崩溃无关；应用崩溃应看 `AirChat-*.ips`。

## 安全模型

- 1:1 消息：P-256 ECDH → HKDF-SHA256 → ChaCha20-Poly1305，AAD 绑定 msgId 与双方设备 ID。
- 防中间人：首次会话两端显示**同一个 6 位安全码**，用户当面核对后才标记为可信。
- 公共频道：**不加密、不签名**。单跳直连保证 `senderId` 必须是当前连接的对端，因此无法伪造
  他人身份；但内容对范围内任何已连接设备可见。
- v1 **不做**：前向保密（无棘轮）、群组加密、账号体系、云中继。

## 已知限制

- 距离约 10–50 米，单跳，不转发。
- 仅文本（≤1000 字），BLE 吞吐有限。
- 并发链路上限 8 条（跨平台安全值），达到后停止扫描并提示。
- iOS 锁屏后无法被其他设备发现（系统限制），但已建立的连接仍可收消息。
- **扫描是手动的**：不点「扫描」就发现不了新的人，链路断了也不会自动重连，需要再扫一次
  （对方点扫描同样能连上你，因为广播一直开着）。
- **平台句柄不是身份**：iOS 上同一个人「扫描到的标识」与「连上来的标识」是两个不同的
  CoreBluetooth identifier（真机实测）。所以「附近」页把某个广播条目与某条链路认作同一个人时，
  在句柄对不上时改用**排除法**：只有当「句柄没出现在广播列表里的链路」与「还没归属的广播条目」
  **各恰好一个**时才配对；出现两个候选就明确不猜，宁可短暂多出一行，也不把某人的安全码挂到
  另一个人身上。Android 不受影响（两种角色都报对端 BLE 地址）。
