import AirChatProtocol
import SwiftUI

// MARK: - 附近

/// The nearby list: one row per person, whatever state their link is in.
///
/// Discovery and connection are automatic (the public channel depends on reaching everyone
/// nearby), so this screen is not a "pairing wizard": it shows what the radio is already doing and
/// turns a tap into the one step that needs a human - comparing the safety code, or opening the
/// conversation with someone whose code was already compared. A tap on a person who is merely
/// visible asks the transport to connect now rather than waiting for the next scan round.
struct NearbyView: View {

    @ObservedObject var model: ChatViewModel
    let onRowClick: (NearbyRow) -> Void

    var body: some View {
        List {
            Section {
                StatusCard(state: model.nodeState)
            }

            if model.nearby.isEmpty {
                Section {
                    Text("还没有发现附近的人。请确认对方也打开了 AirChat，并且两台设备距离在 10–50 米内。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("附近（\(model.nearby.count)）") {
                    ForEach(model.nearby) { row in
                        Button {
                            onRowClick(row)
                        } label: {
                            NearbyRowView(row: row)
                                // Same dead zone as the conversation list: the Spacer between the
                                // name and the state label carries no content, so the row needs a
                                // hit-testable shape of its own.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .refreshable { model.requestChannelSync() }
    }
}

private struct NearbyRowView: View {

    let row: NearbyRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if row.state == .connecting {
                ProgressView().controlSize(.small)
            } else {
                Text(row.state.label)
                    .font(.caption2)
                    .foregroundStyle(color)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch row.state {
        case .trusted, .unverified, .rejected: return "lock.fill"
        case .connecting, .nearby: return "dot.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch row.state {
        case .unverified: return .orange
        case .rejected: return .red
        case .trusted: return .accentColor
        case .connecting, .nearby: return .secondary
        }
    }

    /// The one-line explanation under a person's name: what the radio is doing, and how well.
    private var subtitle: String {
        let signal = row.rssi.map { "信号 \(signalLabel($0))" }
        switch row.state {
        case .nearby:
            return signal ?? "点按连接"
        case .connecting:
            return "正在建立加密链路…"
        case .unverified:
            return ["已连接，点按核对安全码", signal].compactMap { $0 }.joined(separator: " · ")
        case .trusted:
            return "已连接，点按进入对话"
        case .rejected:
            return "安全码已标记为不匹配，点按可重新核对"
        }
    }

    private func signalLabel(_ rssi: Int) -> String {
        if rssi >= -60 { return "强" }
        if rssi >= -80 { return "中" }
        return "弱"
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
    let onVerify: (String) -> Void

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
                                    Text("已连接").font(.caption2).foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(conversation.lastText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // A plain button only responds where its label has content, and the Spacer
                        // between the name and the badge has none: the middle of the row was dead
                        // while both ends worked. A hit-testable shape over the full width fixes it.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    // The row is a tap target, not a replica of a link: redraw it as such rather than
                    // making the text look tappable.
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct ThreadView: View {

    @ObservedObject var model: ChatViewModel
    let peerIdHex: String
    let onVerify: (String) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            TrustBanner(
                trustState: model.selectedTrustState,
                connected: model.selectedConnected,
                onVerify: { onVerify(peerIdHex) }
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
                        .foregroundStyle(Color.accentColor)
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

            if !model.nodeState.links.isEmpty {
                Section("连接详情") {
                    ForEach(model.nodeState.links, id: \.linkId) { link in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.nickname ?? link.peerHandle ?? link.linkId)
                                .font(.callout)
                                .lineLimit(1)
                            Text(linkDetail(link))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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

    private func linkDetail(_ link: LinkInfo) -> String {
        var parts = [link.isCentral ? "我发起" : "对方发起", "MTU \(link.mtu)"]
        switch link.trustState {
        case TrustState.trusted: parts.append("安全码已核对")
        case TrustState.rejected: parts.append("已拒绝")
        default: parts.append("未核对")
        }
        if link.peerConfirmedTheCode { parts.append("对方已确认") }
        if !link.ready { parts.append("握手中") }
        return parts.joined(separator: " · ")
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
