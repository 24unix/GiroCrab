package de.girocrab.app.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Brand: crab accent (coral red), emerald for positive amounts. */
object GiroColors {
    val Crab = Color(0xFF007AFF)
    val CrabDark = Color(0xFF0A84FF)
    val Emerald = Color(0xFF15803D)
    val EmeraldDark = Color(0xFF34D399)
    val Negative = Color(0xFFB91C1C)
    val NegativeDark = Color(0xFFF87171)
}

/** Semantic colours Material 3 has no slot for. */
@Immutable
data class GiroExtraColors(
    val positive: Color,
    val negative: Color,
    val cardSurface: Color,
    val cardBorder: Color,
)

val LocalGiroColors = staticCompositionLocalOf {
    GiroExtraColors(GiroColors.Emerald, GiroColors.Negative, Color.White, Color(0xFFE5E7EB))
}

val GiroBorderLight = Color(0xFFE5E7EB)
val GiroBorderDark = Color(0xFF2C2C2E)

private val LightScheme = lightColorScheme(
    primary = GiroColors.Crab,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD6E6FF),
    onPrimaryContainer = Color(0xFF004E8C),
    secondary = GiroColors.Emerald,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFD6E6FF),
    onSecondaryContainer = Color(0xFF004E8C),
    background = Color(0xFFF2F2F7),
    onBackground = Color(0xFF111418),
    surface = Color.White,
    onSurface = Color(0xFF111418),
    surfaceVariant = Color(0xFFF2F2F7),
    surfaceTint = Color.Transparent,
    surfaceContainer = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainerHigh = Color.White,
    surfaceContainerHighest = Color.White,
    onSurfaceVariant = Color(0xFF5B6470),
    outline = Color(0xFFE5E7EB),
    error = GiroColors.Negative,
)

private val DarkScheme = darkColorScheme(
    primary = GiroColors.CrabDark,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF1F3A60),
    onPrimaryContainer = Color(0xFFD6E6FF),
    secondary = GiroColors.EmeraldDark,
    onSecondary = Color(0xFF00382A),
    secondaryContainer = Color(0xFF1F3A60),
    onSecondaryContainer = Color(0xFFD6E6FF),
    background = Color(0xFF000000),
    onBackground = Color(0xFFE6E8EC),
    surface = Color(0xFF1C1C1E),
    onSurface = Color(0xFFE6E8EC),
    surfaceVariant = Color(0xFF2C2C2E),
    surfaceTint = Color.Transparent,
    surfaceContainer = Color(0xFF1C1C1E),
    surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainerHigh = Color(0xFF1C1C1E),
    surfaceContainerHighest = Color(0xFF1C1C1E),
    onSurfaceVariant = Color(0xFFA3ABB7),
    outline = Color(0xFF2C2C2E),
    error = GiroColors.NegativeDark,
)

/** Tabular (fixed-width) digits so amounts align in columns, like `monospacedDigit()` on iOS. */
fun TextStyle.tabular(): TextStyle = copy(fontFeatureSettings = "tnum")


private val GiroTypography = Typography().let { base ->
    base.copy(
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        labelMedium = base.labelMedium.copy(letterSpacing = 0.2.sp),
    )
}

/** Amount text style: tabular numerals, semibold. */
@Composable
fun amountTextStyle(base: TextStyle = MaterialTheme.typography.bodyLarge): TextStyle =
    base.copy(fontWeight = FontWeight.SemiBold).tabular()

/** Emerald for income, negative red for expenses, neutral for zero. */
@Composable
fun amountColor(cents: Long): Color = when {
    cents > 0 -> LocalGiroColors.current.positive
    cents < 0 -> LocalGiroColors.current.negative
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
fun GiroCrabTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false, // brand palette by default, for parity with iOS/macOS
    content: @Composable () -> Unit,
) {
    val scheme: ColorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val ctx = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        }
        darkTheme -> DarkScheme
        else -> LightScheme
    }
    val extra = if (darkTheme) {
        GiroExtraColors(GiroColors.EmeraldDark, GiroColors.NegativeDark, scheme.surface, scheme.outline)
    } else {
        GiroExtraColors(GiroColors.Emerald, GiroColors.Negative, scheme.surface, scheme.outline)
    }
    CompositionLocalProvider(LocalGiroColors provides extra) {
        MaterialTheme(colorScheme = scheme, typography = GiroTypography, content = content)
    }
}
