package com.airchat.app

import android.content.pm.ApplicationInfo
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.lifecycle.viewmodel.compose.viewModel
import com.airchat.app.ui.AirChatRoot
import com.airchat.app.ui.AirChatTheme
import com.airchat.app.ui.ChatViewModel
import com.airchat.app.ui.ChatViewModelFactory

/**
 * Single-activity host.
 *
 * Deliberately thin: the activity owns nothing Bluetooth related, so rotating, splitting or
 * finishing it never disturbs an established link. The link lives in [AirChatLinkService].
 */
class MainActivity : ComponentActivity() {

    private companion object {
        const val SELF_TEST_EXTRA = "airchat_selftest"
        const val CONNECT_FIRST_EXTRA = "airchat_connect_first"
        const val SCAN_EXTRA = "airchat_scan"
        const val CLEAR_TRUST_EXTRA = "airchat_clear_trust"
    }

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 15+ enforces edge-to-edge for targetSdk 35+; opting in explicitly keeps the
        // behaviour identical on older releases and lets Compose consume the insets.
        enableEdgeToEdge()

        val container = (application as AirChatApp).container
        val controller = RadioController(this, container)

        // Debug-only message injection used by tools/cross_device_test.py. Gated on the debuggable
        // flag so a release build cannot be told to send anything from outside.
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable) {
            intent?.getStringExtra(SELF_TEST_EXTRA)?.takeIf { it.isNotEmpty() }?.let(container::runSelfTest)
            // Taps the first person that shows up, so the harness can drive the same path a user
            // does instead of only the messaging path.
            if (intent?.getBooleanExtra(CONNECT_FIRST_EXTRA, false) == true) container.connectFirstPeer()
            // Scan and nothing else: the harness uses this for the phases that are about the link
            // itself rather than about a scripted message.
            if (intent?.getBooleanExtra(SCAN_EXTRA, false) == true) container.startDebugScan()
            // Forgetting the verdicts is what lets a suite observe a *first* safety-code comparison
            // without reinstalling the app, which would drop the Bluetooth permission.
            if (intent?.getBooleanExtra(CLEAR_TRUST_EXTRA, false) == true) container.clearTrustVerdicts()
        }

        setContent {
            AirChatTheme {
                val windowSizeClass = calculateWindowSizeClass(this)
                val chatViewModel: ChatViewModel = viewModel(
                    factory = ChatViewModelFactory(container),
                )
                AirChatRoot(
                    controller = controller,
                    viewModel = chatViewModel,
                    windowSizeClass = windowSizeClass,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // The user may have toggled Bluetooth or granted permissions outside the app.
        (application as AirChatApp).container.refreshRadio()
    }
}
