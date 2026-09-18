# 测试

四层，按"能跑多快、能证明什么"排序。前三层不需要手机，任何机器都能跑；最后一层需要两台真机。

## 1. 协议与状态机（Kotlin / Swift，各自独立）

同一批黄金向量被两个平台分别断言，因此**跨平台字节级一致**是被证明的，而不是被假设的。

| 内容 | 证明什么 |
| --- | --- |
| `testdata/*.json` | 帧编解码、HKDF(RFC 5869)、AEAD(RFC 8439)、ECDH、安全码、MTU 切片契约 |
| `core-protocol` 单测 | 分片/粘包/坏帧、会话状态机、节点编排（去重、信任、点击、扫描窗口） |
| `AirChatProtocolTests` | 同一批向量 + 同名同语义的状态机测试 |

```powershell
# Windows：67 个 Kotlin 测试
pwsh -NoProfile -File tools/run_tests.ps1 -WithBuild
```

```bash
# macOS：61 个 Swift 测试（不需要 Xcode、不需要模拟器）
./tools/run_tests.sh
```

## 2. 设备测试（两台真机，`tools/cross_device_test.py`）

每个**阶段**是一个场景：独立启动、独立断言、独立日志，失败会直接指名是哪个场景。

| 阶段 | 场景 | 断言 |
| --- | --- | --- |
| `link` | 两端各自扫描 | 双向发现、链路就绪、身份互指、角色镜像、**两端安全码一致** |
| `messages` | 脚本消息 | 公频文本互达、1:1 双向解密、双向 `DELIVERY_ACK` |
| `tap` | 各自点第一个附近的人 | 已连接，且**两端都收到核对安全码的请求** |
| `reopen` | 杀掉 Android App 再启动 | 链路回到同一个对端（冷启动恢复） |
| `background` | Android 切后台后收消息 | 后台仍能**收到、解密并回 ACK**（前台服务的作用） |

```bash
python3 tools/cross_device_test.py                       # 全部 5 个阶段
python3 tools/cross_device_test.py --phases link,tap      # 只跑某几个
python3 tools/cross_device_test.py --reset                # 从未核对状态开始（tap 阶段需要）
python3 tools/cross_device_test.py --android-apk <apk> --ios-app <app>   # 先安装
```

要点：

- **基线是心跳**，不是目测。两端每秒输出一行 `AIRCHAT_STATE {...}`，脚本解析它。
- **`tap` 阶段自己清掉"已核对"记录**（调试入口 `airchat_clear_trust`）：安全码核对过就不再重复
  弹窗是正确行为，但清 App 数据会连带丢掉蓝牙权限、让整个套件卡在系统弹窗上，所以两者分开。
- `--reset` 会卸载两端重装（并自动补运行时权限），只在需要"完全干净"时用；注意重装会让 iOS 重新
  弹一次蓝牙权限框，那一次需要人工点掉。
- 每个阶段用自己的日志文件，因此"重启后的状态"不可能被重启前的旧心跳满足。
- 失败时脚本会给出针对性提示（没扫描 / 没权限 / 蓝牙关 / 看到了但握手不成）。

## 3. 构建与静态检查

```powershell
pwsh -NoProfile -File android/build.ps1 :app:assembleDebug :app:lintDebug :app:bundleRelease
```

- 期望**零告警**（Kotlin 编译、lint 都算）。
- `bundleRelease` 产出的 AAB 就是上架用的包（签名见 `docs/store-release.md`）。

## 4. 必须人工做的部分

自动化能覆盖协议、状态机和 Android 侧的后台/恢复，但下面这些只能手动，且**上架前必须过一遍**：

| 项 | 为什么不能自动 |
| --- | --- |
| iOS 锁屏/后台收消息 | iOS 无法从命令行锁屏或切后台，需要在手机上手动锁屏 |
| iOS↔iOS、Android↔Android 互聊 | 需要两台同平台设备（当前只有各一台） |
| 安全码弹窗的观感、跳转 | UI 走查 |
| 上架前的隐私/合规检查 | 见 `docs/store-release.md` |

iOS 锁屏测试步骤：两端前台连上 → iPhone 锁屏 → Android 发一条 1:1 → iOS 解锁后应能看到该消息
（`bluetooth-central` 后台模式生效）。失败时看 iOS 日志里有没有 `inbound`，以区分"没收到"和"收到了但没显示"。
