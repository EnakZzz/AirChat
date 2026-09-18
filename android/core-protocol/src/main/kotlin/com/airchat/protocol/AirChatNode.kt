package com.airchat.protocol

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A peer currently visible in the advertising channel, connected or not. */
data class NearbyPeer(
    val label: String,
    val protocolVersion: Int,
    val capabilities: Int,
    val rssi: Int?,
    val firstSeenMs: Long,
    val lastSeenMs: Long,
    /**
     * deviceId behind [label], once a link (current or past, this session) has revealed it.
     *
     * The label is a platform handle - a BLE address on Android, a CoreBluetooth identifier on
     * iOS - and is all an advertisement can offer. Until a handshake happens there is no way to
     * know who the entry is, which is exactly why the nearby list shows an anonymous short name
     * until [peerIdHex] appears.
     */
    val peerIdHex: String? = null,
)

/** One live link, as shown in the UI. */
data class LinkInfo(
    val linkId: String,
    /** Platform handle of the peer, matching [NearbyPeer.label] while the handshake runs. */
    val peerHandle: String?,
    val peerIdHex: String?,
    val nickname: String?,
    val isCentral: Boolean,
    val mtu: Int,
    val ready: Boolean,
    val safetyCode: String?,
    val trustState: Int,
    val peerConfirmedTheCode: Boolean,
)

data class NodeState(
    val status: ChatStatus,
    val statusMessage: String,
    val deviceIdHex: String,
    val nickname: String,
    val nearby: List<NearbyPeer>,
    val links: List<LinkInfo>,
) {
    val linkCount: Int get() = links.size
    val readyLinkCount: Int get() = links.count { it.ready }

    companion object {
        fun initial(deviceIdHex: String, nickname: String) = NodeState(
            status = ChatStatus.STOPPED,
            statusMessage = "",
            deviceIdHex = deviceIdHex,
            nickname = nickname,
            nearby = emptyList(),
            links = emptyList(),
        )
    }
}

sealed interface NodeEvent {
    data class MessageStored(val record: MessageRecord) : NodeEvent
    data class MessageStatusChanged(val msgIdHex: String, val status: Int) : NodeEvent
    data class TrustChanged(val peerIdHex: String, val trustState: Int) : NodeEvent

    /**
     * The peer the user tapped has completed its handshake and still needs the safety code
     * compared. Emitted at most once per tap: automatic connections do not interrupt anyone.
     */
    data class VerifyRequested(val peerIdHex: String) : NodeEvent
    data class PeerCodeConfirmed(val peerIdHex: String) : NodeEvent
    data class Notice(val message: String) : NodeEvent
    data class Failure(val message: String) : NodeEvent
}

/** Result of a user-initiated connect attempt. */
sealed interface ConnectResult {
    /** The attempt was started; how it ends shows up in `NodeState.links`. */
    object Started : ConnectResult

    data class Rejected(val reason: String) : ConnectResult
}

/** Result of a send attempt, so the UI can report a precise reason. */
sealed interface SendResult {
    class Sent(val record: MessageRecord) : SendResult
    class Rejected(val reason: String) : SendResult
}

/**
 * Manages every link on one device: handshakes, link deduplication, message fan-out and
 * dedupe, trust state, keep-alive and idle detection.
 *
 * All mutation of internal maps happens under [mutex]; the LinkSession callbacks are funnelled
 * here from whatever thread the transport uses. Storage calls are suspend, hence the mutex
 * rather than a plain lock.
 */
