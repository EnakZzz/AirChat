# AirChat Wire Protocol v1

本文件是 AirChat 线协议与跨平台常量的**唯一真源**。Android（Kotlin）与 iOS（Swift）
两端的实现必须以本文件为准；任何改动都必须同时更新 `testdata/` 下的黄金向量。

适用范围：单跳直连（不做多跳中继）、完全离线（无服务端）、仅传输 UTF-8 文本。

---

## 1. 术语

| 术语 | 含义 |
| --- | --- |
| Node | 一台运行 AirChat 的设备 |
| Link | 一条 BLE GATT 连接（Node ↔ Node） |
| Central | 发起 GATT 连接的一方 |
| Peripheral | 被连接的一方，同时运行 GATT Server |
| Initiator | 握手中**先发送 HELLO** 的一方（等价于 Central） |
| Responder | 用 HELLO_ACK 回应的另一方（等价于 Peripheral） |
| Peer | 通过某个 Link 相连的对端 |
| Room | 由同一物理空间内所有直连 Node 组成的集合（无中心） |
| Channel | 公共频道，房间内所有 Node 共享的一个明文会话 |

---

## 2. 常量

### 2.1 GATT UUID（4 个）

| 名称 | UUID |
| --- | --- |
| Service | `a1c0a000-1e63-4b5a-9d2f-0f1e2d3c4b5a` |
| CH_CTRL | `a1c0a001-1e63-4b5a-9d2f-0f1e2d3c4b5a` |
| CH_TX | `a1c0a002-1e63-4b5a-9d2f-0f1e2d3c4b5a` |
| CH_RX | `a1c0a003-1e63-4b5a-9d2f-0f1e2d3c4b5a` |

### 2.2 广播用 16 位别名 UUID

| 名称 | 值 |
| --- | --- |
| PRESENCE_UUID16 | `0xA1C0` |

`0xA1C0` 仅用于 Service Data（AD type `0x16`）中承载**存在性提示**。
它绝不参与任何决策，只用于快速预筛；权威信息一律来自 HELLO 帧。

### 2.3 数值上限

| 常量 | 值 | 说明 |
| --- | --- | --- |
| PROTOCOL_VERSION | 1 | 帧头与 HELLO 中的协议版本 |
| MAX_PAYLOAD_BYTES | 6144 | 单帧 payload 上限，超出即视为致命错误 |
| MAX_CHUNK_BYTES | 512 | 单个 GATT 分片上限（跨平台安全上限） |
| MAX_LINKS | 8 | 单个 Node 的并发 Link 上限（含 Central 与 Peripheral 角色） |
| MAX_NICKNAME_BYTES | 32 | 昵称 UTF-8 字节上限 |
| MAX_TEXT_BYTES | 4000 | 消息正文 UTF-8 字节上限 |
| MAX_TEXT_CHARS | 1000 | 消息正文字符上限（UI 层约束） |
| CHANNEL_RETAIN_COUNT | 500 | 公共频道本地保留条数 |
| CHANNEL_RETAIN_DAYS | 7 | 公共频道本地保留天数 |
| DEFAULT_MTU | 23 | BLE 默认 ATT MTU（可用载荷 = MTU - 3 = 20）。MTU 未知或 ≤ 0 时回落到该值 |
| PREFERRED_MTU | 517 | Central 连接后请求的 MTU |
| HANDSHAKE_TIMEOUT_MS | 10000 | 握手超时 |
| PING_INTERVAL_MS | 15000 | 保活间隔 |
| LINK_IDLE_TIMEOUT_MS | 45000 | 无任何入站数据后判定链路失活 |
| SCAN_RETRY_AFTER_MS | 6000 | 单向连接回退等待时间，见 §5.3 |
| SYNC_SINCE_MINUTES | 10 | 补拉历史的时间窗口 |
| SYNC_MAX_COUNT | 50 | 补拉历史的条数上限 |

### 2.4 能力位

`capabilities` 为 1 字节位图，v1 定义：

