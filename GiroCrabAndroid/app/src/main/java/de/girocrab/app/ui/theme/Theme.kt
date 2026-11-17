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
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** 1:1 port of `Theme` in GiroCrabApp/Sources/GiroCrabUI/Formatting.swift (+ AccentColor asset). */
object GiroColors {
    val Accent = Color(0xFF2563EB)          // AccentColor light
    val AccentDark = Color(0xFF3B82F6)      // AccentColor dark
    val Inflow = Color(0xFF047857)          // Theme.inflowSpec light
    val InflowDark = Color(0xFF34D399)
    val Negative = Color(0xFFB91C1C)        // Theme.negativeSpec / chargeSpec
    val NegativeDark = Color(0xFFF87171)
    val Outflow = Color(0xFF0F172A)         // Theme.outflowSpec (expense bars)
    val OutflowDark = Color(0xFFF1F5F9)
    val Canvas = Color(0xFFF8FAFC)
    val CanvasDark = Color(0xFF0F172A)
    val Sidebar = Color(0xFFF3F4F6)
    val SidebarDark = Color(0xFF0B1220)
    val Card = Color(0xFFFFFFFF)
    val CardDark = Color(0xFF1E293B)
    val Border = Color(0xFFE2E8F0)
    val BorderDark = Color(0xFF334155)
    val Text = Color(0xFF0F172A)
    val TextDark = Color(0xFFF1F5F9)
    val Secondary = Color(0xFF4B5A70)
    val SecondaryDark = Color(0xFFA3B1C4)
    val Tertiary = Color(0xFF64748B)
    val TertiaryDark = Color(0xFF8494AA)
    val InflowBadge = Color(0xFFECFDF5)
    val InflowBadgeDark = Color(0xFF064E3B)
    val OutflowBadge = Color(0xFFFEF2F2)
    val OutflowBadgeDark = Color(0xFF5B1B1B)
    /** Chart bar opacity (CategorySumChart / BalanceHeaderView: `.opacity(0.85)`, corner radius 1.5). */
    const val BarAlpha = 0.85f
    /** `Theme.selection` on iOS: accent.opacity(0.15); demo-banner stroke accent.opacity(0.18). */
    const val SelectionAlpha = 0.15f
    const val DemoBorderAlpha = 0.18f
    const val BadgeAlpha = 0.12f
}

/** Semantic colours Material 3 has no slot for. */
@Immutable
data class GiroExtraColors(
    val positive: Color,
    val negative: Color,
    val cardSurface: Color,
    val cardBorder: Color,
    val outflow: Color = GiroColors.Outflow,
    val tertiary: Color = GiroColors.Tertiary,
    val accent: Color = GiroColors.Accent,
)

val LocalGiroColors = staticCompositionLocalOf {
    GiroExtraColors(GiroColors.Inflow, GiroColors.Negative, GiroColors.Card, GiroColors.Border)
}

val GiroBorderLight = GiroColors.Border
val GiroBorderDark = GiroColors.BorderDark

private val LightScheme = lightColorScheme(
    primary = GiroColors.Accent,
    onPrimary = Color.White,
    primaryContainer = GiroColors.Accent.copy(alpha = GiroColors.SelectionAlpha).compositeOver(Color.White),
    onPrimaryContainer = GiroColors.Text,
    secondary = GiroColors.Inflow,
    onSecondary = Color.White,
    secondaryContainer = GiroColors.InflowBadge,
    onSecondaryContainer = GiroColors.Inflow,
    background = GiroColors.Canvas,
    onBackground = GiroColors.Text,
    surface = GiroColors.Card,
    onSurface = GiroColors.Text,
    surfaceVariant = GiroColors.Canvas,
    surfaceTint = Color.Transparent,
    surfaceContainer = GiroColors.Card,
    surfaceContainerLow = GiroColors.Card,
    surfaceContainerHigh = GiroColors.Card,
    surfaceContainerHighest = GiroColors.Card,
    onSurfaceVariant = GiroColors.Secondary,
    outline = GiroColors.Border,
    outlineVariant = GiroColors.Border,
    error = GiroColors.Negative,
)

private val DarkScheme = darkColorScheme(
    primary = GiroColors.AccentDark,
    onPrimary = Color.White,
    primaryContainer = GiroColors.AccentDark.copy(alpha = GiroColors.SelectionAlpha).compositeOver(GiroColors.CardDark),
    onPrimaryContainer = GiroColors.TextDark,
    secondary = GiroColors.InflowDark,
    onSecondary = Color(0xFF064E3B),
    secondaryContainer = GiroColors.InflowBadgeDark,
    onSecondaryContainer = GiroColors.InflowDark,
    background = GiroColors.CanvasDark,
    onBackground = GiroColors.TextDark,
    surface = GiroColors.CardDark,
    onSurface = GiroColors.TextDark,
    surfaceVariant = GiroColors.CanvasDark,
    surfaceTint = Color.Transparent,
    surfaceContainer = GiroColors.CardDark,
    surfaceContainerLow = GiroColors.CardDark,
    surfaceContainerHigh = GiroColors.CardDark,
    surfaceContainerHighest = GiroColors.CardDark,
    onSurfaceVariant = GiroColors.SecondaryDark,
    outline = GiroColors.BorderDark,
    outlineVariant = GiroColors.BorderDark,
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
        GiroExtraColors(GiroColors.InflowDark, GiroColors.NegativeDark, scheme.surface, scheme.outline, GiroColors.OutflowDark, GiroColors.TertiaryDark, GiroColors.AccentDark)
    } else {
        GiroExtraColors(GiroColors.Inflow, GiroColors.Negative, scheme.surface, scheme.outline)
    }
    CompositionLocalProvider(LocalGiroColors provides extra) {
        MaterialTheme(colorScheme = scheme, typography = GiroTypography, content = content)
    }
}
