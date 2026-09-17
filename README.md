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
（`C:\Users\HAPPYE~1\...`），Windows 的 AF_UNIX `connect()` 对这种路径返回 `EINVAL`，
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

# 不需要 Xcode、不需要模拟器即可跑协议测试（测试只依赖与平台无关的 AirChatProtocol）
cd ios/AirChatKit && swift test
```

`ios/README.md` 有完整的首次构建清单与已知注意事项。

## 验证状态

| 项目 | 状态 |
| --- | --- |
| 协议层（帧、分片、加密、会话、节点） | ✅ 56 个测试通过，含 RFC 官方向量 |
| Android 编译 + lint + debug/release APK | ✅ 本机实测通过 |
| Android 真机（发现/连接/后台收消息） | ⏳ 需要真机，模拟器不支持 BLE 外设与扫描 |
| iOS 编译 | ⏳ 需要 Mac（本机无 Xcode），见 `ios/README.md` |
| Android ↔ iOS 互通 | ⏳ 需要 Mac + 双端真机 |

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
