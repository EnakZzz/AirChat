package com.airchat.app.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.airchat.app.AirChatContainer
import com.airchat.protocol.AirChatProtocol
import com.airchat.protocol.ByteOps
import com.airchat.protocol.ConnectResult
import com.airchat.protocol.MessageDirection
import com.airchat.protocol.MessageRecord
import com.airchat.protocol.MessageStatus
import com.airchat.protocol.NodeEvent
import com.airchat.protocol.PeerRecord
import com.airchat.protocol.NodeState
import com.airchat.protocol.SendResult
import com.airchat.protocol.TrustState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** One row in the direct-message list. */
data class Conversation(
    val peerIdHex: String,
    val nickname: String,
    val lastText: String,
    val lastAtMs: Long,
    val connected: Boolean,
    val trustState: Int,
)

/**
 * One row of the nearby list: one person, whatever state their link is in.
 *
 * Keyed by deviceId once a handshake has revealed it, and by the platform handle before that, so
 * the same person cannot appear twice - once as an advertisement and once as a link - which is
 * what the old two-section layout did.
 */
data class NearbyRow(
    /** Stable identity for the row: the deviceId when known, otherwise `h:<handle>`. */
    val key: String,
    /** Platform handle, which is what a connect request has to name. */
    val label: String,
    /** Nickname once known, otherwise an anonymous short name. */
    val title: String,
    val state: NearbyState,
    val rssi: Int?,
    val peerIdHex: String?,
)

/** The peer whose safety code the user is being asked to compare. */
data class VerifyRequest(
    val peerIdHex: String,
    val nickname: String,
    val code: String?,
)

/** Everything the UI renders. */
data class ChatUiState(
    val node: NodeState,
    val channel: List<MessageRecord>,
    val conversations: List<Conversation>,
    val thread: List<MessageRecord>,
    val selectedPeerHex: String?,
    val selectedNickname: String?,
    val selectedTrustState: Int,
    val selectedSafetyCode: String?,
    val selectedConnected: Boolean,
    /** The nearby list, already merged into one row per person. */
    val nearby: List<NearbyRow>,
    /** Non-null while the safety-code dialog should be on screen. */
    val verifyRequest: VerifyRequest?,
)

/**
 * Single source of truth for the Compose UI.
 *
 * The node owns all protocol state; this view model only projects persisted messages plus the
 * node's `StateFlow` into renderable shapes, and forwards user intents.
 */
class ChatViewModel(private val container: AirChatContainer) : ViewModel() {

    private val _uiState = MutableStateFlow(emptyState())
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()

    private var selectedPeerHex: String? = null

    init {
        viewModelScope.launch {
            container.node.events.collect { event ->
                // The node only ever asks for a comparison for the peer the user tapped, and only
                // once, so this needs no extra bookkeeping here.
                if (event is NodeEvent.VerifyRequested) requestVerification(event.peerIdHex)
                reload()
            }
        }
        viewModelScope.launch {
            container.node.state.collect { reload() }
        }
        // Initial load runs in its own coroutine: reload() is suspend because it reads storage.
        viewModelScope.launch { reload() }
    }

    // ------------------------------------------------------------- intents

    fun selectConversation(peerIdHex: String?) {
        selectedPeerHex = peerIdHex
        viewModelScope.launch { reload() }
    }

    fun postToChannel(text: String) {
        viewModelScope.launch {
            when (val result = container.node.postChannelMessage(text)) {
                is SendResult.Sent -> Unit
                is SendResult.Rejected -> _notice.value = result.reason
            }
            reload()
        }
    }

    fun sendPrivate(text: String) {
        val peer = selectedPeerHex ?: return
        viewModelScope.launch {
            when (val result = container.node.sendPrivateMessage(peer, text)) {
                is SendResult.Sent -> Unit
                is SendResult.Rejected -> _notice.value = result.reason
            }
            reload()
        }
    }

    fun setNickname(nickname: String) {
        viewModelScope.launch {
            container.node.setNickname(nickname)
            reload()
        }
    }

