# 上架：Google Play 与 App Store（免费产品）

> 政策以提交时 Play Console / App Store Connect 的实际提示为准；本文只记**在本仓库里能核实的
> 事实**、以及两家当前公开的硬性要求。账号、税务、收款信息不在本文范围。

## 现状盘点（本节结论都有据可查）

| 项 | 状态 |
| --- | --- |
| Android 包名 / 版本 | `com.airchat.app`（debug 后缀 `.debug`），versionCode 1 / 1.0.0 |
| Android release 签名 | ❌ **没有签名配置**，release 产物是 unsigned，必须先建上传密钥 |
| Android 目标 API | targetSdk 36、compileSdk 37（compileSdk 37 是新版 Compose 强制要求） |
| Android 前台服务 | `connectedDevice` 类型已声明，Play 需要额外填"前台服务权限"声明 |
| iOS Bundle ID / 版本 | `app.airchat.ios`，MARKETING_VERSION 1.0.0 / CURRENT_PROJECT_VERSION 1 |
| iOS 图标 | ❌ **没有 Assets.xcassets / AppIcon** —— 这一项不补，TestFlight 上传会被拒 |
| iOS 后台模式 | `bluetooth-central` + `bluetooth-peripheral` 已声明 |
| iOS 加密出口合规 | ⚠️ Info.plist 未声明 `ITSAppUsesNonExemptEncryption`，每次上传都要人工问答 |
| 隐私政策 URL | ❌ 没有（两家都需要，尤其涉及 BLE 权限与用户聊天内容） |
| 用户举报/屏蔽 | ❌ 没有（这是**两家对聊天类 App 的硬性审核项**，见下） |

## App Store（先上 TestFlight）

1. **会员资格**：Apple Developer Program（个人 99 USD/年）。你已有 Team `VKQ556327V`，只需确认它是
   可发布 App 的类型（个人/公司），并且账号下同意过最新协议。
2. **App Store Connect 建记录**：My Apps → + → New App，Bundle ID 选 `app.airchat.ios`
   （需先在 Certificates, Identifiers & Profiles 里注册这个 ID），主要语言中文。
3. **补图标**：`ios/AirChat/Assets.xcassets/AppIcon.appiconset`，1024×1024 单尺寸即可（Xcode 15+
   单尺寸 AppIcon）。缺图标是上传校验最常见的失败点。
4. **加密出口合规**：本 App 只用系统库（CryptoKit 的 P-256 / HKDF / ChaCha20-Poly1305）实现标准
   算法，属豁免范围。在 Info.plist 里声明：
   ```xml
   <key>ITSAppUsesNonExemptEncryption</key><false/>
   ```
   可免除每次上传的问答；若 Apple 判定不属豁免，则需提交年度自分类报告。
5. **归档上传**：
   ```bash
   cd ios && xcodegen generate
   xcodebuild -project AirChat.xcodeproj -scheme AirChat -configuration Release \
     -destination "generic/platform=iOS" -archivePath /tmp/AirChat.xcarchive \
     -allowProvisioningUpdates DEVELOPMENT_TEAM=VKQ556327V archive
   xcodebuild -exportArchive -archivePath /tmp/AirChat.xcarchive \
     -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates   # method: app-store-connect
   xcrun altool --upload-app -f <ipa> --type ios -u <apple-id> -p <app-specific-password>
   ```
   （或直接在 Xcode 里 Organizer → Distribute App → TestFlight。）
6. **TestFlight**：内部测试（最多 100 人，同账号下）**不需要审核**，几分钟内可分发；外部测试需要
   一次 Beta App Review。先走内部测试最省事。
7. **审核注意（正式上架前）**：
   - **审核员无法配对两台蓝牙设备**。必须在 "App Review Information" 里附一段演示视频（两台手机
     互发消息 + 安全码核对），并说明"无服务器、仅蓝牙、需两台设备"。没有视频，大概率以
     "无法评估"被拒。
   - **用户生成内容（指南 1.2）**：聊天类 App 需要提供举报/屏蔽机制、内容过滤说明、以及可联系的
     支持方式。这是当前最大的功能缺口（见下）。
   - 隐私标签：**不收集数据**（没有服务器），消息仅存本地；但要在隐私政策里写清"消息存于设备"。

## Google Play

1. **账号**：Play Console 开发者账号（一次性 25 USD）。个人账号需要完成身份验证，且**新个人账号
   需要 12 名测试者连续 14 天**（封闭测试）才能申请生产发布 —— 这是时间上的硬成本，越早建越好。
2. **上传密钥**：Play 用 Play App Signing，你只需上传密钥：
   ```powershell
   keytool -genkeypair -v -keystore upload-keystore.jks -alias upload \
     -keyalg RSA -keysize 4096 -validity 10000
   ```
   然后在 `android/app/build.gradle.kts` 里加 `signingConfigs.release`（密钥与密码**不要提交**，
   放 `local.properties` 或环境变量），再 `:app:bundleRelease` 产出 AAB 上传。
3. **target API 要求**：Play 每年 8 月抬高一档（要求 target 到上一年发布的 API）。本项目 targetSdk 36，
   Play Console 会直接显示当前是否达标。
4. **表格与声明**（都要填，且与代码一致）：
   - 数据安全（Data safety）：**不收集、不共享**；消息仅本地保存；`BLUETOOTH_SCAN` 声明为
     `neverForLocation`（manifest 里已这么做）。
   - 内容分级问卷、广告声明（无广告）、目标受众。
   - **前台服务声明**：`FOREGROUND_SERVICE_CONNECTED_DEVICE` 需要说明用途（维持与附近设备的连接）。
   - **用户生成内容政策**：与 Apple 1.2 同理，聊天类需要举报/屏蔽与内容管理措施。
5. **隐私政策 URL**：必需（可放 GitHub Pages，本仓库已有公开仓库，最省事）。

## 提交前必须补的功能缺口

两家商店对"用户能互相发消息"的 App 有共同要求，当前版本都还没有：

1. **举报与屏蔽**：私聊页/长按消息 → 举报该用户或屏蔽（屏蔽后在本地丢弃其消息并阻止 1:1 发送）。
   数据层已有 `peers.trust_state`（含 REJECTED），扩展一个 BLOCKED 即可，改动不大。
2. **隐私政策页**（可用仓库里的 Markdown + GitHub Pages）。
3. **iOS 图标**（1024×1024）与 **Android 512×512 商店图标**（后者只在 Play Console 上传，不进 APK）。
4. **审核演示视频**（iOS 必需，Play 也可用于说明蓝牙用途）。

## 建议顺序

1. 补 iOS AppIcon + `ITSAppUsesNonExemptEncryption` → TestFlight 内部测试跑通（当天可完成）。
2. 补举报/屏蔽 + 隐私政策 → 提交外部 TestFlight 审核与内部 Android 封闭测试。
3. Android 建上传密钥、出 AAB、填 Play 各项声明 → 封闭测试 → 生产发布。
