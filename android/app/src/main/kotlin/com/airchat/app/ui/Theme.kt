package com.airchat.app.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/**
 * Material 3 Expressive with dynamic colour.
 *
 * Expressive is the current Material specification (compose-material3 1.4+), and it is adopted
 * purely through the theme: the type scale, the shape language and the motion scheme all come from
 * here, so screens keep the same layout and structure they had before. That matters because this
 * app is deliberately laid out like its iOS counterpart.
 *
 * AirChat targets API 31+, where `dynamicLightColorScheme` is always available, so the wallpaper
 * derived palette (Material You) is used unconditionally. The static scheme is kept as a
 * defensive fallback because dynamic colour can throw on some vendor ROMs.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AirChatTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else {
            if (darkTheme) darkColorScheme() else lightColorScheme()
        }
    }.getOrElse {
        if (darkTheme) darkColorScheme() else lightColorScheme()
    }

    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        // Expressive motion: the springs the standard components animate with. Nothing in the app
        // animates by hand, so this is where the motion comes from.
        motionScheme = MotionScheme.expressive(),
        content = content,
    )
}