| 位 | 名称 | 含义 |
| --- | --- | --- |
| 0 | CAP_PRIVATE | 支持 1:1 私聊 |
| 1 | CAP_SYNC | 支持公共频道历史补拉 |
| 2-7 | — | 保留，发送方必须置 0，接收方必须忽略 |

---

## 3. 基本编码规则

- **所有多字节整数一律大端序（big-endian / network order）。**
- 有符号 64 位时间戳为 `i64`（自 Unix epoch 起的毫秒数），大端。
- 字符串一律为 UTF-8 字节序列，前置 1 字节长度（`u8`），长度单位是**字节**。
- 定长字段（`deviceId`、`msgId`、公钥、nonce）不加长度前缀。
- 变长字段（昵称、文本、密文）前置 `u16` 字节长度。
- 未使用的保留字段发送方置 0，接收方忽略。

---

## 4. 广播格式（Advertising）

Legacy advertising（Android 侧显式 `setLegacy()`）。

AD 结构拼接顺序：

1. Flags：`0x06 0x02 0x06 0x1A`（LE General Discoverable + BR/EDR Not Supported）
2. Complete 128-bit Service UUID List（AD type `0x07`）：Service UUID
3. Service Data - 16-bit UUID（AD type `0x16`）：UUID16 = `0xA1C0`，数据为 4 字节存在性块

存在性块（4 字节，**可选**）：

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8 | protocolVersion |
| 1 | u8 | capabilities |
| 2 | u16 | ticket（随机连接凭据，见 §5.3） |

总长度：`4 + 18 + 8 = 30` 字节 ≤ 31，可在 legacy 包内完整携带。

**不广播昵称**：昵称通过 HELLO 交换。原因见 §11.3（iOS 后台广播限制）。

### 4.1 存在性块是可选的非权威提示（重要）

接收方**必须**容忍它不存在，并据此生成一个替代 ticket；**不得**因缺失而忽略该对端。

原因：**iOS 无法发送 Service Data**。给
`CBAdvertisementDataServiceDataKey` 传以 `CBUUID` 为 key 的字典时，CoreBluetooth 在把参数
编码成 XPC 消息时会 abort。iOS 27 上的带符号崩溃报告：

```
CBXpcCreateXPCDictionaryWithNSDictionary
  -> -[CBUUID UTF8String]  -> NSInvalidArgumentException（unrecognized selector）
  <- -[CBPeripheralManager startAdvertising:]  <- BleTransport.startAdvertising()
```

后果与代价（已接受）：

- Android 仍然发送存在性块，因此 **Android ↔ Android** 仍能使用 §5.3 的 ticket 优化；
- **Android ↔ iOS / iOS ↔ iOS** 退化为：没读到存在性块的一方按对端地址派生一个伪 ticket，
  仅用于在本次相遇内保持决策稳定；
- 伪 ticket 两侧可能"都不发起"，所以 §5.3 的回退规则（`SCAN_RETRY_AFTER_MS`）是**必须**的，
  它保证最终一定有人发起连接；由此产生的重复链路由 §5.4 去重。
- 净代价：最坏情况下多建立一条冗余连接、连接建立延迟一个 `SCAN_RETRY_AFTER_MS`。

---

## 5. 连接建立

### 5.1 GATT 服务结构

Peripheral 暴露一个 Service 与三个 Characteristic：

| Characteristic | 属性 | 方向 | 用途 |
| --- | --- | --- | --- |
| CH_CTRL | NOTIFY + WRITE | 双向 | 握手与信令（HELLO / HELLO_ACK / KEY_VERIFY / PING / PONG） |
| CH_TX | NOTIFY | Peripheral → Central | 数据流 |
| CH_RX | WRITE + WRITE_NO_RESPONSE | Central → Peripheral | 数据流 |

连接后 Central 必须：

