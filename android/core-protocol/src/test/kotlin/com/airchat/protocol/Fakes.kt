package com.airchat.protocol

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.CopyOnWriteArrayList

/**
 * In-memory [Link] pair used to exercise the full session and node pipelines without hardware.
 *
 * `send` hands the raw chunk straight to the peer's inbound handler, which is exactly what a
 * BLE write/notification looks like from the application's point of view. Setting a small MTU
 * therefore exercises real fragmentation and reassembly code paths.
 */
class FakeLink(
    override val linkId: String,
    override val isCentral: Boolean,
    override var mtu: Int = 185,
    override val peerLabel: String? = null,
) : Link {
    private var handler: ((ByteArray) -> Unit)? = null
    private val earlyBytes = mutableListOf<ByteArray>()

    var peer: FakeLink? = null

    /**
     * Invoked once when this link closes. The harness wires it to the owning transport so a
     * disconnect surfaces as a real `LinkClosed` event, exactly like a BLE disconnect callback.
     */
    var onClosed: (() -> Unit)? = null

    /** When true, [send] reports failure, simulating a saturated or dropped link. */
    var failSend: Boolean = false

    /** Stands in for the transport's single serial queue; see [closeFromPeer]. */
    private val lock = Any()

    /** Every chunk handed to the transport, in order, tagged with the channel it used. */
    val sentChunks = CopyOnWriteArrayList<Pair<Boolean, ByteArray>>()

    var closed: Boolean = false
        private set

    override fun setInboundHandler(handler: (ByteArray) -> Unit) {
        val pending: List<ByteArray>
        synchronized(lock) {
            this.handler = handler
            pending = earlyBytes.toList()
            earlyBytes.clear()
        }
        // Honour the transport contract: bytes that arrived before registration are flushed.
        // Outside the lock, because the flush runs peer code that may send straight back.
        for (bytes in pending) handler(bytes)
    }

    override fun send(bytes: ByteArray, control: Boolean): Boolean {
        val target = synchronized(lock) {
            if (closed || failSend) return false
            sentChunks += control to bytes
            peer
        }
        // Delivered outside the lock: the peer's handler runs protocol code that writes back
        // through this same pair, and holding a lock across it would deadlock.
        target?.deliver(bytes)
        return true
    }

    override fun close() {
        val notify = synchronized(lock) {
            if (closed) return
            closed = true
            onClosed
        }
        notify?.invoke()
        // A BLE disconnect is observed by both ends, so the peer's transport must also report it.
        peer?.closeFromPeer()
    }

    /**
     * Marks this link closed on behalf of the peer that closed.
     *
     * The real transports deliver every callback on one serial queue per link, so a byte that
     * arrives before `setInboundHandler` is either seen by the flush or by the handler itself - it
     * cannot fall between them. The fake had no such serialisation and two nodes run on their own
     * dispatchers, so a HELLO could be appended to `earlyBytes` after the flush had already read
     * them: the link then existed on both sides with no bytes ever crossing it, which is far more
     * confusing to debug than a crash. This lock restores the serial-queue contract.
     */
    private fun closeFromPeer() {
        val notify = synchronized(lock) {
            if (closed) return
            closed = true
            onClosed
        }
        notify?.invoke()
    }

    /**
     * Injects raw bytes as if they had been received from the peer. Used to simulate a hostile
     * or buggy peer (spoofed sender ids, unknown frame types, malformed payloads).
     */
    fun inject(bytes: ByteArray) {
        deliver(bytes)
    }

    private fun deliver(bytes: ByteArray) {
        val target = synchronized(lock) {
            if (closed) return
            val current = handler
            if (current == null) {
                earlyBytes += bytes
                return
            }
            current
        }
        target.invoke(bytes)
    }

    /** Number of frames the local side wrote, derived from the raw chunk stream. */
    fun framesSentToPeer(): List<Frame> {
        val framer = StreamFramer()
        val frames = mutableListOf<Frame>()
        for ((_, chunk) in sentChunks) {
            when (val outcome = framer.push(chunk)) {
                is FramingOutcome.Frames -> frames += outcome.frames
                is FramingOutcome.Fatal -> error("test link produced a fatal framing error")
            }
        }
        return frames
    }
}

/** Test double for [Transport]; links are opened and closed explicitly by the harness. */
class FakeTransport : Transport {
    private val _events = MutableSharedFlow<TransportEvent>(extraBufferCapacity = 128)
    override val events: SharedFlow<TransportEvent> = _events.asSharedFlow()

    override var ticket: Int = 1000

    var started: Boolean = false
        private set

    var lastPresence: Pair<Int, Int>? = null
        private set

    override suspend fun start() {
        started = true
    }

    override suspend fun stop() {
        started = false
    }

    override fun updatePresence(protocolVersion: Int, capabilities: Int) {
        lastPresence = protocolVersion to capabilities
    }

    /** Handles the node asked to connect to, in order, so a tap can be asserted end to end. */
    val connectRequests = mutableListOf<String>()

    override fun connectTo(peerLabel: String) {
        connectRequests += peerLabel
    }

    fun open(link: Link) {
        _events.tryEmit(TransportEvent.LinkOpened(link))
    }

