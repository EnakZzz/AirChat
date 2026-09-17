package com.airchat.app

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

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 15+ enforces edge-to-edge for targetSdk 35+; opting in explicitly keeps the
        // behaviour identical on older releases and lets Compose consume the insets.
        enableEdgeToEdge()

        val container = (application as AirChatApp).container
        val controller = RadioController(this, container)

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
