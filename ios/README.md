# AirChat for iOS

Swift + SwiftUI 实现，逻辑层放在本地 SwiftPM 包 `AirChatKit` 里，App 目标只是一个薄壳。

## 首次构建清单（在一台 Mac 上）

```bash
# 1. 装 XcodeGen（`.xcodeproj` 是生成物，不入库）
brew install xcodegen

# 2. 先跑协议测试：不需要 Xcode、不需要模拟器，几秒钟就能确认移植是否字节级正确
cd ios/AirChatKit
swift test

# 3. 生成并打开 App 工程
cd ..
xcodegen generate
open AirChat.xcodeproj

# 4. 在 Xcode 里设置你的 Development Team（Signing & Capabilities），选真机运行
```

`swift test` 之所以能脱离 Xcode 运行，是因为 `AirChatBLE` 的外设部分被 `#if os(iOS)` 包起来，
在 macOS 上会退化成一个只报告"不支持"的 stub。这是必需的：SwiftPM 在 `swift test` 时会构建包内
**所有** target，而不是只构建测试的依赖；如果 `AirChatBLE` 直接引用 `CBPeripheralManager`，
整包在 macOS 上根本编译不过，协议测试也就无法脱离真机运行。

真机联调需要**两台**设备：Android ↔ Android、Android ↔ iOS、iOS ↔ iOS 三种组合。

## 关于 iOS 26 / SwiftUI 的取舍

代码只使用长期稳定的 SwiftUI / CoreBluetooth / CryptoKit API，目的是**第一次就能编译通过**：
本机（Windows）没有 Xcode，无法核对新 SDK 的 API 名称，若为了"用最新特性"而写入无法验证的
符号，最可能的结果是编译失败。

因此"用上最新系统特性"这部分按下面处理：

- 已落实且无需新 API 的部分：deployment target iOS 26、`NavigationStack`、`ContentUnavailableView`、
  `@Observable` 之外的标准 SwiftUI 状态管理、系统字体与 Dynamic Type、深浅色自动适配、
  安全区与 `List`/`Form` 的系统外观。
- 建议在 Mac 上按需追加（**请以你本地 SDK 的实际符号为准**）：
  1. iOS 26 起的 Liquid Glass 材质：给卡片/工具栏加玻璃效果。
  2. 把 `AirChatNode.state` 的推送接到 `@Observable` / `ObservableObject` 之外的新观察机制，
     减少手写桥接。
  3. 锁屏实时活动（ActivityKit）显示"正在附近聊天 N 人"。
  4. `CBCentralManager` 的状态恢复已经在用（`CBCentralManagerOptionRestoreIdentifierKey`），
     可以再补 UI 层的恢复提示。

## 结构

```
ios/
  project.yml                  XcodeGen 工程定义（工程结构的唯一真源）
  AirChat/                     App 目标：SwiftUI 视图与接线
    AirChatApp.swift           @main + 组装 AppContainer
    ChatViewModel.swift        把 node 的状态投影成可渲染的数据
    ContentView.swift          四个 Tab 的外壳
    Views.swift                附近 / 公共频道 / 私聊 / 设置 / 安全码弹窗
    Info.plist                 蓝牙用途说明 + 两个后台模式
  AirChatKit/
    Package.swift
    Sources/AirChatProtocol/   纯 Swift：编解码、分片重组、CryptoKit 加密、会话状态机、节点编排
    Sources/AirChatBLE/        CoreBluetooth：广播、扫描、GATT Server 与 Central
    Sources/AirChatData/       系统 libsqlite3 持久化（零第三方依赖）
    Tests/AirChatProtocolTests/XCTest，读取仓库根的 testdata/
```

## 实现要点

- **单线程纪律**：所有 CoreBluetooth 回调先派发到 `BleTransport` 的串行队列，`BleLink` 与
  `LinkSession` 因此不需要任何锁。
- **MTU 由系统决定**：没有 request 接口。Central 侧读 `maximumWriteValueLength(for:)`，
  Peripheral 侧读 `central.maximumUpdateValueLength`。
- **写入用 write-with-response**：ATT 层提供流控；`write-without-response` 在接收方缓冲满时
  会静默丢包，而 v1 没有重传层。CH_RX 仍声明 `writeWithoutResponse` 以备将来。
- **通知流控**：`updateValue` 返回 false 时把分片放回队首，等
  `peripheralManagerIsReady(toUpdateSubscribers:)` 再继续。
- **CCCD 不会回调到 delegate**：订阅状态通过 `didSubscribeTo` / `didUnsubscribeFrom` 观察。
- **AEAD 细节**：CryptoKit 的 `SealedBox.combined` 会在前面带上 nonce，而 AirChat 把 nonce 放在
  帧头，所以显式拼接 `ciphertext + tag`。这是最容易写错、也最难发现的一处互通陷阱，测试里有
  针对性的断言。
- **公钥编码**：CryptoKit 的 `rawRepresentation` 就是 `0x04 || X || Y` 的 65 字节未压缩点，正好
  与 Android（JCA `ECPoint` 展开）一致。

## 后台行为（必须知情）

- App 在后台时 iOS **不再广播服务 UUID**（进入 overflow area），本地名也不会广播；只有前台的
  扫描方能可靠发现它。所以"锁屏时被别人发现"在 iOS 上做不到。
- 已建立的连接仍可接收通知，配合两个 background mode，锁屏后仍能收到消息。
- 设置页已把这一点如实告知用户。

## 排障

| 现象 | 原因与处理 |
| --- | --- |
| `swift test` 报找不到 testdata | 设置 `AIRCHAT_TESTDATA_DIR=/path/to/repo/testdata` |
| Xcode 报签名错误 | 在 Signing & Capabilities 里选你自己的 Team |
| 真机看不到对端 | 确认两台都授予了蓝牙权限、蓝牙已开、距离 10–50 米；打开设置页看诊断日志 |
| 互相看不到但都能广播 | iOS 无法扫描 iOS 后台广播，让至少一台保持前台 |
| 安全码两端不一致 | 说明存在中间人或一端实现偏离契约；不要点"一致"，并检查版本号 |