1. 发现 Service 与三个 Characteristic；
2. 订阅 CH_CTRL 与 CH_TX 的 CCCD（`0x2902`）；
3. 请求较大 MTU（Android `requestMtu(517)`；iOS 由系统协商，读 `maximumWriteValueLength`）。

### 5.2 双向语义

握手完成后，两侧数据通路语义对称：

- 对 Central 而言：**出站 = 写 CH_RX**，**入站 = CH_TX 通知 + CH_CTRL 通知**；
- 对 Peripheral 而言：**出站 = CH_TX 通知 + CH_CTRL 通知**，**入站 = CH_RX 写入**。

数据帧（type ≥ 0x10）走 CH_TX / CH_RX；信令帧（type ≤ 0x0F、0x30、0x31、0x7E、0x7F）走 CH_CTRL。
实现可以简化：把 CH_CTRL 与 CH_TX 的入站字节流**按到达顺序合并进同一个重组缓冲区**，因为帧协议自带长度信息。

### 5.3 连接方向决策（避免 N² 重复连接）

每台 Node 同时广播与扫描，因此必须确定性地决定谁发起连接。

1. 每个 Node 在每次开始广播时生成一个随机 `u16 ticket`，写入存在性块。
2. 扫描到对端存在性块后：
   - 若 `myTicket < theirTicket` → 本机发起 Central 连接；
   - 若 `myTicket > theirTicket` → 本机不连接，等待对端发起；
   - 若 `myTicket == theirTicket` → 双方都会连接，由 §5.4 去重解决。
3. **回退规则**：若某对端持续可见超过 `SCAN_RETRY_AFTER_MS`（6000ms），且本机未达
   `MAX_LINKS`、且与该对端尚未建立 Link，则无论 ticket 大小本机都主动连接。
   这保证对端因自身已满/异常而未能发起时仍能建链。
4. 同一对端在短时间内（< 2000ms）重复发起连接失败时，退避 3000ms 再试，避免连接风暴。

### 5.4 重复 Link 去重

握手交换真实 `deviceId` 后，若发现对同一 `deviceId` 已存在 Link，则按以下**确定性规则**保留一条：

> 保留 `Central 的 deviceId 较小` 的那条 Link，断开另一条。

两端依据同一规则得出相同结论，故必然收敛。规则比较的是 `deviceId` 的 16 字节
**无符号字典序**。

### 5.5 Link 上限

- 达到 `MAX_LINKS` 后停止扫描并在 UI 提示「附近人数已满」。
- 已建立的 Link 不受影响；一旦有 Link 断开，立即恢复扫描。

### 5.6 保活与失活

- 每 `PING_INTERVAL_MS` 在闲置 Link 上发送 PING，收到任意入站数据即刷新活跃时间。
- 超过 `LINK_IDLE_TIMEOUT_MS` 无入站数据 → 主动断开并标记链路失活。
- 断开后若对端仍在广播，重新走 §5.3 建链（ticket 保持不变）。

---

## 6. 帧格式与流式重组

### 6.1 帧头

```
偏移  长度  类型   字段
0     1     u8     version       必须为 PROTOCOL_VERSION
1     1     u8     type
2     2     u16    payloadLength
4     N     u8[]   payload
```

头部固定 4 字节。

### 6.2 流式重组

GATT 的写入与通知都是**无边界字节流**，帧可能被切开或粘连。约定：

- 发送方把完整的帧字节序列按 `chunkSize = min(mtu - 3, MAX_CHUNK_BYTES)` 顺序切片发送。
- 接收方维护累积缓冲区，循环执行：
  1. 缓冲不足 4 字节 → 等待更多数据；
  2. 读 `version`，若不是 1 → **致命错误**，清空缓冲并断开 Link；
  3. 读 `type` 与 `payloadLength`；
  4. 若 `payloadLength > MAX_PAYLOAD_BYTES` → **致命错误**，清空缓冲并断开 Link；
  5. 缓冲不足 `4 + payloadLength` → 等待更多数据；
  6. 取出完整帧，交付上层，继续循环。
