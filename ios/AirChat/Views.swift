import AirChatProtocol
import SwiftUI

// MARK: - 附近

struct NearbyView: View {

    @ObservedObject var model: ChatViewModel
    let onVerify: (LinkInfo) -> Void

    var body: some View {
        List {
            Section {
                StatusCard(state: model.nodeState)
            }

            Section("我的设备") {
                LabeledContent("昵称", value: model.localNickname)
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备 ID").font(.caption).foregroundStyle(.secondary)
                    Text(model.deviceIdHex.isEmpty ? "初始化中…" : model.deviceIdHex)
                        .font(.system(.caption, design: .monospaced))
                }
            }

            if !model.nodeState.links.isEmpty {
                Section("已连接（\(model.nodeState.links.count)）") {
                    ForEach(model.nodeState.links, id: \.linkId) { link in
                        LinkRow(link: link, onVerify: { onVerify(link) })
                    }
                }
            }

            if !model.nodeState.nearby.isEmpty {
                Section("附近（\(model.nodeState.nearby.count)）") {
                    ForEach(model.nodeState.nearby, id: \.label) { peer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.label).font(.callout)
                            Text(subtitle(for: peer))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.nodeState.links.isEmpty && model.nodeState.nearby.isEmpty {
                Section {
                    Text("还没有发现附近的人。请确认对方也打开了 AirChat，并且两台设备距离在 10–50 米内。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { model.requestChannelSync() }
    }

    private func subtitle(for peer: NearbyPeer) -> String {
        var parts = ["协议 v\(peer.protocolVersion)"]
        if let rssi = peer.rssi { parts.append("\(rssi) dBm") }
        if peer.capabilities & Capabilities.`private` != 0 { parts.append("支持私聊") }
        return parts.joined(separator: " · ")
    }
}

private struct StatusCard: View {
    let state: NodeState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.status == .scanning { ProgressView().controlSize(.small) }
                Text(title).font(.headline)
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch state.status {
        case .scanning: return "正在寻找附近的人…"
        case .nearbyFull: return "附近人数已满（上限 \(AirChatProtocol.maxLinks)）"
        case .permissionMissing: return "需要蓝牙权限"
        case .bluetoothUnavailable: return "蓝牙未开启"
        case .failed: return "蓝牙出错"
        case .stopped: return "已停止"
        }
    }

    private var detail: String {
        state.statusMessage.isEmpty ? "正在广播并扫描 AirChat 服务" : state.statusMessage
    }
}

private struct LinkRow: View {
    let link: LinkInfo
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(link.nickname ?? String((link.peerIdHex ?? "未知设备").prefix(8)))
                    .font(.body.weight(.semibold))
                Spacer()
                TrustBadge(trustState: link.trustState)
            }

            Text(subtitle).font(.caption).foregroundStyle(.secondary)

            if let code = link.safetyCode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.caption)
                    Text(code.chunked(into: 3).joined(separator: " "))
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                }
            }

            Button("核对安全码", action: onVerify)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [link.isCentral ? "我发起的连接" : "对方连接我", "MTU \(link.mtu)"]
        if link.peerConfirmedTheCode { parts.append("对方已确认安全码") }
        return parts.joined(separator: " · ")
    }
}

private struct TrustBadge: View {
    let trustState: Int

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
    }

    private var label: String {
        switch trustState {
        case TrustState.trusted: return "已核对"
        case TrustState.rejected: return "已拒绝"
        default: return "未核对"
        }
    }

    private var color: Color {
        switch trustState {
        case TrustState.trusted: return .accentColor
        case TrustState.rejected: return .red
        default: return .secondary
        }
    }
}

// MARK: - 公共频道

struct ChannelView: View {

    @ObservedObject var model: ChatViewModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("消息会发给附近所有已连接的设备，不加密。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 4)

            MessageList(messages: model.channel, showSender: true, emptyText: "附近还没有人说话。")

            MessageComposer(
                draft: $draft,
                enabled: model.nodeState.readyLinkCount > 0,
                disabledHint: "还没有连接任何人"
            ) {
                model.postToChannel($0)
            }
        }
    }
}

// MARK: - 私聊

struct DirectView: View {

    @ObservedObject var model: ChatViewModel
    let onVerify: (LinkInfo) -> Void

    var body: some View {
        Group {
            if let peer = model.selectedPeerHex {
                ThreadView(model: model, peerIdHex: peer, onVerify: onVerify)
            } else {
                ConversationList(model: model)
            }
        }
    }
}

private struct ConversationList: View {

    @ObservedObject var model: ChatViewModel