    /**
     * Asks the transport to reach a person the user tapped, and remembers the tap so the safety
     * code is offered automatically once their handshake completes.
     */
    fun requestConnect(peerHandle: String) {
        viewModelScope.launch {
            when (val result = container.node.requestConnect(peerHandle)) {
                is ConnectResult.Started -> Unit
                is ConnectResult.Rejected -> _notice.value = result.reason
            }
            reload()
        }
    }

    /** Opens the safety-code dialog for a peer we are already connected to. */
    fun requestVerification(peerIdHex: String) {
        val link = container.node.state.value.links.firstOrNull { it.peerIdHex == peerIdHex }
        _uiState.value = _uiState.value.copy(
            verifyRequest = VerifyRequest(
                peerIdHex = peerIdHex,
                nickname = link?.nickname ?: peerIdHex.take(8),
                code = link?.safetyCode,
            ),
        )
    }

    fun dismissVerification() {
        _uiState.value = _uiState.value.copy(verifyRequest = null)
    }

    fun confirmSafety(peerIdHex: String, accepted: Boolean) {
        viewModelScope.launch {
            // Dismiss first: the dialog's own confirm button is the last thing the user touched, and
            // the navigation that may follow should not race a still-visible sheet.
            _uiState.value = _uiState.value.copy(verifyRequest = null)
            container.node.confirmSafetyCode(peerIdHex, accepted)
            reload()
        }
    }

    fun notifyTyping(active: Boolean) {
        val peer = selectedPeerHex
        viewModelScope.launch { container.node.sendTyping(peer, active) }
    }

    fun startScan() = container.node.startScan()

    fun stopScan() = container.node.stopScan()

    fun refreshRadio() = container.refreshRadio()

    fun logs(): List<String> = container.logTail()

    fun consumeNotice() {
        _notice.value = null
    }

    // -------------------------------------------------------------- loading

    private suspend fun reload() {
        val node = container.node.state.value
        val channel = container.store.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, CHANNEL_WINDOW)
        val peers = container.store.listPeers()

        val conversations = peers.mapNotNull { peer ->
            val peerHex = com.airchat.protocol.ByteOps.toHex(peer.deviceId)
            val last = container.store.listMessages(peerHex, 1).lastOrNull() ?: return@mapNotNull null
            Conversation(
                peerIdHex = peerHex,
                nickname = peer.nickname.ifBlank { peerHex.take(8) },
                lastText = last.text,
                lastAtMs = last.receivedMs,
                connected = node.links.any { it.peerIdHex == peerHex && it.ready },
                trustState = peer.trustState,
            )
        }.sortedByDescending { it.lastAtMs }

        val rows = buildNearbyRows(node, peers)

        val selected = selectedPeerHex
        val thread = if (selected == null) emptyList() else container.store.listMessages(selected, THREAD_WINDOW)
        val selectedLink = node.links.firstOrNull { it.peerIdHex == selected }
        val selectedPeer = if (selected == null) null else container.store.getPeer(com.airchat.protocol.ByteOps.fromHex(selected))