- 未知 `type`：**分层契约** —— 成帧器（framer）是纯字节流解析器，只负责正确切分帧，
  必须把未知类型原样上交给会话层并保持同步；**由会话层负责丢弃**未知类型。
  这样做的原因是成帧器不应承担协议策略，且将来新增消息类型只需改会话层。
  两端实现必须遵循同一分层，否则 `testdata/frames.json` 的
  `sticky_across_three_chunks_25` 用例会不一致。
- 注意：`Hello` 帧的 payload 最大 2+16+1+32+65+1+8 = 125 字节，需按同一规则分片。

### 6.3 写入方式

v1 实现**使用 write-with-response**（Android `WRITE_TYPE_DEFAULT`，iOS
`writeValue(_:for:type:.withResponse)`）。

理由：write-with-response 由 ATT 层提供逐包确认与流控；write-without-response
在接收方内部缓冲满时会**静默丢弃**分片，导致字节流损坏，而 v1 不包含重传层。
CH_RX 同时声明 `WRITE_NO_RESPONSE` 属性仅为将来兼容，v1 不使用。

Peripheral 侧发送通知必须做流控：
- Android：依赖 `onNotificationSent` 回调逐包推进；
- iOS：`updateValue` 返回 `false` 时等待 `peripheralManagerIsReady(toUpdateSubscribers:)`。

---

## 7. 消息类型总表

| type | 名称 | 通道 | payload |
| --- | --- | --- | --- |
| 0x01 | HELLO | CH_CTRL | §8.1 |
| 0x02 | HELLO_ACK | CH_CTRL | §8.1（结构相同） |
| 0x10 | CHANNEL_POST | CH_TX / CH_RX | §8.2 |
| 0x11 | PRIVATE_MSG | CH_TX / CH_RX | §8.3 |
| 0x12 | DELIVERY_ACK | CH_TX / CH_RX | §8.4 |
| 0x13 | TYPING | CH_TX / CH_RX | §8.5 |
| 0x20 | SYNC_REQ | CH_TX / CH_RX | §8.6 |
| 0x21 | SYNC_RESP | CH_TX / CH_RX | §8.7 |
| 0x30 | KEY_VERIFY_REQ | CH_CTRL | 空 |
| 0x31 | KEY_VERIFY_RESP | CH_CTRL | §8.8 |
| 0x7E | PONG | CH_CTRL | 空 |
| 0x7F | PING | CH_CTRL | 空 |

未知 type 一律跳过 payload。

---

## 8. payload 布局

### 8.1 HELLO (0x01) / HELLO_ACK (0x02)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u16 | protocolVersion（=1） |
| 2 | u8[16] | deviceId |
| 18 | u8 | nicknameLength（0..32） |
| 19 | u8[nicknameLength] | nickname（UTF-8） |
| 19+n | u8[65] | publicKey（`0x04 ‖ X(32) ‖ Y(32)`，P-256 未压缩点） |
| 84+n | u8 | capabilities |
| 85+n | u8[8] | helloNonce（随机） |

HELLO_ACK 使用完全相同的结构。`helloNonce` 仅用于安全码转录（§10.3）。

握手时序：

1. Initiator（Central）在订阅完成后立即发送 HELLO；
2. Responder 收到 HELLO 后必须回 HELLO_ACK；
3. 双方在**收到对端 HELLO/HELLO_ACK 后**即进入 READY 并派生会话密钥；
4. 超过 `HANDSHAKE_TIMEOUT_MS` 未完成 → 断开 Link；
5. `protocolVersion` 不匹配 → 断开 Link 并在 UI 提示版本不一致。

### 8.2 CHANNEL_POST (0x10)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8[16] | msgId |
| 16 | i64 | timestampMillis（发送方时钟） |
| 24 | u8[16] | senderId |
| 40 | u8 | nicknameLength |
| 41 | u8[nicknameLength] | senderNickname（快照） |
| 41+n | u16 | textLength |
| 43+n | u8[textLength] | text（UTF-8，明文） |

