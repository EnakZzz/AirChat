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
| Android ↔ iOS 链路建立 | ✅ 链路可建立；**iOS 侧握手已完成**（拿到 Android 设备 ID 并算出安全码） |
| Android ↔ iOS 完整互通 | ⏳ Android 尚未收到 iOS 的 `HELLO_ACK`（Android 停在 `ready=false`） |

跨机自动化测试：`python3 tools/cross_device_test.py`（在接了两台手机的 Mac 上运行）。它会拉起两端、
解析二者的状态心跳、断言"双向发现 / 链路就绪 / 身份互指 / 角色镜像 / **两端安全码一致**"，并在失败时
直接给出卡在哪一步以及下一步该查什么。上述结论全部由该脚本与设备侧日志得出，不是目测。

真机首跑发现并修复的两个平台级问题（不是猜测，都有设备侧证据）：

1. **iOS 启动即闪退**：给 `CBAdvertisementDataServiceDataKey` 传以 `CBUUID` 为 key 的字典会让
   CoreBluetooth 在编码 XPC 时对 key 调 `UTF8String` 而 abort（带符号崩溃报告已确认）。
   修复：iOS 只广播 Service UUID；Android 不再忽略「没有 presence 块」的对端。详见
   `docs/protocol.md` §4.1。
2. **SSH 下真机签名失败**（`errSecInternalComponent`）：登录钥匙串必须解锁，否则 codesign
   无法取用私钥，即使 `security show-keychain-info` 之外的构建步骤都正常。

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