        _uiState.value = ChatUiState(
            node = node,
            channel = channel,
            conversations = conversations,
            thread = thread,
            selectedPeerHex = selected,
            selectedNickname = selectedLink?.nickname ?: selectedPeer?.nickname,
            selectedTrustState = selectedPeer?.trustState ?: TrustState.UNVERIFIED,
            selectedSafetyCode = selectedLink?.safetyCode,
            selectedConnected = selectedLink?.ready == true,
            nearby = rows,
            verifyRequest = _uiState.value.verifyRequest?.takeIf { request ->
                // Drop the dialog if the peer left, so it cannot outlive the link it describes.
                node.links.any { it.peerIdHex == request.peerIdHex && it.ready }
            },
        )
    }

    /**
     * Merges the three sources of "who is around" into one row per person.
     *
     * A person is reachable in up to three ways at once - advertising, mid-handshake, and linked -
     * and the list has to show exactly one of them, with the most progressed state winning.
     */
    private fun buildNearbyRows(node: NodeState, peers: List<PeerRecord>): List<NearbyRow> {
        val nicknameByHex = peers.associate { ByteOps.toHex(it.deviceId) to it.nickname }
        val rows = LinkedHashMap<String, NearbyRow>()
        val claimedHandles = mutableSetOf<String>()

        // Linked: one row per person, keyed by deviceId so a reconnect cannot duplicate it.
        for (link in node.links.filter { it.ready }) {
            val peerHex = link.peerIdHex ?: continue
            link.peerHandle?.let { claimedHandles += it }
            rows[peerHex] = NearbyRow(
                key = peerHex,
                label = link.peerHandle ?: peerHex,
                title = link.nickname?.takeIf { it.isNotBlank() }
                    ?: nicknameByHex[peerHex]?.takeIf { it.isNotBlank() }
                    ?: anonymousName(link.peerHandle ?: peerHex),
                state = when (link.trustState) {
                    TrustState.TRUSTED -> NearbyState.TRUSTED
                    TrustState.REJECTED -> NearbyState.REJECTED
                    else -> NearbyState.UNVERIFIED
                },
                rssi = null,
                peerIdHex = peerHex,
            )
        }

        // Mid-handshake: only visible on the side that initiated, because the handle of a link the
        // peer opened is the peer's view of us, not the handle we scanned.
        for (link in node.links.filter { !it.ready }) {
            val handle = link.peerHandle ?: continue
            if (claimedHandles.contains(handle) || rows.containsKey("h:$handle")) continue
            claimedHandles += handle
            rows["h:$handle"] = NearbyRow(
                key = "h:$handle",
                label = handle,
                title = anonymousName(handle),
                state = NearbyState.CONNECTING,
                rssi = null,
                peerIdHex = null,
            )
        }

        // Merely visible. Skipped when a link already speaks for that handle, or when the node has
        // already attributed the advertisement to a person we are showing.
        for (peer in node.nearby) {
            if (claimedHandles.contains(peer.label)) continue
            val known = peer.peerIdHex
            if (known != null && rows.containsKey(known)) continue
            rows["h:${peer.label}"] = NearbyRow(
                key = "h:${peer.label}",
                label = peer.label,
                title = known?.let { nicknameByHex[it] }?.takeIf { it.isNotBlank() }
                    ?: anonymousName(peer.label),
                state = NearbyState.NEARBY,
                rssi = peer.rssi,
                peerIdHex = known,
            )
        }

        // Display order is the enum's declaration order: a decision the user owes comes before one
        // they have already made, and anyone reachable comes before anyone merely visible.
        return rows.values.sortedWith(
            compareBy({ it.state.ordinal }, { -(it.rssi ?: RSSI_UNKNOWN) }, { it.title }),
        )
    }

    private fun emptyState() = ChatUiState(
        node = NodeState.initial("", ""),
        channel = emptyList(),
        conversations = emptyList(),
        thread = emptyList(),
        selectedPeerHex = null,
        selectedNickname = null,
        selectedTrustState = TrustState.UNVERIFIED,
        selectedSafetyCode = null,
        selectedConnected = false,
        nearby = emptyList(),
        verifyRequest = null,
    )

    private companion object {
        /** Render window for the public channel: the retention policy keeps 500. */
        const val CHANNEL_WINDOW = 500
        const val THREAD_WINDOW = 500

        /** Sorts entries with no RSSI last. */
        const val RSSI_UNKNOWN = 127
    }
}

class ChatViewModelFactory(private val container: AirChatContainer) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        @Suppress("UNCHECKED_CAST")
        return ChatViewModel(container) as T
    }
}

/** Formats a status enum as a check-mark suffix; kept here so the UI stays declarative. */
/**
 * `附近设备 · 9B42`: a platform handle is a BLE address or a CoreBluetooth UUID, which tells a
 * person nothing, so it is reduced to a short tail that is at least stable and distinguishable.
 */
internal fun anonymousName(handle: String): String {
    val tail = handle.filter { it.isLetterOrDigit() }.takeLast(4).uppercase()
    return if (tail.isEmpty()) "附近设备" else "附近设备 · $tail"
}

internal fun MessageRecord.isOutgoing(): Boolean = direction == MessageDirection.OUTGOING

internal fun MessageRecord.isDelivered(): Boolean = status == MessageStatus.DELIVERED