约束：`senderId` 必须等于本 Link 对端的 `deviceId`，否则丢弃（§9）。
`textLength ≤ MAX_TEXT_BYTES`，昵称长度 ≤ `MAX_NICKNAME_BYTES`。

### 8.3 PRIVATE_MSG (0x11)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8[16] | msgId |
| 16 | i64 | timestampMillis |
| 24 | u8[16] | senderId |
| 40 | u8[16] | recipientId |
| 56 | u8[12] | nonce |
| 68 | u16 | ciphertextLength |
| 70 | u8[ciphertextLength] | ciphertext ‖ tag（AEAD 输出） |

明文为 UTF-8 文本，长度 ≤ `MAX_TEXT_BYTES`；故 `ciphertextLength ≤ MAX_TEXT_BYTES + 16`。

### 8.4 DELIVERY_ACK (0x12)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8[16] | msgId |
| 16 | u8 | status |

status：`0 = DELIVERED`，`1 = UNDECRYPTABLE`。

约定：**即使因为重复 msgId 而丢弃消息，也必须回 ACK**，以终止对端重试。

### 8.5 TYPING (0x13)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8 | scope（0 = channel，1 = private） |
| 1 | u8 | state（0 = stop，1 = start） |
| 2 | u8[16] | recipientId（scope=0 时全 0） |

定长 18 字节。发送方即本 Link 对端，不带 senderId。

### 8.6 SYNC_REQ (0x20)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8[16] | requesterId |
| 16 | u16 | sinceMinutesAgo |
| 18 | u16 | maxCount |

### 8.7 SYNC_RESP (0x21)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u16 | count |
| 2 | — | count 个「u16 长度 + CHANNEL_POST payload 原始字节」 |

发送方必须保证整个 payload ≤ `MAX_PAYLOAD_BYTES`；容纳不下的条目直接省略
（count 相应减少）。接收方按 `senderId == 对端 deviceId` 校验后逐条入库。

### 8.8 KEY_VERIFY_RESP (0x31)

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8 | result（0 = rejected，1 = accepted） |

---

## 9. 报文校验规则

1. 帧头 `version != 1` → 致命错误，断开 Link。
2. `payloadLength > MAX_PAYLOAD_BYTES` → 致命错误，断开 Link。
3. payload 长度与声明不符（读越界）→ 丢弃该帧，继续处理后续帧。
4. `CHANNEL_POST` / `PRIVATE_MSG` / `SYNC_REQ` 中的 `senderId` 不等于本 Link 对端的
   `deviceId` → 丢弃（防伪造）。单跳不转发，故该约束恒成立。
5. `PRIVATE_MSG.recipientId` 不等于本机 `deviceId` → 丢弃。
6. 已处理过的 `msgId` → 丢弃内容，但仍回 `DELIVERY_ACK`。
7. 未知 `type` → 跳过 payload。

---

## 10. 加密

### 10.1 身份密钥

- 算法：ECDH，曲线 **NIST P-256（secp256r1）**。
- 每台设备首次启动生成一对长期身份密钥并持久化。
- 公钥序列化：未压缩点 `0x04 ‖ X(32, 大端) ‖ Y(32, 大端)`，共 65 字节。
- 私钥仅保存在应用私有存储中，绝不外发。

### 10.2 会话密钥派生

设两端的 `deviceId` 按 16 字节无符号字典序排序后为 `first`、`second`：

```
IKM  = ECDH(myPrivKey, peerPubKey)                     // 32 字节，X 坐标
salt = SHA-256("AirChat-v1-salt")                      // 32 字节
info = "AirChat-v1-session-key"                        // 21 字节 ASCII
     ‖ first.deviceId  (16)
     ‖ second.deviceId (16)
     ‖ first.publicKey (65)
     ‖ second.publicKey(65)
OKM  = HKDF-SHA256(IKM, salt, info, 32)                // RFC 5869，会话密钥
```

