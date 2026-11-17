package de.girocrab.app.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement.spacedBy
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.fillMaxSize
import de.girocrab.app.ui.theme.GiroColors
import de.girocrab.app.ui.theme.LocalGiroColors
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.AppViewModel
import de.girocrab.app.model.Booking
import de.girocrab.app.model.BookingFilter
import de.girocrab.app.model.Direction
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs

// 1:1 with Swift Theme (Formatting.swift): inflow / outflow / accent, see de.girocrab.app.ui.theme.GiroColors.
private val IncomeColor: Color @Composable get() = LocalGiroColors.current.positive
private val ExpenseColor: Color @Composable get() = LocalGiroColors.current.outflow
private val NetColor: Color @Composable get() = LocalGiroColors.current.accent

private data class MonthFlow(val month: YearMonth, val incomeCents: Long, val expenseCents: Long) {
    val netCents get() = incomeCents - expenseCents
}

private data class CategoryShare(val id: String?, val name: String, val color: Color, val cents: Long)

private data class TagStat(
    val id: String,
    val name: String,
    val color: Color,
    val incomeCents: Long,
    val expenseCents: Long,
    val count: Int,
)

/** Bookings in the current scope, ignoring list filters/search (analytics has its own period). */
private fun scopeBookings(s: AppUiState): List<Booking> =
    AppViewModel.filterBookings(s.copy(filter = BookingFilter(), search = ""))

private fun formatEur(cents: Long, hide: Boolean, signed: Boolean = false): String {
    if (hide) return "•••• €"
    val abs = abs(cents)
    val body = String.format(Locale.GERMANY, "%,d,%02d €", abs / 100, abs % 100)
    return when {
        cents < 0 -> "−$body"
        signed && cents > 0 -> "+$body"
        else -> body
    }
}

private fun shortEur(cents: Long): String {
    val v = abs(cents) / 100
    return if (v >= 1000) String.format(Locale.GERMANY, "%.1fk", v / 1000.0) else v.toString()
}