    fun closeLink(linkId: String, reason: String) {
        _events.tryEmit(TransportEvent.LinkClosed(linkId, reason))
    }

    fun reportSeen(label: String, protocolVersion: Int = AirChatProtocol.VERSION, capabilities: Int = Capabilities.ALL, ticket: Int = 2000, rssi: Int? = -60) {
        _events.tryEmit(TransportEvent.PeerSeen(label, protocolVersion, capabilities, ticket, rssi))
    }

    fun reportStatus(status: ChatStatus, message: String) {
        _events.tryEmit(TransportEvent.Status(status, message))
    }
}

/** Creates a cross-wired link pair between two fake transports. */
object FakeBle {
    fun connect(
        a: FakeTransport,
        b: FakeTransport,
        mtu: Int = 185,
        aIsCentral: Boolean = true,
        labelPrefix: String = "link",
        // The platform handle each side sees. Tests that assert nearby-list attribution set these
        // to the label the owning transport reports through `reportSeen`.
        labelA: String = "peer-of-a",
        labelB: String = "peer-of-b",
    ): Pair<FakeLink, FakeLink> {
        val stamp = System.nanoTime()
        val linkA = FakeLink("$labelPrefix-a-$stamp", aIsCentral, mtu, labelA)
        val linkB = FakeLink("$labelPrefix-b-$stamp", !aIsCentral, mtu, labelB)
        linkA.peer = linkB
        linkB.peer = linkA
        linkA.onClosed = { a.closeLink(linkA.linkId, "disconnected") }
        linkB.onClosed = { b.closeLink(linkB.linkId, "disconnected") }
        a.open(linkA)
        b.open(linkB)
        return linkA to linkB
    }
}

/** Minimal in-memory [ChatStore] with the same ordering guarantees as the Room implementation. */
class InMemoryChatStore(
    private var identity: IdentityRecord? = null,
) : ChatStore {
    private val peers = LinkedHashMap<String, PeerRecord>()
    private val messages = LinkedHashMap<String, MessageRecord>()
    private val sessions = LinkedHashMap<String, SessionRecord>()

    /** Ordered log of stored messages, used to assert insertion order. */
    val messageOrder = mutableListOf<String>()

    var insertCalls: Int = 0
        private set

    override suspend fun loadIdentity(): IdentityRecord? = identity

    override suspend fun saveIdentity(record: IdentityRecord) {
        identity = record
    }

    override suspend fun upsertPeer(record: PeerRecord) {
        peers[ByteOps.toHex(record.deviceId)] = record
    }

    override suspend fun getPeer(deviceId: ByteArray): PeerRecord? = peers[ByteOps.toHex(deviceId)]

    override suspend fun listPeers(): List<PeerRecord> = peers.values.toList()

    override suspend fun setTrustState(deviceId: ByteArray, trustState: Int) {
        val key = ByteOps.toHex(deviceId)
        val existing = peers[key] ?: return
        peers[key] = PeerRecord(
            existing.deviceId, existing.nickname, existing.publicKey, trustState,
            existing.lastSeenMs, existing.createdMs,
        )
    }

    override suspend fun insertMessage(record: MessageRecord): Boolean {
        insertCalls++
        val key = ByteOps.toHex(record.msgId)
        if (messages.containsKey(key)) return false
        messages[key] = record
        messageOrder += key
        return true
    }

    override suspend fun getMessage(msgId: ByteArray): MessageRecord? = messages[ByteOps.toHex(msgId)]

    override suspend fun updateMessageStatus(msgId: ByteArray, status: Int): Boolean {
        val key = ByteOps.toHex(msgId)
        val existing = messages[key] ?: return false
        messages[key] = MessageRecord(
            existing.msgId, existing.conversationId, existing.kind, existing.direction,
            existing.senderId, existing.recipientId, existing.text, existing.timestampMs,
            existing.receivedMs, status,
        )
        return true
    }

    override suspend fun listMessages(conversationId: String, limit: Int): List<MessageRecord> =
        messages.values.filter { it.conversationId == conversationId }
            .sortedWith(CHRONOLOGICAL)
            .takeLast(limit)

    override suspend fun historySince(sinceMs: Long, limit: Int): List<MessageRecord> =
        messages.values.filter { it.kind == MessageKind.CHANNEL && it.receivedMs >= sinceMs }
            .sortedWith(CHRONOLOGICAL)
            .take(limit)

    private companion object {
        /**
         * The sort key from `docs/protocol.md`: the sender's timestamp first, then the local
         * receive time, then the message id. A fake that sorted on the receive time alone would
         * look right here because a stable sort preserves a LinkedHashMap's insertion order, while
         * Swift's is not stable and the real stores are SQL - the two fakes and both stores must
         * not disagree about a documented order.
         */
        val CHRONOLOGICAL = compareBy<MessageRecord>(
            { it.timestampMs },
            { it.receivedMs },
            { ByteOps.toHex(it.msgId) },
        )
    }

    override suspend fun saveSession(record: SessionRecord) {
        sessions[ByteOps.toHex(record.peerDeviceId)] = record
    }

    override suspend fun getSession(peerDeviceId: ByteArray): SessionRecord? = sessions[ByteOps.toHex(peerDeviceId)]

    override suspend fun pruneChannel(retainCount: Int, retainDays: Int) = Unit
}