双方各自计算所得 `OKM` 必须完全一致。会话密钥**不随消息变化**（v1 无前向保密）。

### 10.3 安全码（防中间人）

```
transcript = "AirChat-v1-safety"                       // 18 字节 ASCII
           ‖ first.deviceId  ‖ second.deviceId
           ‖ first.publicKey‖ second.publicKey
           ‖ initiatorHelloNonce (8)
           ‖ responderHelloNonce (8)
h      = SHA-256(transcript)
value20 = (h[0] << 12) | (h[1] << 4) | (h[2] >> 4)     // 20 bit
code    = value20 % 1000000                            // 0..999999
显示    = 6 位十进制零填充，如 "004271"
```

`initiator` 为 Central（先发 HELLO 的一方），`responder` 为 Peripheral。双方必须得到
相同的 6 位码；不一致说明存在中间人或实现不一致，必须警告用户。

信任流程：

1. 双方首次建立 1:1 时，会话状态为 **UNVERIFIED**，UI 明确标注；
2. 用户打开核对页，双方比对 6 位码；
3. 用户确认一致 → 将 `peers.trust_state` 置为 `1`（trusted）并持久化；
4. 任一方点击「不匹配」→ 置为 `2`（rejected），拒绝 1:1 且提示风险；
5. `publicKey` 发生变化（可能为设备重装或中间人）→ 强制回落到 UNVERIFIED 并要求重新核对。

`KEY_VERIFY_REQ` / `KEY_VERIFY_RESP` 用于把「已核对」的结论同步给对端，便于两端同时
更新存储；但**用户确认只在本机生效**，不接受对端自动置为 trusted。

### 10.4 AEAD

- 算法：`ChaCha20-Poly1305`，12 字节随机 nonce，16 字节 tag。
- AAD = `msgId(16) ‖ senderId(16) ‖ recipientId(16)`，共 48 字节。
- 随机 nonce 由平台 CSPRNG 生成；同一会话密钥下 nonce 重复概率可忽略。

### 10.5 v1 明确不提供的安全属性

- 无前向保密（静态 ECDH，无双棘轮）；
- 公共频道不加密、不签名（任何已连接的对端都可发送公共频道消息，但无法伪造他人 `senderId`，见 §9.4）；
- 不对抗设备已被物理控制/越狱的场景；
- 不做流量分析防护。

---

## 11. 平台差异与已知限制

### 11.1 链路数量

Android 与 iOS 的 LE 连接数都有实际上限（经验值 7–8）。因此 `MAX_LINKS = 8` 是
**跨平台安全值**，两端必须一致，否则会出现一方认为已满、另一方仍在连的不对称。

### 11.2 分片大小

- Android Central：连接后 `requestMtu(517)`，以 `onMtuChanged` 的实际值计算。
- iOS Central：由系统协商，读 `peripheral.maximumWriteValueLength(for:)`。
- iOS Peripheral：必须按 `central.maximumUpdateValueLength` 计算通知分片。
- 统一上限 `MAX_CHUNK_BYTES = 512`。

### 11.3 iOS 后台限制

- 进入后台后，iOS 广播**不再携带 Local Name**，且 128 位 Service UUID 被移入
  「overflow area」，只有前台扫描的 App 能可靠发现它。
- 因此设计上选择：**昵称等一切语义信息都不放在广播里**，广播只用于发现。
- 后台仍可接收 `bluetooth-central` 通知，即已建立的 Link 可以继续收消息。
- 结论：iOS 后台**可收、可被前台设备连接，但不保证能被其他后台设备发现**。此为平台
  限制，需在设置页向用户如实说明。

### 11.4 其他

- 模拟器/仿真器**不支持** BLE 外设与扫描，联调必须使用真机。
- BLE 带宽有限（实际吞吐常在 KB/s 量级），v1 仅支持文本。

---

## 12. 本地存储 schema（两端字段名一致）

### identity（单行，id 恒为 1）

