package com.airchat.app.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.windowsizeclass.WindowSizeClass
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.airchat.app.R
import com.airchat.app.RadioController
import com.airchat.protocol.ByteOps
import com.airchat.protocol.ChatStatus
import com.airchat.protocol.MessageDirection
import com.airchat.protocol.MessageRecord
import com.airchat.protocol.MessageStatus
import com.airchat.protocol.NodeState
import com.airchat.protocol.TrustState
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The five states a person's row can be in, declared in display order: whoever needs a decision
 * comes first, then whoever is reachable, then whoever is merely visible.
 */
enum class NearbyState(@param:StringRes val labelRes: Int) {
    UNVERIFIED(R.string.nearby_state_unverified),
    REJECTED(R.string.nearby_state_rejected),
    TRUSTED(R.string.nearby_state_trusted),
    CONNECTING(R.string.nearby_state_connecting),
    NEARBY(R.string.nearby_state_nearby),
}

@Composable
private fun NearbyState.color(): Color = when (this) {
    NearbyState.UNVERIFIED -> Color(0xFFE07B00)
    NearbyState.REJECTED -> MaterialTheme.colorScheme.error
    NearbyState.TRUSTED -> MaterialTheme.colorScheme.primary
    NearbyState.CONNECTING, NearbyState.NEARBY -> MaterialTheme.colorScheme.onSurfaceVariant
}

private enum class Tab(val labelRes: Int, val icon: ImageVector) {
    Nearby(R.string.tab_nearby, Icons.Filled.Place),
    Channel(R.string.tab_channel, Icons.Filled.Home),
    Direct(R.string.tab_direct, Icons.Filled.Person),
    Settings(R.string.tab_settings, Icons.Filled.Settings),
}

/**
 * Root of the UI: gates on permissions and adapter state, keeps the link service alive, and
 * hosts the adaptive navigation shell.
 *
 * The navigation pattern follows the width size class, so the same screens work as a phone
 * bottom bar, a tablet rail beside a wider list, or a folded inner display.
 */
@Composable
fun AirChatRoot(
    controller: RadioController,
    viewModel: ChatViewModel,
    windowSizeClass: WindowSizeClass,
) {
    var hasPermissions by remember { mutableStateOf(controller.hasBluetoothPermissions()) }
    var bluetoothEnabled by remember { mutableStateOf(controller.isBluetoothEnabled()) }
    var serviceEnabled by rememberSaveable { mutableStateOf(true) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        hasPermissions = controller.hasBluetoothPermissions()
        controller.refreshRadio()
    }
    val bluetoothLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) {
        bluetoothEnabled = controller.isBluetoothEnabled()
        controller.refreshRadio()
    }

    LaunchedEffect(Unit) {
        if (!hasPermissions) {
            permissionLauncher.launch(controller.allRuntimePermissions())
        }
    }
    LaunchedEffect(hasPermissions, bluetoothEnabled, serviceEnabled) {
        if (hasPermissions && bluetoothEnabled) {
            if (serviceEnabled) controller.startLinkService() else controller.stopLinkService()
        }
    }

    when {
        !controller.isBluetoothSupported() -> GateScreen(
            icon = Icons.Filled.Warning,
            title = "此设备不支持蓝牙 LE",
            body = "AirChat 完全依赖蓝牙点对点通信，没有服务器中转，因此无法在此设备上运行。",
            actionLabel = null,
            onAction = {},
        )

        !hasPermissions -> GateScreen(
            icon = Icons.Filled.Lock,
            title = stringResource(R.string.permission_title),
            body = stringResource(R.string.permission_body),
            actionLabel = stringResource(R.string.permission_action),
            onAction = { permissionLauncher.launch(controller.allRuntimePermissions()) },
        )

        !bluetoothEnabled -> GateScreen(
            icon = Icons.Filled.Warning,
            title = stringResource(R.string.bluetooth_off_title),
            body = stringResource(R.string.bluetooth_off_body),
            actionLabel = stringResource(R.string.bluetooth_off_action),
            onAction = {
                runCatching { bluetoothLauncher.launch(controller.bluetoothEnableIntent()) }
                bluetoothEnabled = controller.isBluetoothEnabled()
            },
        )

        else -> ChatShell(
            viewModel = viewModel,
            windowSizeClass = windowSizeClass,
            serviceEnabled = serviceEnabled,
            onServiceEnabledChange = { serviceEnabled = it },
        )
    }
}