class AirChatNode(
    private val store: ChatStore,
    private val transport: Transport,
    private val scope: CoroutineScope,
    private val logger: AirChatLogger = AirChatLogger.NOOP,
    private val clock: () -> Long = System::currentTimeMillis,
    private val capabilities: Int = Capabilities.ALL,
    /** Link ceiling; matches the transport's own limit, and is a seam for the cap tests. */
    private val maxLinks: Int = AirChatProtocol.MAX_LINKS,
    /** How long a tap stays in flight; a seam so the expiry path is testable in milliseconds. */
    private val pendingConnectMs: Long = PENDING_CONNECT_MS,
) {
    private val mutex = Mutex()
    private val sessions = LinkedHashMap<String, LinkSession>()
    private val nearby = LinkedHashMap<String, NearbyPeer>()
    private val peerConfirmedCode = mutableSetOf<String>()

    /**
     * Session-scoped label -> deviceId memory.
     *
     * A handle is all an advertisement, or a link that has not finished its handshake, can offer.
     * Remembering the mapping lets a peer that drops off and comes back be shown by nickname
     * instead of falling back to the anonymous short name.
     */
    private val handleToPeerId = HashMap<String, String>()

    /**
     * The peer the user tapped and is still waiting on.
     *
     * Automatic connections must not interrupt anyone with a safety-code dialog, so the prompt is
     * only offered for a tap, and only while the tap is fresh.
     */
    private var pendingConnect: PendingConnect? = null

    private data class PendingConnect(val handle: String, val deadlineMs: Long)

    private val _state = MutableStateFlow(NodeState.initial("", ""))
    val state: StateFlow<NodeState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<NodeEvent>(extraBufferCapacity = 256)
    val events: SharedFlow<NodeEvent> = _events.asSharedFlow()

    private var identity: LocalIdentity? = null
    private var nicknameInternal: String = DEFAULT_NICKNAME
    private var collectorJob: Job? = null
    private var maintenanceJob: Job? = null

    val deviceIdHex: String get() = identity?.deviceIdHex ?: ""

    val localNickname: String get() = nicknameInternal

    // ---------------------------------------------------------------- lifecycle

    /**
     * Loads or creates the persisted identity, then brings the transport up. Safe to call once
     * per process; calling it again is a no-op while the node is running.
     */
    suspend fun start() = mutex.withLock {
        if (collectorJob != null) return@withLock

        val stored = store.loadIdentity()
        val loaded = if (stored == null) {
            val created = LocalIdentity.generate()
            store.saveIdentity(created.toRecord(DEFAULT_NICKNAME))
            created to DEFAULT_NICKNAME
        } else {
            LocalIdentity.fromRecord(stored) to stored.nickname.ifBlank { DEFAULT_NICKNAME }
        }
        identity = loaded.first
        nicknameInternal = loaded.second
        logger.log(TAG, "identity ${loaded.first.deviceIdHex} (${nicknameInternal})")

        store.pruneChannel(AirChatProtocol.CHANNEL_RETAIN_COUNT, AirChatProtocol.CHANNEL_RETAIN_DAYS)
        publishState()

        transport.updatePresence(AirChatProtocol.VERSION, capabilities)
        collectorJob = scope.launch { transport.events.collect { handleTransportEvent(it) } }
        maintenanceJob = scope.launch { maintenanceLoop() }
        transport.start()
    }

    suspend fun stop() {
        collectorJob?.cancel()
        maintenanceJob?.cancel()
        collectorJob = null
        maintenanceJob = null
        runCatching { transport.stop() }
        mutex.withLock {
            for (session in sessions.values) {
                session.link.close()
                session.markClosed()
            }
            sessions.clear()
            nearby.clear()
            handleToPeerId.clear()
            pendingConnect = null
            publishState()
        }
    }

    suspend fun setNickname(nickname: String) {
        val trimmed = nickname.trim()
        if (trimmed.isEmpty()) return
        val bytes = trimmed.toByteArray(Charsets.UTF_8)
        if (bytes.size > AirChatProtocol.MAX_NICKNAME_BYTES) return
        mutex.withLock {
            val current = identity ?: return@withLock
            nicknameInternal = trimmed
            store.saveIdentity(current.toRecord(trimmed))
            publishState()
        }
    }

    // ---------------------------------------------------------------- connect

    /**
     * Connects to the peer the user tapped in the nearby list, and remembers the tap so the
     * safety-code dialog can be offered automatically once that peer's handshake completes.
     *
     * The cap is checked here as well as in the transport so the user gets a reason instead of a
     * tap that appears to do nothing.
     */
    suspend fun requestConnect(peerHandle: String): ConnectResult = mutex.withLock {
        if (identity == null) return@withLock ConnectResult.Rejected("身份尚未就绪")
        if (sessions.size >= maxLinks) {
            return@withLock ConnectResult.Rejected("附近人数已满（上限 $maxLinks），先断开一个")
        }
        // A tap on a peer that is already connected (or connecting) is not a new connection: it is
        // the user asking for that peer's safety code, which may already be available.
        val alreadyLinked = sessions.values.any {
            !it.isTerminal && it.link.peerLabel == peerHandle
        }
        if (!alreadyLinked) {
            transport.connectTo(peerHandle)
            logger.log(TAG, "user requested connect to $peerHandle")
        }
        pendingConnect = PendingConnect(peerHandle, clock() + pendingConnectMs)
        evaluateVerifyPrompt()
        ConnectResult.Started
    }

    /**
     * Offers the safety-code dialog for the tapped peer, once.
     *
     * A peer whose code is already trusted is not prompted again, and a tap that never turns into
     * a link expires instead of resurfacing later against whoever happens to connect next.
     */
    private suspend fun evaluateVerifyPrompt() {
        val pending = pendingConnect ?: return
        if (clock() > pending.deadlineMs) {
            pendingConnect = null
            return
        }
        val session = sessions.values.firstOrNull {
            it.isReady && it.link.peerLabel == pending.handle
        } ?: return
        val deviceId = session.peer?.deviceId ?: return
        pendingConnect = null
        if (store.getPeer(deviceId)?.trustState == TrustState.TRUSTED) return
        emit(NodeEvent.VerifyRequested(ByteOps.toHex(deviceId)))
    }

    /** deviceId this handle is known by: a live link first, the session memory second. */
    private fun peerIdForHandle(handle: String): String? =
        sessions.values.firstOrNull { it.link.peerLabel == handle }?.peerDeviceIdHex
            ?: handleToPeerId[handle]

    // ---------------------------------------------------------------- outbound

    /** Sends a public channel message to every ready link. */
    suspend fun postChannelMessage(text: String): SendResult = mutex.withLock {
        val body = text.trim()
        val rejection = validateOutgoingText(body)
        if (rejection != null) return@withLock SendResult.Rejected(rejection)
        val me = identity ?: return@withLock SendResult.Rejected("identity not ready")

        val now = clock()
        val record = MessageRecord(
            msgId = AirChatCrypto.randomMessageId(),
            conversationId = AirChatProtocol.CHANNEL_CONVERSATION_ID,
            kind = MessageKind.CHANNEL,
            direction = MessageDirection.OUTGOING,
            senderId = me.deviceId,
            recipientId = null,
            text = body,
            timestampMs = now,
            receivedMs = now,
            status = MessageStatus.LOCAL,
        )
        // Store first so a crash mid-send cannot lose the message.
        store.insertMessage(record)
        emit(NodeEvent.MessageStored(record))

        val post = ChannelPost(record.msgId, now, me.deviceId, nicknameInternal, body)
        var delivered = 0
        for (session in readySessions()) {
            if (session.sendChannelPost(post)) delivered++
        }
        val status = if (delivered > 0) MessageStatus.SENT else MessageStatus.FAILED
        store.updateMessageStatus(record.msgId, status)
        val updated = record.copyWithStatus(status)
        if (status != MessageStatus.LOCAL) emit(NodeEvent.MessageStatusChanged(ByteOps.toHex(record.msgId), status))
        publishState()
        SendResult.Sent(updated)
    }

    /** Sends an encrypted 1:1 message to a specific peer. */
    suspend fun sendPrivateMessage(peerIdHex: String, text: String): SendResult = mutex.withLock {
        val body = text.trim()
        val rejection = validateOutgoingText(body)
        if (rejection != null) return@withLock SendResult.Rejected(rejection)
        val me = identity ?: return@withLock SendResult.Rejected("identity not ready")

        val peerId = runCatching { ByteOps.fromHex(peerIdHex) }.getOrNull()
            ?: return@withLock SendResult.Rejected("bad peer id")
        if (peerId.contentEquals(me.deviceId)) {
            return@withLock SendResult.Rejected("cannot message this device")
        }

        val peerRecord = store.getPeer(peerId)
        if (peerRecord?.trustState == TrustState.REJECTED) {
            return@withLock SendResult.Rejected("安全码已被标记为不匹配，已阻止发送")
        }

        val session = readySessions().firstOrNull { it.peerDeviceIdHex == peerIdHex }
            ?: return@withLock SendResult.Rejected("对方不在附近")

        val now = clock()
        val message = session.sendPrivateMessage(
            msgId = AirChatCrypto.randomMessageId(),
            timestampMillis = now,
            recipientId = peerId,
            plaintext = body,
        ) ?: return@withLock SendResult.Rejected("会话未就绪")

        val record = MessageRecord(
            msgId = message.msgId,
            conversationId = peerIdHex,
            kind = MessageKind.PRIVATE,
            direction = MessageDirection.OUTGOING,
            senderId = me.deviceId,
            recipientId = peerId,
            text = body,
            timestampMs = now,
            receivedMs = now,
            status = MessageStatus.SENT,
        )
        store.insertMessage(record)
        emit(NodeEvent.MessageStored(record))
        publishState()
        SendResult.Sent(record)
    }

    /** Records the user's verdict on the safety code and tells the peer. */
    suspend fun confirmSafetyCode(peerIdHex: String, accepted: Boolean) = mutex.withLock {
        val peerId = runCatching { ByteOps.fromHex(peerIdHex) }.getOrNull() ?: return@withLock
        val trustState = if (accepted) TrustState.TRUSTED else TrustState.REJECTED
        store.setTrustState(peerId, trustState)
        for (session in sessions.values) {
            if (session.peerDeviceIdHex == peerIdHex) {
                session.verifiedLocally = accepted
                session.sendKeyVerifyRequest()
            }
        }
        emit(NodeEvent.TrustChanged(peerIdHex, trustState))
        publishState()
    }

    suspend fun sendTyping(peerIdHex: String?, active: Boolean) = mutex.withLock {
        if (peerIdHex == null) {
            for (session in readySessions()) {
                session.sendTyping(TypingScope.CHANNEL, active, EMPTY_DEVICE_ID)
            }
        } else {
            sessions.values
                .firstOrNull { it.peerDeviceIdHex == peerIdHex && it.isReady }
                ?.sendTyping(
                    TypingScope.PRIVATE,
                    active,
                    runCatching { ByteOps.fromHex(peerIdHex) }.getOrDefault(EMPTY_DEVICE_ID),
                )
        }
    }

    /** Requests channel history from every ready peer that supports it. */
    suspend fun requestChannelSync() = mutex.withLock {
        for (session in readySessions()) {
            val peer = session.peer ?: continue
            if (peer.supportsSync) session.sendSyncRequest()
        }
    }

    // ---------------------------------------------------------------- inbound

    private fun handleTransportEvent(event: TransportEvent) {
        when (event) {
            is TransportEvent.LinkOpened -> {
                val session = LinkSession(
                    link = event.link,
                    localIdentity = identity ?: return,
                    nicknameProvider = { nicknameInternal },
                    capabilities = capabilities,
                    listener = sessionListener,
                    clock = clock,
                    logger = logger,
                )
                // Register the consumer before starting the handshake: the peer may already be
                // writing HELLO, and the transport must not drop those bytes.
                event.link.setInboundHandler { bytes -> session.onBytes(bytes) }
                sessions[event.link.linkId] = session
                logger.log(TAG, "link opened ${event.link.linkId} (central=${event.link.isCentral})")
                session.start()
                publishStateSoon()
            }

            is TransportEvent.LinkClosed -> {
                sessions.remove(event.linkId)?.markClosed()
                publishStateSoon()
            }

            is TransportEvent.PeerSeen -> {
                val now = clock()
                val existing = nearby[event.peerLabel]
                nearby[event.peerLabel] = NearbyPeer(
                    label = event.peerLabel,
                    protocolVersion = event.protocolVersion,
                    capabilities = event.capabilities,
                    rssi = event.rssi,
                    firstSeenMs = existing?.firstSeenMs ?: now,
                    lastSeenMs = now,
                    peerIdHex = peerIdForHandle(event.peerLabel) ?: existing?.peerIdHex,
                )
                publishStateSoon()
            }

            is TransportEvent.PeerLost -> {
                nearby.remove(event.peerLabel)
                publishStateSoon()
            }

            is TransportEvent.Status -> {
                _state.value = _state.value.copy(
                    status = event.status,
                    statusMessage = event.message,
                )
            }
        }
    }

    private val sessionListener = object : LinkSessionListener {
        override fun onReady(session: LinkSession, peer: Hello) {
            scope.launch { onSessionReady(session, peer) }
        }

        override fun onChannelPost(session: LinkSession, post: ChannelPost) {
            scope.launch { onChannelPostReceived(session, post) }
        }

        override fun onPrivateMessage(session: LinkSession, received: ReceivedPrivateMessage) {
            scope.launch { onPrivateMessageReceived(session, received) }
        }

        override fun onDeliveryAck(session: LinkSession, ack: DeliveryAck) {
            scope.launch { onDeliveryAckReceived(ack) }
        }

        override fun onTyping(session: LinkSession, typing: Typing) {
            // Typing indicators are ephemeral and not persisted.
            emit(NodeEvent.Notice("typing:${session.peerDeviceIdHex}:${typing.scope.code}:${typing.active}"))
        }

        override fun onSyncRequest(session: LinkSession, request: SyncRequest) {
            scope.launch { onSyncRequestReceived(session, request) }
        }

        override fun onSyncResponse(session: LinkSession, response: SyncResponse) {
            scope.launch { onSyncResponseReceived(session, response) }
        }

        override fun onKeyVerifyRequest(session: LinkSession) {
            scope.launch {
                val peerId = session.peerDeviceIdHex ?: return@launch
                mutex.withLock { peerConfirmedCode.add(peerId) }
                emit(NodeEvent.PeerCodeConfirmed(peerId))
                publishStateSoon()
            }
        }

        override fun onKeyVerifyResponse(session: LinkSession, accepted: Boolean) {
            scope.launch {
                val peerId = session.peerDeviceIdHex ?: return@launch
                if (accepted) {
                    mutex.withLock { peerConfirmedCode.add(peerId) }
                    emit(NodeEvent.PeerCodeConfirmed(peerId))
                }
                publishStateSoon()
            }
        }

        override fun onFailed(session: LinkSession, reason: String) {
            scope.launch {
                emit(NodeEvent.Failure("链路 ${session.link.linkId} 握手失败：$reason"))
                session.link.close()
                mutex.withLock { sessions.remove(session.link.linkId)?.markClosed() }
                publishStateSoon()
            }
        }
    }

    private suspend fun onSessionReady(session: LinkSession, peer: Hello) {
        mutex.withLock {
            rememberPeer(peer)

            // Protocol 5.4: keep the link whose central deviceId is smaller, drop the other.
            val peerHex = ByteOps.toHex(peer.deviceId)
            session.link.peerLabel?.let { handleToPeerId[it] = peerHex }
            val duplicates = sessions.values.filter {
                it !== session && !it.isTerminal && it.peerDeviceIdHex == peerHex
            }
            for (other in duplicates) {
                val keep = chooseLinkToKeep(session, other)
                val drop = if (keep === session) other else session
                logger.log(TAG, "duplicate link with $peerHex; dropping ${drop.link.linkId}")
                // Both links of a duplicate pair are the same person (dedupe is keyed by peer
                // deviceId), so the tap follows whichever one survives.
                drop.link.peerLabel?.let { handleToPeerId[it] = peerHex }
                val pendingNow = pendingConnect
                if (pendingNow != null && pendingNow.handle == drop.link.peerLabel) {
                    pendingConnect = pendingNow.copy(handle = keep.link.peerLabel ?: pendingNow.handle)
                }
                drop.link.close()
                drop.markClosed()
                sessions.remove(drop.link.linkId)
                emit(NodeEvent.Notice("检测到重复连接，已保留一条链路"))
            }
            if (session.state == SessionState.CLOSED) {
                // This link lost the dedupe. The survivor already ran this method, so only the
                // prompt is still owed - deliver it against whoever is left.
                evaluateVerifyPrompt()
                publishState()
                return@withLock
            }

            val now = clock()
            session.sessionKey?.let { key ->
                store.saveSession(
                    SessionRecord(
                        peerDeviceId = peer.deviceId,
                        sessionKey = key,
                        peerPublicKey = peer.publicKey,
                        verified = store.getPeer(peer.deviceId)?.trustState == TrustState.TRUSTED,
                        createdMs = now,
                        lastUsedMs = now,
                    ),
                )
            }
            session.verifiedLocally = store.getPeer(peer.deviceId)?.trustState == TrustState.TRUSTED

            if (peer.supportsSync) session.sendSyncRequest()
            // The handshake that answers the user's tap is the ordinary case: without this the
            // prompt would only ever appear when a duplicate link happened to lose the dedupe.
            evaluateVerifyPrompt()
            publishState()
        }
    }

    private suspend fun onChannelPostReceived(session: LinkSession, post: ChannelPost) {
        val record = MessageRecord(
            msgId = post.msgId,
            conversationId = AirChatProtocol.CHANNEL_CONVERSATION_ID,
            kind = MessageKind.CHANNEL,
            direction = MessageDirection.INCOMING,
            senderId = post.senderId,
            recipientId = null,
            text = post.text,
            timestampMs = post.timestampMillis,
            receivedMs = clock(),
            status = MessageStatus.DELIVERED,
        )
        val stored = mutex.withLock {
            upsertPeerFromPost(post, session)
            store.insertMessage(record)
        }
        if (stored) {
            emit(NodeEvent.MessageStored(record))
            publishStateSoon()
        }
    }

    private suspend fun onPrivateMessageReceived(session: LinkSession, received: ReceivedPrivateMessage) {
        val message = received.message
        val plaintext = received.plaintext
        val record = if (plaintext == null) {
            null
        } else {
            MessageRecord(
                msgId = message.msgId,
                conversationId = ByteOps.toHex(message.senderId),
                kind = MessageKind.PRIVATE,
                direction = MessageDirection.INCOMING,
                senderId = message.senderId,
                recipientId = message.recipientId,
                text = plaintext,
                timestampMs = message.timestampMillis,
                receivedMs = clock(),
                status = MessageStatus.DELIVERED,
            )
        }
        val stored = mutex.withLock {
            if (record == null) return@withLock false
            rememberPeerFromPrivateMessage(message)
            store.insertMessage(record)
        }
        // Always acknowledge, even for duplicates or failures: that is what stops peer retries.
        session.sendDeliveryAck(
            message.msgId,
            if (plaintext == null) AckStatus.UNDECRYPTABLE else AckStatus.DELIVERED,
        )
        if (stored && record != null) {
            emit(NodeEvent.MessageStored(record))
            publishStateSoon()
        }
    }

    private suspend fun onDeliveryAckReceived(ack: DeliveryAck) {
        val status = when (ack.status) {
            AckStatus.DELIVERED -> MessageStatus.DELIVERED
            AckStatus.UNDECRYPTABLE -> MessageStatus.FAILED
        }
        // A single conditional update doubles as the existence check: an ACK for an unknown
        // msgId (e.g. one we never sent) must be ignored without touching the store again.
        val updated = mutex.withLock { store.updateMessageStatus(ack.msgId, status) }
        if (!updated) return
        emit(NodeEvent.MessageStatusChanged(ByteOps.toHex(ack.msgId), status))
        publishStateSoon()
    }

    private suspend fun onSyncRequestReceived(session: LinkSession, request: SyncRequest) {
        val since = clock() - request.sinceMinutesAgo.coerceIn(0, 24 * 60) * 60_000L
        val limit = request.maxCount.coerceIn(1, AirChatProtocol.SYNC_MAX_COUNT)
        val history = mutex.withLock { store.historySince(since, limit) }
        val posts = history.mapNotNull { record ->
            // Only the local device's own posts are ours to forward; peers forward their own.
            if (record.kind != MessageKind.CHANNEL) null
            else ChannelPost(
                record.msgId,
                record.timestampMs,
                record.senderId,
                store.getPeer(record.senderId)?.nickname ?: "",
                record.text,
            )
        }
        session.sendSyncResponse(posts)
    }

    private suspend fun onSyncResponseReceived(session: LinkSession, response: SyncResponse) {
        var added = 0
        mutex.withLock {
            for (post in response.posts) {
                upsertPeerFromPost(post, session)
                val inserted = store.insertMessage(
                    MessageRecord(
                        msgId = post.msgId,
                        conversationId = AirChatProtocol.CHANNEL_CONVERSATION_ID,
                        kind = MessageKind.CHANNEL,
                        direction = MessageDirection.INCOMING,
                        senderId = post.senderId,
                        recipientId = null,
                        text = post.text,
                        timestampMs = post.timestampMillis,
                        receivedMs = clock(),
                        status = MessageStatus.DELIVERED,
                    ),
                )
                if (inserted) added++
            }
        }
        if (added > 0) emit(NodeEvent.Notice("已同步 $added 条历史消息"))
        publishStateSoon()
    }

    // ---------------------------------------------------------------- helpers

    private suspend fun rememberPeer(hello: Hello) {
        val now = clock()
        val existing = store.getPeer(hello.deviceId)
        val keyChanged = existing != null && !existing.publicKey.contentEquals(hello.publicKey)
        if (keyChanged) {
            emit(NodeEvent.Notice("${hello.nickname} 的公钥已变化，请重新核对安全码"))
        }
        store.upsertPeer(
            PeerRecord(
                deviceId = hello.deviceId,
                nickname = hello.nickname,
                publicKey = hello.publicKey,
                // Protocol 10.3 rule 5: a changed public key must fall back to UNVERIFIED.
                trustState = if (existing == null || keyChanged) TrustState.UNVERIFIED else existing.trustState,
                lastSeenMs = now,
                createdMs = existing?.createdMs ?: now,
            ),
        )
    }

    /** Channel posts carry a nickname snapshot but no public key; keep any known key. */
    private suspend fun upsertPeerFromPost(post: ChannelPost, session: LinkSession) {
        val now = clock()
        val existing = store.getPeer(post.senderId)
        val knownKey = existing?.publicKey ?: session.peer?.publicKey
        if (knownKey == null) return
        store.upsertPeer(
            PeerRecord(
                deviceId = post.senderId,
                nickname = post.senderNickname.ifBlank { existing?.nickname ?: "" },
                publicKey = knownKey,
                trustState = existing?.trustState ?: TrustState.UNVERIFIED,
                lastSeenMs = now,
                createdMs = existing?.createdMs ?: now,
            ),
        )
    }

    private suspend fun rememberPeerFromPrivateMessage(message: PrivateMessage) {
        val now = clock()
        val existing = store.getPeer(message.senderId) ?: return
        store.upsertPeer(
            PeerRecord(
                deviceId = existing.deviceId,
                nickname = existing.nickname,
                publicKey = existing.publicKey,
                trustState = existing.trustState,
                lastSeenMs = now,
                createdMs = existing.createdMs,
            ),
        )
    }

    /**
     * Protocol 5.4: prefer the link whose central has the smaller deviceId. Both peers evaluate
     * the same predicate over the same two deviceIds, so both converge on the same survivor.
     */
    private fun chooseLinkToKeep(a: LinkSession, b: LinkSession): LinkSession {
        val centralA = centralDeviceId(a) ?: return a
        val centralB = centralDeviceId(b) ?: return b
        val comparison = ByteOps.compareUnsigned(centralA, centralB)
        return if (comparison <= 0) a else b
    }

    private fun centralDeviceId(session: LinkSession): ByteArray? = when {
        session.link.isCentral -> identity?.deviceId
        else -> session.peer?.deviceId
    }

    private fun readySessions(): List<LinkSession> = sessions.values.filter { it.isReady }

    private fun validateOutgoingText(text: String): String? = when {
        text.isEmpty() -> "消息不能为空"
        text.length > AirChatProtocol.MAX_TEXT_CHARS -> "消息超过 ${AirChatProtocol.MAX_TEXT_CHARS} 字"
        text.toByteArray(Charsets.UTF_8).size > AirChatProtocol.MAX_TEXT_BYTES ->
            "消息超过 ${AirChatProtocol.MAX_TEXT_BYTES} 字节"
        else -> null
    }

    private fun emit(event: NodeEvent) {
        if (!_events.tryEmit(event)) logger.log(TAG, "dropped node event: $event")
    }

    private fun publishStateSoon() {
        scope.launch { mutex.withLock { publishState() } }
    }

    private suspend fun publishState() {
        val me = identity
        val now = clock()
        _state.value = _state.value.copy(
            deviceIdHex = me?.deviceIdHex ?: "",
            nickname = nicknameInternal,
            nearby = nearby.values
                .map { peer ->
                    val known = peerIdForHandle(peer.label)
                    if (peer.peerIdHex == known) peer else peer.copy(peerIdHex = known)
                }
                .sortedByDescending { it.lastSeenMs },
            links = sessions.values.map { session ->
                val peerHex = session.peerDeviceIdHex
                LinkInfo(
                    linkId = session.link.linkId,
                    peerHandle = session.link.peerLabel,
                    peerIdHex = peerHex,
                    nickname = session.peer?.nickname,
                    isCentral = session.link.isCentral,
                    mtu = session.link.mtu,
                    ready = session.isReady,
                    safetyCode = session.safetyCode,
                    trustState = peerHex?.let { store.getPeer(session.peer!!.deviceId)?.trustState }
                        ?: TrustState.UNVERIFIED,
                    peerConfirmedTheCode = peerHex != null && peerConfirmedCode.contains(peerHex),
                )
            },
        )
        // Nearby entries that stopped advertising are pruned on the maintenance tick.
        if (nearby.values.any { now - it.lastSeenMs > NEARBY_TTL_MS }) {
            nearby.entries.removeAll { now - it.value.lastSeenMs > NEARBY_TTL_MS }
        }
    }

    private suspend fun maintenanceLoop() {
        while (scope.isActive) {
            delay(MAINTENANCE_INTERVAL_MS)
            mutex.withLock {
                val now = clock()
                val dead = sessions.values.filter {
                    it.isReady && now - it.lastInboundAtMs > AirChatProtocol.LINK_IDLE_TIMEOUT_MS
                }
                for (session in dead) {
                    logger.log(TAG, "idle timeout on ${session.link.linkId}")
                    session.link.close()
                    session.markClosed()
                    sessions.remove(session.link.linkId)
                }
                for (session in sessions.values) {
                    if (!session.isReady) continue
                    if (now - session.lastOutboundAtMs >= AirChatProtocol.PING_INTERVAL_MS) session.ping()
                }
                val pending = pendingConnect
                if (pending != null && now > pending.deadlineMs) {
                    pendingConnect = null
                    val linked = sessions.values.any {
                        it.isReady && it.link.peerLabel == pending.handle
                    }
                    if (!linked) emit(NodeEvent.Notice("没能连上，请靠近后重试"))
                }
                publishState()
            }
        }
    }

    private companion object {
        const val TAG = "AirChatNode"
        const val DEFAULT_NICKNAME = "邻居"
        const val MAINTENANCE_INTERVAL_MS = 5_000L
        const val NEARBY_TTL_MS = 15_000L

        /** How long a tap stays "in flight" before it is reported as not connecting. */
        const val PENDING_CONNECT_MS = 20_000L
        val EMPTY_DEVICE_ID = ByteArray(AirChatProtocol.DEVICE_ID_BYTES)
    }
}

/** Copy helper used when a stored record's status changes. */
private fun MessageRecord.copyWithStatus(status: Int) = MessageRecord(
    msgId, conversationId, kind, direction, senderId, recipientId, text, timestampMs, receivedMs, status,
)