| 列 | 类型 | 说明 |
| --- | --- | --- |
| id | INTEGER PK | 恒为 1，保证只有一行 |
| device_id | BLOB(16) | 本机 deviceId |
| private_key | BLOB | 私钥。平台相关编码：Android 为 PKCS#8，iOS 为 CryptoKit 的 32 字节 raw scalar |
| public_key | BLOB(65) | 未压缩点，与 `private_key` 配对。两端都必须持久化它，因为 JCA 无法从私钥标量推导公钥 |
| nickname | TEXT | 用户昵称 |
| created_ms | INTEGER | 首次生成时间 |

> 身份一旦生成就不再变更；重新生成会使所有对端存储的公钥失效并要求重新核对安全码。

### peers

| 列 | 类型 | 说明 |
| --- | --- | --- |
| device_id | BLOB(16) PK | 对端 deviceId |
| nickname | TEXT | 最近一次已知昵称 |
| public_key | BLOB(65) | 最近一次已知公钥 |
| trust_state | INTEGER | 0 = unverified，1 = trusted，2 = rejected |
| last_seen_ms | INTEGER | 最近一次见到（毫秒） |
| created_ms | INTEGER | 首次见到（毫秒） |

### messages

| 列 | 类型 | 说明 |
| --- | --- | --- |
| msg_id | BLOB(16) PK | 消息唯一 ID，天然去重 |
| conversation_id | TEXT | `channel` 或私聊对端 deviceId 的 32 位小写 hex |
| kind | INTEGER | 0 = channel，1 = private |
| direction | INTEGER | 0 = 收到，1 = 发出 |
| sender_id | BLOB(16) | 发送方 |
| recipient_id | BLOB(16) NULL | 私聊时为接收方，公共频道为 NULL |
| text | TEXT | 明文文本 |
| timestamp_ms | INTEGER | 发送方时间戳 |
| received_ms | INTEGER | 本机首次处理时间（排序兜底） |
| status | INTEGER | 0 = local，1 = sent，2 = delivered，3 = failed |

排序键：`COALESCE(timestamp_ms, received_ms)` 与 `received_ms` 组合，避免对端时钟漂移
导致乱序。索引：`(conversation_id, received_ms)`、`(status)`。

### sessions

| 列 | 类型 | 说明 |
| --- | --- | --- |
| peer_device_id | BLOB(16) PK | 对端 deviceId |
| session_key | BLOB(32) | 派生出的会话密钥 |
| peer_public_key | BLOB(65) | 派生时使用的对端公钥 |
| verified | INTEGER | 0/1 |
| created_ms | INTEGER | |
| last_used_ms | INTEGER | |

状态值：`messages.status` 中 `1 = sent`（已写入至少一条 Link）、`2 = delivered`
（收到 DELIVERY_ACK）。UI 对应单勾 / 双勾。

---

## 13. 测试向量

`testdata/` 下的 JSON 被 Kotlin 与 Swift 测试共同读取并断言，保证两端字节级一致：

| 文件 | 内容 |
| --- | --- |
| `hkdf-sha256-rfc5869.json` | RFC 5869 官方 HKDF-SHA256 测试向量 |
| `chacha20poly1305-rfc8439.json` | RFC 8439 §2.8.2 官方 AEAD 测试向量 |
| `p256-ecdh.json` | 固定私钥对与期望 ECDH 共享密钥 |
| `session-key.json` | 固定输入的期望会话密钥 |
| `safety-number.json` | 固定输入的期望 6 位安全码 |
| `frames.json` | 帧编码/解码与分片重组用例 |

向量由独立实现（Python `cryptography`）生成，与两端实现互为交叉验证，避免自证。

---

## 14. 版本策略

- 帧头 `version` 与 HELLO 的 `protocolVersion` 必须同时为 `1`。
- 主版本不一致 → 拒绝建链并在 UI 提示「对方版本不兼容」。
- 新增消息类型（未占用 type）不改变主版本，接收方按 §6.2 跳过未知类型。
- 修改已有 payload 布局 → 主版本 +1。
