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

private val IncomeColor = Color(0xFF2E7D32)
private val ExpenseColor = Color(0xFFC62828)
private val NetColor = Color(0xFF1565C0)

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

private fun parseColor(hex: Long) = Color(hex)

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
            CategoryShare(id, c?.name ?: "Ohne Kategorie", c?.let { parseColor(it.colorHex) } ?: Color.Gray, cents)
        }.sortedByDescending { it.cents }
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
            Row(horizontalArrangement = spacedBy(8.dp)) {
                listOf(3, 6, 12).forEach { m ->
                    FilterChip(selected = months == m, onClick = { months = m }, label = { Text("$m Monate") })
                }
            }
        }
        item {
            val inc = monthly.sumOf { it.incomeCents }
            val exp = monthly.sumOf { it.expenseCents }
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = spacedBy(12.dp)) {
                    Text("Einnahmen & Ausgaben", style = MaterialTheme.typography.titleMedium)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        SummaryCell("Einnahmen", formatEur(inc, hide), IncomeColor)
                        SummaryCell("Ausgaben", formatEur(-exp, hide), ExpenseColor)
                        SummaryCell("Netto", formatEur(inc - exp, hide, signed = true), NetColor)
                    }
                    CashflowChart(monthly, hide)
                    Row(horizontalArrangement = spacedBy(16.dp)) {
                        LegendDot(IncomeColor, "Einnahmen")
                        LegendDot(ExpenseColor, "Ausgaben")
                        LegendDot(NetColor, "Netto")
                    }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
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
            Card(Modifier.fillMaxWidth()) {
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
            val barW = slot * 0.3f

            drawLine(axis, Offset(0f, zeroY), Offset(size.width, zeroY), strokeWidth = 2f)

            data.forEachIndexed { i, m ->
                val cx = slot * i + slot / 2
                val incTop = y(m.incomeCents)
                drawRect(IncomeColor, Offset(cx - barW - 1f, incTop), Size(barW, zeroY - incTop))
                val expTop = y(m.expenseCents)
                drawRect(ExpenseColor, Offset(cx + 1f, expTop), Size(barW, zeroY - expTop))
            }

            val path = Path()
            data.forEachIndexed { i, m ->
                val p = Offset(slot * i + slot / 2, y(m.netCents))
                if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
            }
            drawPath(path, NetColor, style = Stroke(width = 5f, cap = StrokeCap.Round))
            data.forEachIndexed { i, m ->
                drawCircle(NetColor, 7f, Offset(slot * i + slot / 2, y(m.netCents)))
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