    var body: some View {
        Group {
            if model.conversations.isEmpty {
                ContentUnavailableView(
                    "还没有私聊",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("先到「附近」连接一个人。")
                )
            } else {
                List(model.conversations) { conversation in
                    Button {
                        model.select(conversation.peerIdHex)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(conversation.nickname).font(.body.weight(.semibold))
                                Spacer()
                                if conversation.connected {
                                    Text("已连接").font(.caption2).foregroundStyle(.accentColor)
                                }
                            }
                            Text(conversation.lastText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ThreadView: View {

    @ObservedObject var model: ChatViewModel
    let peerIdHex: String
    let onVerify: (LinkInfo) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            TrustBanner(
                trustState: model.selectedTrustState,
                connected: model.selectedConnected,
                onVerify: {
                    if let link = model.nodeState.links.first(where: { $0.peerIdHex == peerIdHex }) {
                        onVerify(link)
                    }
                }
            )

            MessageList(
                messages: model.thread,
                showSender: false,
                emptyText: "还没有消息。1:1 消息使用端到端加密。"
            )

            MessageComposer(
                draft: $draft,
                enabled: model.selectedConnected,
                disabledHint: "对方不在附近，无法发送加密消息"
            ) {
                model.sendPrivate($0)
            }
        }
        .navigationTitle(model.selectedNickname ?? String(peerIdHex.prefix(8)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("返回列表") { model.select(nil) }
            }
        }
    }
}

private struct TrustBanner: View {

    let trustState: Int
    let connected: Bool
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.caption)
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if connected && trustState == TrustState.unverified {
                Button("核对", action: onVerify).font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(background)
    }

    private var message: String {
        if !connected {
            return "对方不在附近。AirChat 没有服务器，消息只在双方都在附近时送达。"
        }
        switch trustState {
        case TrustState.trusted: return "安全码已核对，会话已端到端加密。"
        case TrustState.rejected: return "你标记了安全码不匹配，已阻止发送。"
        default: return "尚未核对安全码。消息已加密，但无法排除中间人。"
        }
    }

    private var background: Color {
        if !connected { return Color.red.opacity(0.12) }
        switch trustState {
        case TrustState.trusted: return Color.accentColor.opacity(0.12)
        case TrustState.rejected: return Color.red.opacity(0.12)
        default: return Color.orange.opacity(0.14)
        }
    }
}

// MARK: - 消息列表与输入

private struct MessageList: View {

    let messages: [MessageRecord]
    let showSender: Bool
    let emptyText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Text(emptyText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 48)
                    }
                    ForEach(messages, id: \.messageIdKey) { message in
                        MessageRow(message: message, showSender: showSender)
                            .id(message.messageIdKey)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.messageIdKey, anchor: .bottom) }
                }
            }
        }
    }
}

private struct MessageRow: View {

    let message: MessageRecord
    let showSender: Bool

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if showSender && !outgoing {
                    Text(String(ByteOps.toHex(message.senderId).prefix(6)))
                        .font(.caption2)
                        .foregroundStyle(.accentColor)
                }
                Text(message.text).font(.body)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: Double(message.receivedMs) / 1000)))
                        .font(.caption2)
                    if outgoing {
                        Text(message.status == MessageStatus.delivered ? "✓✓" : "✓").font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(outgoing ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !outgoing { Spacer(minLength: 40) }
        }
    }

    private var outgoing: Bool { message.direction == MessageDirection.outgoing }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct MessageComposer: View {

    @Binding var draft: String
    let enabled: Bool
    let disabledHint: String
    let onSend: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(enabled ? "说点什么…" : disabledHint, text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(!enabled)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!enabled || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        onSend(body)
        draft = ""
    }
}

// MARK: - 设置

struct SettingsView: View {

    @ObservedObject var model: ChatViewModel
    @State private var nickname = ""
    @State private var showLogs = false

    var body: some View {
        Form {
            Section("昵称") {
                TextField("昵称", text: $nickname)
                    .onSubmit { model.setNickname(nickname) }
                Button("保存昵称") { model.setNickname(nickname) }
            }

            Section("设备 ID") {
                Text(model.deviceIdHex.isEmpty ? "初始化中…" : model.deviceIdHex)
                    .font(.system(.caption, design: .monospaced))
            }

            Section("存储策略") {
                Text("公共频道保留 \(AirChatProtocol.channelRetainCount) 条 / \(AirChatProtocol.channelRetainDays) 天；私聊永久保留。")
                    .font(.footnote)
            }

            Section("iOS 兼容性说明") {
                Text("进入后台后，iOS 不再广播服务 UUID，因此锁屏时无法被其他设备发现，但仍能接收已建立连接的消息。这是系统限制，不是 AirChat 的缺陷。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                Toggle("显示诊断日志", isOn: $showLogs)
                if showLogs {
                    let lines = model.logs().suffix(120)
                    if lines.isEmpty {
                        Text("暂无日志").font(.footnote)
                    } else {
                        ScrollView {
                            Text(lines.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }
        }
        .onAppear { nickname = model.localNickname }
        .onChange(of: model.localNickname) { nickname = model.localNickname }
    }
}

// MARK: - 安全码核对

struct SafetyCodeSheet: View {

    let nickname: String
    let code: String?
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("请与对方当面比对这 6 位数字。一致才代表没有中间人。")
                    .font(.callout)
                    .multilineTextAlignment(.center)

                if let code {
                    Text(code.chunked(into: 3).joined(separator: " "))
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .accessibilityLabel("安全码 \(code)")
                    Text("与 \(nickname) 当面比对").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("对方已断开，无法核对").foregroundStyle(.red)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        onConfirm()
                    } label: {
                        Label("一致，信任对方", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(code == nil)

                    Button(role: .destructive) {
                        onReject()
                    } label: {
                        Label("不一致，拒绝", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("核对安全码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("稍后", action: onDismiss)
                }
            }
        }
    }
}

// MARK: - 工具

private extension MessageRecord {
    /// Message ids are the primary key, so they are also stable SwiftUI identity.
    var messageIdKey: String { ByteOps.toHex(msgId) }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<next]))
            index = next
        }
        return chunks
    }
}