private val IosPalette = listOf(0xFF007AFF, 0xFF5856D6, 0xFF34C759, 0xFFFF9500, 0xFFAF52DE, 0xFF5AC8FA).map { Color(it) }
private fun parseColor(hex: Long) = Color(hex)
private fun paletteColor(i: Int) = IosPalette[i % IosPalette.size]

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AnalyticsScreen(
    state: AppUiState,
    vm: AppViewModel,
    /** Called after a tap-to-filter so the host can switch to the booking list. */
    onShowBookings: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var months by rememberSaveable { mutableIntStateOf(6) }
    val hide = state.privacyMode

    val today = remember { LocalDate.now() }
    val periodStart = remember(months) { YearMonth.from(today).minusMonths((months - 1).toLong()).atDay(1) }
    val all = remember(state.data, state.scope) { scopeBookings(state) }
    val inPeriod = remember(all, periodStart) { all.filter { !it.bookingDate.isBefore(periodStart) } }

    val monthly = remember(inPeriod, months) {
        val cur = YearMonth.from(today)
        (months - 1 downTo 0).map { back ->
            val ym = cur.minusMonths(back.toLong())
            val bs = inPeriod.filter { YearMonth.from(it.bookingDate) == ym }
            MonthFlow(
                ym,
                bs.filter { it.amountCents > 0 }.sumOf { it.amountCents },
                -bs.filter { it.amountCents < 0 }.sumOf { it.amountCents },
            )
        }
    }

    val categories = remember(inPeriod, state.data.categories) {
        val byId = state.data.categories.associateBy { it.id }
        val sums = HashMap<String?, Long>()
        for (b in inPeriod) {
            if (b.amountCents >= 0) continue
            if (b.splits.isEmpty()) {
                sums.merge(b.categoryId, -b.amountCents, Long::plus)
            } else {
                for (p in b.splits) sums.merge(p.categoryId, abs(p.amountCents), Long::plus)
            }
        }
        sums.map { (id, cents) ->
            val c = id?.let { byId[it] }
            CategoryShare(id, c?.name ?: "Ohne Kategorie", Color.Gray, cents)
        }.sortedByDescending { it.cents }.mapIndexed { i, s -> s.copy(color = paletteColor(i)) }
    }

    val tags = remember(inPeriod, state.data.tags) {
        state.data.tags.mapNotNull { t ->
            val bs = inPeriod.filter { t.id in it.tagIds }
            if (bs.isEmpty()) null else TagStat(
                t.id, t.name, parseColor(t.colorHex),
                bs.filter { it.amountCents > 0 }.sumOf { it.amountCents },
                -bs.filter { it.amountCents < 0 }.sumOf { it.amountCents },
                bs.size,
            )
        }.sortedByDescending { it.expenseCents + it.incomeCents }
    }

    LazyColumn(
        modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = spacedBy(16.dp),
    ) {
        item {
            val opts = listOf(3, 6, 12)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                opts.forEachIndexed { i, m ->
                    SegmentedButton(
                        selected = months == m,
                        onClick = { months = m },
                        shape = SegmentedButtonDefaults.itemShape(i, opts.size, RoundedCornerShape(8.dp)),
                        colors = SegmentedButtonDefaults.colors(
                            activeContainerColor = MaterialTheme.colorScheme.surface,
                            activeContentColor = MaterialTheme.colorScheme.onSurface,
                            activeBorderColor = MaterialTheme.colorScheme.outline,
                            inactiveContainerColor = MaterialTheme.colorScheme.background,
                            inactiveContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            inactiveBorderColor = MaterialTheme.colorScheme.outline,
                        ),
                        icon = {},
                    ) { Text("$m Monate", style = MaterialTheme.typography.labelLarge) }
                }
            }
        }
        item {
            val inc = monthly.sumOf { it.incomeCents }
            val exp = monthly.sumOf { it.expenseCents }
            Card(
                Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = spacedBy(12.dp)) {
                    Text("Einnahmen & Ausgaben", style = MaterialTheme.typography.titleMedium)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        SummaryCell("Einnahmen", formatEur(inc, hide), IncomeColor)
                        SummaryCell("Ausgaben", formatEur(-exp, hide), ExpenseColor)
                        SummaryCell("Netto", formatEur(inc - exp, hide, signed = true), NetColor)
                    }
                    CashflowChart(monthly, hide)
                    run {
                        val rate = if (inc > 0) ((inc - exp) * 100f / inc) else 0f
                        androidx.compose.material3.Surface(
                            color = MaterialTheme.colorScheme.secondaryContainer,
                            shape = RoundedCornerShape(50),
                        ) {
                            Text(
                                "Sparen & Investieren vs. Konsum (#614): Sparquote " +
                                    (if (hide) "•••" else "%.0f %%".format(Locale.GERMANY, rate)),
                                Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                    Row(horizontalArrangement = spacedBy(16.dp)) {
                        LegendDot(IncomeColor, "Einnahmen")
                        LegendDot(ExpenseColor, "Ausgaben")
                        LegendDot(NetColor, "Netto")
                    }
                }
            }
        }
        item {
            Card(
                Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = spacedBy(10.dp)) {
                    Text("Ausgaben nach Kategorie", style = MaterialTheme.typography.titleMedium)
                    val total = categories.sumOf { it.cents }
                    if (categories.isEmpty()) {
                        Text("Keine Ausgaben im Zeitraum", style = MaterialTheme.typography.bodyMedium)
                    }
                    categories.forEach { c ->
                        ShareRow(
                            name = c.name,
                            color = c.color,
                            fraction = if (total > 0) c.cents.toFloat() / total else 0f,
                            amount = formatEur(-c.cents, hide),
                            onClick = {
                                vm.setFilter(
                                    BookingFilter(
                                        direction = Direction.Expense,
                                        categoryId = c.id,
                                        uncategorizedOnly = c.id == null,
                                        from = periodStart,
                                    ),
                                )
                                onShowBookings()
                            },
                        )
                    }
                }
            }
        }
        item {
            var prorate by rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
            val budgets = remember { androidx.compose.runtime.mutableStateMapOf("Lebensmittel" to 45000L, "Restaurants" to 15000L, "Freizeit" to 20000L) }
            var editing by remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
            var newName by remember { androidx.compose.runtime.mutableStateOf("") }
            var editText by remember { androidx.compose.runtime.mutableStateOf("") }
            val curMonth = YearMonth.from(today)
            val spent = remember(all) {
                all.filter { it.amountCents < 0 && YearMonth.from(it.bookingDate) == curMonth }
            }
            val catNames = remember(state.data.categories) { state.data.categories.associate { it.id to it.name } }
            val income = monthly.lastOrNull()?.incomeCents ?: 0L
            val expense = monthly.lastOrNull()?.expenseCents ?: 0L
            Card(
                Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = spacedBy(10.dp)) {
                    Text("Monatsbudgets & Sparquote", style = MaterialTheme.typography.titleMedium)
                    val rate = if (income > 0) (income - expense) * 100f / income else 0f
                    Text(
                        "Sparquote diesen Monat: " + (if (hide) "•••" else "%.0f %%".format(Locale.GERMANY, rate)),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    budgets.entries.sortedBy { it.key }.forEach { (name, limit) ->
                        val used = spent.filter { (catNames[it.categoryId] ?: "").equals(name, ignoreCase = true) }.sumOf { -it.amountCents }
                            .let { if (it == 0L && !prorate && spent.isEmpty()) 0L else it }
                        val frac = if (limit > 0) used.toFloat() / limit else 0f
                        val col = if (frac > 1f) ExpenseColor else if (frac > 0.85f) Color(0xFFFF9500) else IncomeColor
                        Column(Modifier.clickable { editing = name; editText = (limit / 100).toString() }) {
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(name, style = MaterialTheme.typography.bodyMedium)
                                Text("${formatEur(used, hide)} / ${formatEur(limit, hide)}", style = MaterialTheme.typography.bodySmall, color = col)
                            }
                            ShareBar(frac, col)
                        }
                    }
                    androidx.compose.material3.TextButton(onClick = { editing = "Neues Budget"; editText = "100" }) {
                        Text("Budget hinzufügen / ändern")
                    }
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Jahreszahlungen anteilig umlegen (1/12, #253)", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        androidx.compose.material3.Switch(prorate, { prorate = it })
                    }
                }
            }
            editing?.let { key ->
                androidx.compose.material3.AlertDialog(
                    onDismissRequest = { editing = null },
                    title = { Text(if (key == "Neues Budget") "Budget hinzufügen" else "Limit für $key (€)") },
                    text = {
                        Column {
                            if (key == "Neues Budget") {
                                androidx.compose.material3.OutlinedTextField(
                                    value = newName, onValueChange = { newName = it }, label = { Text("Kategorie") }, singleLine = true,
                                )
                            }
                            androidx.compose.material3.OutlinedTextField(
                                value = editText, onValueChange = { editText = it }, label = { Text("Limit pro Monat (€)") }, singleLine = true,
                            )
                        }
                    },
                    confirmButton = {
                        androidx.compose.material3.TextButton(onClick = {
                            val v = editText.replace(',', '.').toDoubleOrNull()
                            val name = if (key == "Neues Budget") newName.trim() else key
                            if (v != null && name.isNotEmpty()) budgets[name] = (v * 100).toLong()
                            editing = null; newName = ""
                        }) { Text("Speichern") }
                    },
                    dismissButton = { androidx.compose.material3.TextButton(onClick = { editing = null }) { Text("Abbrechen") } },
                )
            }
        }
        item {
            Card(
                Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = spacedBy(10.dp)) {
                    Text("Auswertung nach Tags", style = MaterialTheme.typography.titleMedium)
                    if (tags.isEmpty()) {
                        Text("Keine getaggten Buchungen im Zeitraum", style = MaterialTheme.typography.bodyMedium)
                    } else {
                        val totalIn = tags.sumOf { it.incomeCents }
                        val totalOut = tags.sumOf { it.expenseCents }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            SummaryCell("Einnahmen", formatEur(totalIn, hide), IncomeColor)
                            SummaryCell("Ausgaben", formatEur(-totalOut, hide), ExpenseColor)
                            SummaryCell("Buchungen", tags.sumOf { it.count }.toString(), MaterialTheme.colorScheme.onSurface)
                        }
                    }
                }
            }
        }
        items(tags, key = { it.id }) { t ->
            val totalOut = tags.sumOf { it.expenseCents }
            Card(
                Modifier.fillMaxWidth().clickable {
                    vm.setFilter(BookingFilter(tagId = t.id, from = periodStart))
                    onShowBookings()
                },
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(10.dp).background(t.color, CircleShape))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "#${t.name}",
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.titleSmall,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text("${t.count} Buchungen", style = MaterialTheme.typography.labelMedium)
                    }
                    ShareBar(if (totalOut > 0) t.expenseCents.toFloat() / totalOut else 0f, t.color)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("+ ${formatEur(t.incomeCents, hide)}", color = IncomeColor, style = MaterialTheme.typography.bodySmall)
                        Text(formatEur(-t.expenseCents, hide), color = ExpenseColor, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun SummaryCell(label: String, value: String, color: Color) {
    Column {
        Text(label, style = MaterialTheme.typography.labelSmall)
        Text(value, color = color, style = MaterialTheme.typography.titleSmall, maxLines = 1)
    }
}

@Composable
private fun LegendDot(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Spacer(Modifier.width(4.dp))
        Text(label, style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun ShareBar(fraction: Float, color: Color) {
    val track = MaterialTheme.colorScheme.surfaceVariant
    Box(Modifier.fillMaxWidth().height(8.dp).background(track, RoundedCornerShape(4.dp))) {
        Box(
            Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(8.dp)
                .background(color, RoundedCornerShape(4.dp)),
        )
    }
}

@Composable
private fun ShareRow(name: String, color: Color, fraction: Float, amount: String, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick), verticalArrangement = spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(color, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${(fraction * 100).toInt()} %", style = MaterialTheme.typography.labelMedium)
            Spacer(Modifier.width(12.dp))
            Text(amount, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
        }
        ShareBar(fraction, color)
    }
}

/** Grouped income/expense bars per month plus a net-cashflow trend line. */
@Composable
private fun CashflowChart(data: List<MonthFlow>, hide: Boolean) {
    val axis = MaterialTheme.colorScheme.outlineVariant
    val labelColor = MaterialTheme.colorScheme.onSurfaceVariant
    val incomeBar = IncomeColor.copy(alpha = GiroColors.BarAlpha)
    val expenseBar = ExpenseColor.copy(alpha = GiroColors.BarAlpha)
    val netColor = NetColor.copy(alpha = 0.8f)
    val gridColor = LocalGiroColors.current.tertiary.copy(alpha = 0.45f)
    val pointFill = MaterialTheme.colorScheme.surface
    val maxVal = (data.maxOfOrNull { maxOf(it.incomeCents, it.expenseCents) } ?: 0L).coerceAtLeast(1L)
    val minNet = (data.minOfOrNull { it.netCents } ?: 0L).coerceAtMost(0L)

    Column {
        Canvas(Modifier.fillMaxWidth().height(180.dp)) {
            if (hide || data.isEmpty()) {
                drawRect(axis.copy(alpha = 0.3f), size = size)
                return@Canvas
            }
            val range = (maxVal - minNet).toFloat()
            fun y(v: Long) = size.height * (1f - (v - minNet) / range)
            val zeroY = y(0)
            val slot = size.width / data.size
            val barW = slot * 0.26f

            for (g in 1..3) {
                val gy = size.height * g / 4f
                drawLine(gridColor, Offset(0f, gy), Offset(size.width, gy), strokeWidth = 1.dp.toPx(), pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
            }
            drawLine(axis, Offset(0f, zeroY), Offset(size.width, zeroY), strokeWidth = 2f)

            data.forEachIndexed { i, m ->
                val cx = slot * i + slot / 2
                val incTop = y(m.incomeCents)
                drawRoundRect(incomeBar, Offset(cx - barW - 4.dp.toPx() / 2, incTop), Size(barW, (zeroY - incTop).coerceAtLeast(0f)), CornerRadius(1.5.dp.toPx()))
                val expTop = y(m.expenseCents)
                drawRoundRect(expenseBar, Offset(cx + 4.dp.toPx() / 2, expTop), Size(barW, (zeroY - expTop).coerceAtLeast(0f)), CornerRadius(1.5.dp.toPx()))
            }

            val path = Path()
            data.forEachIndexed { i, m ->
                val p = Offset(slot * i + slot / 2, y(m.netCents))
                if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
            }
            drawPath(path, netColor, style = Stroke(width = 5f, cap = StrokeCap.Round))
            data.forEachIndexed { i, m ->
                drawCircle(pointFill, 10f, Offset(slot * i + slot / 2, y(m.netCents)))
                drawCircle(netColor, 7f, Offset(slot * i + slot / 2, y(m.netCents)))
            }
        }
        Row(Modifier.fillMaxWidth()) {
            data.forEach { m ->
                Text(
                    m.month.month.getDisplayName(TextStyle.SHORT, Locale.GERMANY),
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.labelSmall,
                    color = labelColor,
                    maxLines = 1,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
        if (!hide && data.isNotEmpty()) {
            Text(
                "Max. ${shortEur(maxVal)} € pro Monat",
                style = MaterialTheme.typography.labelSmall,
                color = labelColor,
            )
        }
    }
}
