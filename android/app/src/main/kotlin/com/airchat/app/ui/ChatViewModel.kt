package com.airchat.app.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.airchat.app.AirChatContainer
import com.airchat.protocol.AirChatProtocol
import com.airchat.protocol.MessageDirection
import com.airchat.protocol.MessageRecord
import com.airchat.protocol.MessageStatus
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
            container.node.events.collect { reload() }
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

    fun confirmSafety(peerIdHex: String, accepted: Boolean) {
        viewModelScope.launch {
            container.node.confirmSafetyCode(peerIdHex, accepted)
            reload()
        }
    }

    fun notifyTyping(active: Boolean) {
        val peer = selectedPeerHex
        viewModelScope.launch { container.node.sendTyping(peer, active) }
    }

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
    )

    private companion object {
        /** Render window for the public channel: the retention policy keeps 500. */
        const val CHANNEL_WINDOW = 500
        const val THREAD_WINDOW = 500
    }
}

class ChatViewModelFactory(private val container: AirChatContainer) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        @Suppress("UNCHECKED_CAST")
        return ChatViewModel(container) as T
    }
}

/** Formats a status enum as a check-mark suffix; kept here so the UI stays declarative. */
internal fun MessageRecord.isOutgoing(): Boolean = direction == MessageDirection.OUTGOING

internal fun MessageRecord.isDelivered(): Boolean = status == MessageStatus.DELIVERED