@Composable
private fun GateScreen(
    icon: ImageVector,
    title: String,
    body: String,
    actionLabel: String?,
    onAction: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(48.dp))
            Spacer(Modifier.height(16.dp))
            Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            Text(
                body,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (actionLabel != null) {
                Spacer(Modifier.height(24.dp))
                Button(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}

@Composable
private fun ChatShell(
    viewModel: ChatViewModel,
    windowSizeClass: WindowSizeClass,
    serviceEnabled: Boolean,
    onServiceEnabledChange: (Boolean) -> Unit,
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val notice by viewModel.notice.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    var tabName by rememberSaveable { mutableStateOf(Tab.Nearby.name) }
    val selectedTab = Tab.entries.firstOrNull { it.name == tabName } ?: Tab.Nearby
    val compact = windowSizeClass.widthSizeClass == WindowWidthSizeClass.Compact

    LaunchedEffect(notice) {
        val message = notice
        if (message != null) {
            snackbarHostState.showSnackbar(message)
            viewModel.consumeNotice()
        }
    }

    // Participates in predictive back: from inside a thread, back returns to the conversation list.
    BackHandler(enabled = selectedTab == Tab.Direct && uiState.selectedPeerHex != null) {
        viewModel.selectConversation(null)
    }

    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        bottomBar = {
            if (compact) {
                NavigationBar {
                    Tab.entries.forEach { entry ->
                        NavigationBarItem(
                            selected = entry == selectedTab,
                            onClick = { tabName = entry.name },
                            icon = { Icon(entry.icon, contentDescription = null) },
                            label = { Text(stringResource(entry.labelRes)) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        Row(modifier = Modifier.fillMaxSize().padding(padding)) {
            if (!compact) {
                NavigationRail {
                    Spacer(Modifier.height(8.dp))
                    Tab.entries.forEach { entry ->
                        NavigationRailItem(
                            selected = entry == selectedTab,
                            onClick = { tabName = entry.name },
                            icon = { Icon(entry.icon, contentDescription = null) },
                            label = { Text(stringResource(entry.labelRes)) },
                        )
                    }
                }
            }
            Box(modifier = Modifier.fillMaxSize()) {
                when (selectedTab) {
                    Tab.Nearby -> NearbyScreen(
                        state = uiState,
                        onScan = viewModel::startScan,
                        onStopScan = viewModel::stopScan,
                        onRowClick = { row ->
                            // One tap means three different things depending on state, which is what
                            // keeps the screen free of buttons: reach out, compare the code, or open
                            // the conversation.
                            when (row.state) {
                                NearbyState.NEARBY -> viewModel.requestConnect(row.label)
                                NearbyState.UNVERIFIED, NearbyState.REJECTED ->
                                    row.peerIdHex?.let(viewModel::requestVerification)
                                NearbyState.TRUSTED -> row.peerIdHex?.let { peer ->
                                    tabName = Tab.Direct.name
                                    viewModel.selectConversation(peer)
                                }
                                NearbyState.CONNECTING -> Unit
                            }
                        },
                        onConfirmSafety = { peer, accepted ->
                            viewModel.confirmSafety(peer, accepted)
                            // Confirming in person is the end of the connection flow: land the user in
                            // the conversation rather than dropping them back on the list.
                            if (accepted) {
                                tabName = Tab.Direct.name
                                viewModel.selectConversation(peer)
                            }
                        },
                        onDismissVerify = viewModel::dismissVerification,
                    )

                    Tab.Channel -> ChannelScreen(
                        state = uiState.node,
                        messages = uiState.channel,
                        onSend = viewModel::postToChannel,
                    )

                    Tab.Direct -> DirectScreen(
                        state = uiState,
                        onSelect = viewModel::selectConversation,
                        onSend = viewModel::sendPrivate,
                        onConfirmSafety = viewModel::confirmSafety,
                        onTyping = viewModel::notifyTyping,
                    )

                    Tab.Settings -> SettingsScreen(
                        state = uiState.node,
                        serviceEnabled = serviceEnabled,
                        onServiceEnabledChange = onServiceEnabledChange,
                        onNicknameChange = viewModel::setNickname,
                        logsProvider = viewModel::logs,
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------------- 附近

/**
 * The nearby list: one row per person, whatever state their link is in.
 *
 * Discovery and connection are automatic (the public channel depends on reaching everyone
 * nearby), so this screen is not a "pairing wizard": it shows what the radio is already doing and
 * turns a tap into the one step that needs a human - comparing the safety code, or opening the
 * conversation with someone whose code was already compared. A tap on a person who is merely
 * visible asks the transport to connect now rather than waiting for the next scan round.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NearbyScreen(
    state: ChatUiState,
    onScan: () -> Unit,
    onStopScan: () -> Unit,
    onRowClick: (NearbyRow) -> Unit,
    onConfirmSafety: (String, Boolean) -> Unit,
    onDismissVerify: () -> Unit,
) {
    val scanning = state.node.scanning
    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(stringResource(R.string.tab_nearby)) },
            actions = {
                // Looking for people is the one thing here that costs battery, so it is a button
                // rather than something the app does to you indefinitely.
                TextButton(onClick = if (scanning) onStopScan else onScan) {
                    Text(
                        stringResource(
                            if (scanning) R.string.nearby_stop_scan else R.string.nearby_start_scan,
                        ),
                    )
                }
                IconButton(onClick = if (scanning) onStopScan else onScan) {
                    Icon(
                        imageVector = if (scanning) Icons.Filled.Close else Icons.Filled.Search,
                        contentDescription = stringResource(
                            if (scanning) R.string.nearby_stop_scan else R.string.nearby_start_scan,
                        ),
                    )
                }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { StatusCard(state.node) }

            if (state.nearby.isNotEmpty()) {
                item { SectionTitle(stringResource(R.string.nearby_section, state.nearby.size)) }
                items(state.nearby, key = { it.key }) { row ->
                    NearbyRowItem(row = row, onClick = { onRowClick(row) })
                }
            } else {
                item {
                    Text(
                        stringResource(
                            if (scanning) R.string.nearby_empty else R.string.nearby_not_scanned,
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }

    state.verifyRequest?.let { request ->
        SafetyCodeDialog(
            nickname = request.nickname,
            code = request.code,
            onConfirm = { onConfirmSafety(request.peerIdHex, true) },
            onReject = { onConfirmSafety(request.peerIdHex, false) },
            onDismiss = onDismissVerify,
        )
    }
}

@Composable
private fun StatusCard(state: NodeState) {
    val label: String
    val detail: String
    when (state.status) {
        ChatStatus.SCANNING -> {
            label = stringResource(R.string.status_scanning)
            detail = "正在广播并扫描 AirChat 服务"
        }
        ChatStatus.NEARBY_FULL -> {
            label = stringResource(R.string.nearing_full)
            detail = "已达并发连接上限，断开一个后才会继续发现新的人"
        }
        ChatStatus.PERMISSION_MISSING -> {
            label = stringResource(R.string.permission_title)
            detail = state.statusMessage
        }
        ChatStatus.BLUETOOTH_UNAVAILABLE -> {
            label = stringResource(R.string.bluetooth_off_title)
            detail = state.statusMessage
        }
        ChatStatus.FAILED -> {
            label = "蓝牙出错"
            detail = state.statusMessage
        }
        ChatStatus.STOPPED -> {
            label = stringResource(R.string.status_stopped)
            detail = "打开后台连接后即可扫描附近的人"
        }
        ChatStatus.IDLE -> {
            label = stringResource(R.string.status_idle)
            detail = "广播中，别人仍能发现你；点右上角「扫描」开始寻找附近的人"
        }
    }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (state.status == ChatStatus.SCANNING) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.size(12.dp))
                }
                Text(label, style = MaterialTheme.typography.titleMedium)
            }
            Spacer(Modifier.height(6.dp))
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun NearbyRowItem(row: NearbyRow, onClick: () -> Unit) {
    ListItem(
        content = {
            Text(row.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        supportingContent = {
            Text(
                text = row.subtitle(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        leadingContent = {
            Icon(
                imageVector = when (row.state) {
                    NearbyState.TRUSTED, NearbyState.UNVERIFIED, NearbyState.REJECTED -> Icons.Filled.Lock
                    else -> Icons.Filled.Place
                },
                contentDescription = null,
            )
        },
        trailingContent = {
            if (row.state == NearbyState.CONNECTING) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            } else {
                Text(
                    text = stringResource(row.state.labelRes),
                    style = MaterialTheme.typography.labelMedium,
                    color = row.state.color(),
                )
            }
        },
        modifier = Modifier.clickableRow(onClick),
    )
}

/** The one-line explanation under a person's name: what the radio is doing, and how well. */
@Composable
private fun NearbyRow.subtitle(): String {
    val signal = rssi?.let { stringResource(R.string.nearby_signal, signalLabel(it)) }
    return when (state) {
        NearbyState.NEARBY -> signal ?: stringResource(R.string.nearby_state_nearby)
        NearbyState.CONNECTING -> stringResource(R.string.nearby_connecting_detail)
        NearbyState.UNVERIFIED -> if (signal == null) {
            stringResource(R.string.nearby_unverified_detail)
        } else {
            stringResource(R.string.nearby_unverified_detail) + " · " + signal
        }
        NearbyState.TRUSTED -> stringResource(R.string.nearby_trusted_detail)
        NearbyState.REJECTED -> stringResource(R.string.nearby_rejected_detail)
    }
}

@Composable
private fun signalLabel(rssi: Int): String = stringResource(
    when {
        rssi >= -60 -> R.string.nearby_signal_strong
        rssi >= -80 -> R.string.nearby_signal_medium
        else -> R.string.nearby_signal_weak
    },
)

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 8.dp),
    )
}

// ------------------------------------------------------------------ 公共频道

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChannelScreen(
    state: NodeState,
    messages: List<MessageRecord>,
    onSend: (String) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(title = { Text(stringResource(R.string.tab_channel)) })
        Text(
            stringResource(R.string.channel_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        MessageList(
            messages = messages,
            emptyText = stringResource(R.string.channel_empty),
            showSender = true,
            modifier = Modifier.weight(1f),
        )
        MessageComposer(
            enabled = state.readyLinkCount > 0,
            disabledHint = "还没有连接任何人",
            onSend = onSend,
        )
    }
}

// --------------------------------------------------------------------- 私聊

@Composable
private fun DirectScreen(
    state: ChatUiState,
    onSelect: (String?) -> Unit,
    onSend: (String) -> Unit,
    onConfirmSafety: (String, Boolean) -> Unit,
    onTyping: (Boolean) -> Unit,
) {
    if (state.selectedPeerHex == null) {
        ConversationList(state = state, onSelect = onSelect)
    } else {
        ThreadScreen(
            state = state,
            onBack = { onSelect(null) },
            onSend = onSend,
            onConfirmSafety = onConfirmSafety,
            onTyping = onTyping,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationList(state: ChatUiState, onSelect: (String) -> Unit) {
    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(title = { Text(stringResource(R.string.tab_direct)) })
        if (state.conversations.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    stringResource(R.string.direct_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(32.dp),
                )
            }
        } else {
            LazyColumn {
                items(state.conversations, key = { it.peerIdHex }) { conversation ->
                    ListItem(
                        content = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(conversation.nickname, modifier = Modifier.weight(1f))
                                if (conversation.connected) {
                                    Text(
                                        stringResource(R.string.link_ready),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.primary,
                                    )
                                }
                            }
                        },
                        supportingContent = {
                            Text(conversation.lastText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        },
                        leadingContent = { Icon(Icons.Filled.Person, contentDescription = null) },
                        trailingContent = { Text(formatTime(conversation.lastAtMs)) },
                        modifier = Modifier.clickableRow { onSelect(conversation.peerIdHex) },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ThreadScreen(
    state: ChatUiState,
    onBack: () -> Unit,
    onSend: (String) -> Unit,
    onConfirmSafety: (String, Boolean) -> Unit,
    onTyping: (Boolean) -> Unit,
) {
    val peerHex = state.selectedPeerHex ?: return
    var verifying by remember { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(state.selectedNickname ?: peerHex.take(8)) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                }
            },
            actions = {
                if (state.selectedSafetyCode != null) {
                    IconButton(onClick = { verifying = true }) {
                        Icon(Icons.Filled.Lock, contentDescription = "核对安全码")
                    }
                }
            },
        )

        TrustBanner(
            trustState = state.selectedTrustState,
            connected = state.selectedConnected,
            onVerify = { verifying = true },
        )

        MessageList(
            messages = state.thread,
            emptyText = "还没有消息。1:1 消息使用端到端加密。",
            showSender = false,
            modifier = Modifier.weight(1f),
        )
        MessageComposer(
            enabled = state.selectedConnected,
            disabledHint = "对方不在附近，无法发送加密消息",
            onSend = onSend,
            onTyping = onTyping,
        )
    }

    if (verifying) {
        SafetyCodeDialog(
            nickname = state.selectedNickname ?: "对方",
            code = state.selectedSafetyCode,
            onConfirm = {
                onConfirmSafety(peerHex, true)
                verifying = false
            },
            onReject = {
                onConfirmSafety(peerHex, false)
                verifying = false
            },
            onDismiss = { verifying = false },
        )
    }
}

@Composable
private fun TrustBanner(trustState: Int, connected: Boolean, onVerify: () -> Unit) {
    if (!connected) {
        Banner(
            text = "对方不在附近。AirChat 没有服务器，消息只在双方都在附近时送达。",
            container = MaterialTheme.colorScheme.errorContainer,
            content = MaterialTheme.colorScheme.onErrorContainer,
        )
        return
    }
    when (trustState) {
        TrustState.TRUSTED -> Banner(
            text = "安全码已核对，会话已端到端加密。",
            container = MaterialTheme.colorScheme.secondaryContainer,
            content = MaterialTheme.colorScheme.onSecondaryContainer,
        )

        TrustState.REJECTED -> Banner(
            text = "你标记了安全码不匹配，已阻止发送。",
            container = MaterialTheme.colorScheme.errorContainer,
            content = MaterialTheme.colorScheme.onErrorContainer,
        )

        else -> Banner(
            text = "尚未核对安全码。消息已加密，但无法排除中间人。",
            container = MaterialTheme.colorScheme.tertiaryContainer,
            content = MaterialTheme.colorScheme.onTertiaryContainer,
            onClick = onVerify,
        )
    }
}

@Composable
private fun Banner(
    text: String,
    container: Color,
    content: Color,
    onClick: (() -> Unit)? = null,
) {
    Surface(color = container, modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            Icon(Icons.Filled.Info, contentDescription = null, tint = content, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(8.dp))
            Text(text, style = MaterialTheme.typography.bodySmall, color = content, modifier = Modifier.weight(1f))
            if (onClick != null) {
                TextButton(onClick = onClick) { Text("核对") }
            }
        }
    }
}

// ------------------------------------------------------------- 消息列表与输入

@Composable
private fun MessageList(
    messages: List<MessageRecord>,
    emptyText: String,
    showSender: Boolean,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.lastIndex)
    }

    if (messages.isEmpty()) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                emptyText,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(32.dp),
            )
        }
        return
    }

    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(messages, key = { ByteOps.toHex(it.msgId) }) { message ->
            MessageBubble(message = message, showSender = showSender)
        }
    }
}

@Composable
private fun MessageBubble(message: MessageRecord, showSender: Boolean) {
    val outgoing = message.direction == MessageDirection.OUTGOING
    val container = if (outgoing) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.surfaceVariant
    }
    val content = if (outgoing) {
        MaterialTheme.colorScheme.onPrimaryContainer
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (outgoing) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            color = container,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                if (showSender && !outgoing) {
                    Text(
                        ByteOps.toHex(message.senderId).take(6),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                Text(message.text, style = MaterialTheme.typography.bodyMedium, color = content)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        formatTime(message.receivedMs),
                        style = MaterialTheme.typography.labelSmall,
                        color = content,
                    )
                    if (outgoing) {
                        Spacer(Modifier.size(6.dp))
                        Text(
                            if (message.status == MessageStatus.DELIVERED) "\u2713\u2713" else "\u2713",
                            style = MaterialTheme.typography.labelSmall,
                            color = content,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MessageComposer(
    enabled: Boolean,
    disabledHint: String,
    onSend: (String) -> Unit,
    onTyping: ((Boolean) -> Unit)? = null,
) {
    var text by remember { mutableStateOf("") }
    val send = {
        val body = text.trim()
        if (body.isNotEmpty()) {
            onSend(body)
            text = ""
            onTyping?.invoke(false)
        }
    }

    Column(modifier = Modifier.fillMaxWidth().imePadding().navigationBarsPadding()) {
        HorizontalDivider()
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            OutlinedTextField(
                value = text,
                onValueChange = {
                    text = it
                    onTyping?.invoke(it.isNotEmpty())
                },
                enabled = enabled,
                placeholder = {
                    Text(if (enabled) stringResource(R.string.message_hint) else disabledHint)
                },
                maxLines = 4,
                modifier = Modifier.weight(1f),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { send() }),
            )
            Spacer(Modifier.size(8.dp))
            IconButton(onClick = send, enabled = enabled && text.isNotBlank()) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.send))
            }
        }
    }
}

// --------------------------------------------------------------------- 设置

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(
    state: NodeState,
    serviceEnabled: Boolean,
    onServiceEnabledChange: (Boolean) -> Unit,
    onNicknameChange: (String) -> Unit,
    logsProvider: () -> List<String>,
) {
    var nickname by remember { mutableStateOf(state.nickname) }
    var showLogs by remember { mutableStateOf(false) }

    LaunchedEffect(state.nickname) {
        if (nickname != state.nickname) nickname = state.nickname
    }

    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(title = { Text(stringResource(R.string.tab_settings)) })
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                OutlinedTextField(
                    value = nickname,
                    onValueChange = { nickname = it.take(12) },
                    label = { Text(stringResource(R.string.settings_nickname)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                Button(onClick = { onNicknameChange(nickname) }) { Text("保存昵称") }
            }
            item {
                ListItem(
                    content = { Text("后台保持连接") },
                    supportingContent = { Text("以前台服务保持蓝牙连接，锁屏后仍可收到消息") },
                    trailingContent = {
                        Switch(checked = serviceEnabled, onCheckedChange = onServiceEnabledChange)
                    },
                )
            }
            item {
                ListItem(
                    content = { Text(stringResource(R.string.settings_device_id)) },
                    supportingContent = {
                        Text(
                            state.deviceIdHex.ifEmpty { "初始化中…" },
                            fontFamily = FontFamily.Monospace,
                        )
                    },
                )
            }
            if (state.links.isNotEmpty()) {
                item { SectionTitle(stringResource(R.string.settings_links_title)) }
                items(state.links, key = { it.linkId }) { link ->
                    ListItem(
                        content = {
                            Text(link.nickname ?: link.peerHandle ?: link.linkId, maxLines = 1)
                        },
                        supportingContent = {
                            Text(
                                buildString {
                                    append(if (link.isCentral) "我发起" else "对方发起")
                                    append(" · MTU ${link.mtu}")
                                    append(
                                        when (link.trustState) {
                                            TrustState.TRUSTED -> " · 安全码已核对"
                                            TrustState.REJECTED -> " · 已拒绝"
                                            else -> " · 未核对"
                                        },
                                    )
                                    if (link.peerConfirmedTheCode) append(" · 对方已确认")
                                    if (!link.ready) append(" · 握手中")
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        },
                    )
                }
            }
            item {
                ListItem(
                    content = { Text("存储策略") },
                    supportingContent = { Text(stringResource(R.string.settings_retention)) },
                )
            }
            item {
                ListItem(
                    content = { Text("iOS 兼容性说明") },
                    supportingContent = { Text(stringResource(R.string.settings_ios_note)) },
                )
            }
            item {
                OutlinedButton(onClick = { showLogs = !showLogs }) {
                    Text(if (showLogs) "隐藏诊断日志" else stringResource(R.string.settings_logs))
                }
            }
            if (showLogs) {
                item {
                    val logs = logsProvider()
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = RoundedCornerShape(8.dp),
                    ) {
                        Text(
                            if (logs.isEmpty()) "暂无日志" else logs.takeLast(120).joinToString("\n"),
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 320.dp)
                                .padding(12.dp),
                        )
                    }
                }
            }
        }
    }
}

// ----------------------------------------------------------------- 安全码弹窗

@Composable
private fun SafetyCodeDialog(
    nickname: String,
    code: String?,
    onConfirm: () -> Unit,
    onReject: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.safety_title)) },
        text = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.safety_body), style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(16.dp))
                if (code == null) {
                    Text("对方已断开，无法核对", color = MaterialTheme.colorScheme.error)
                } else {
                    Text(
                        code.chunked(3).joinToString(" "),
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        fontSize = 40.sp,
                        letterSpacing = 4.sp,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text("与 $nickname 当面比对", style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        confirmButton = {
            Button(onClick = onConfirm, enabled = code != null) {
                Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text(stringResource(R.string.safety_match))
            }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDismiss) { Text("稍后") }
                TextButton(onClick = onReject) {
                    Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text(stringResource(R.string.safety_mismatch))
                }
            }
        },
    )
}

// ---------------------------------------------------------------------- 工具

private fun Modifier.clickableRow(onClick: () -> Unit): Modifier =
    this.then(Modifier.clickable(onClick = onClick))

private val TIME_FORMATTER: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")

private fun formatTime(epochMillis: Long): String = runCatching {
    TIME_FORMATTER.format(Instant.ofEpochMilli(epochMillis).atZone(ZoneId.systemDefault()))
}.getOrDefault("")
