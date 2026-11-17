package de.girocrab.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.girocrab.app.model.Account
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.Booking
import de.girocrab.app.model.BookingFilter
import de.girocrab.app.model.Category
import de.girocrab.app.model.Direction
import de.girocrab.app.model.Scope
import de.girocrab.app.model.Tag
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs

enum class TimeRange(val label: String) {
    All("Gesamter Zeitraum"), Days30("30 Tage"), Days90("90 Tage"), ThisYear("Dieses Jahr");

    fun from(today: LocalDate): LocalDate? = when (this) {
        All -> null
        Days30 -> today.minusDays(30)
        Days90 -> today.minusDays(90)
        ThisYear -> today.withDayOfYear(1)
    }
}

enum class FlowFilter(val label: String) {
    All("Alle"), Unchecked("Ungeprüft"), Expenses("Ausgaben"), Income("Einnahmen")
}

private val DE: Locale = Locale.GERMANY
private val dayFmt: DateTimeFormatter = DateTimeFormatter.ofPattern("dd.MM.", DE)
private val tabular = FontFamily.Default
private val tnum = androidx.compose.ui.text.TextStyle(fontFeatureSettings = "tnum")

private fun color(hex: Long) = Color(hex)

/** Pure grouping helper: newest month first, subtotals per month. */
data class MonthGroup(val month: YearMonth, val income: Long, val expense: Long, val items: List<Booking>)

fun groupByMonth(bookings: List<Booking>): List<MonthGroup> =
    bookings.groupBy { YearMonth.from(it.bookingDate) }
        .toSortedMap(compareByDescending { it })
        .map { (m, l) ->
            MonthGroup(
                m,
                l.filter { it.amountCents > 0 }.sumOf { it.amountCents },
                l.filter { it.amountCents < 0 }.sumOf { it.amountCents },
                l,
            )
        }

/**
 * Booking stream: balance header, filter bar and month-grouped list.
 *
 * @param bookings pre-filtered by scope/search/filter (AppViewModel.visibleBookings)
 */
@Composable
fun BookingStreamScreen(
    state: AppUiState,
    bookings: List<Booking>,
    onSearch: (String) -> Unit,
    onFilter: (BookingFilter) -> Unit,
    onFetch: () -> Unit = {},
    onNewTransfer: () -> Unit = {},
    onAccountSettings: () -> Unit = {},
    onOpenBooking: (Booking) -> Unit = {},
    onToggleChecked: (String) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val masked = state.privacyMode
    var range by rememberSaveable { mutableStateOf(TimeRange.All) }
    var flow by rememberSaveable { mutableStateOf(FlowFilter.All) }
    var docsOnly by rememberSaveable { mutableStateOf(false) }
    var analytics by rememberSaveable { mutableStateOf(false) }

    val shown = bookings
        .filter { b ->
            when (flow) {
                FlowFilter.All -> true
                FlowFilter.Unchecked -> !b.checked
                FlowFilter.Expenses -> b.amountCents < 0
                FlowFilter.Income -> b.amountCents > 0
            }
        }
        .filter { !docsOnly || it.documentCount > 0 }
    val groups = remember(shown) { groupByMonth(shown) }
    val data = state.data

    LazyColumn(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        item {
            BalanceHeaderCard(
                state = state,
                masked = masked,
                onFetch = onFetch,
                onNewTransfer = onNewTransfer,
                onAccountSettings = onAccountSettings,
            )
        }
        item {
            FilterBar(
                search = state.search,
                onSearch = onSearch,
                range = range,
                onRange = {
                    range = it
                    onFilter(state.filter.copy(from = it.from(LocalDate.now()), to = null))
                },
                flow = flow,
                onFlow = {
                    flow = it
                    onFilter(
                        state.filter.copy(
                            direction = when (it) {
                                FlowFilter.Expenses -> Direction.Expense
                                FlowFilter.Income -> Direction.Income
                                else -> Direction.Any
                            },
                        ),
                    )
                },
                categories = data.categories,
                categoryId = state.filter.categoryId,
                onCategory = { onFilter(state.filter.copy(categoryId = it)) },
                tags = data.tags,
                tagId = state.filter.tagId,
                onTag = { onFilter(state.filter.copy(tagId = it)) },
                docsOnly = docsOnly,
                onDocs = { docsOnly = it },
                analytics = analytics,
                onAnalytics = { analytics = it },
                count = shown.size,
            )
        }
        item {
            AnimatedVisibility(analytics) { AnalyticsPanel(shown, data.categories, masked) }
        }
        if (groups.isEmpty()) {
            item {
                Text(
                    if (state.search.isEmpty()) "Konto abrufen oder anderen Zeitraum wählen." else "Nichts gefunden.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(24.dp),
                )
            }
        }
        groups.forEach { g ->
            item(key = "h_${g.month}") { MonthHeader(g, masked) }
            items(g.items, key = { it.id }) { b ->
                BookingRow(
                    booking = b,
                    category = data.categories.firstOrNull { it.id == b.categoryId },
                    tags = data.tags.filter { it.id in b.tagIds },
                    unchecked = !b.checked,
                    hasDocument = b.documentCount > 0,
                    masked = masked,
                    onToggleChecked = { onToggleChecked(b.id) },
                    onClick = { onOpenBooking(b) },
                )
            }
        }
    }
}

@Composable
fun BalanceHeaderCard(
    state: AppUiState,
    masked: Boolean,
    onFetch: () -> Unit,
    onNewTransfer: () -> Unit,
    onAccountSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val data = state.data
    val account: Account? = state.selectedAccountId?.let { id -> data.accounts.firstOrNull { it.id == id } }
    val title = when (val s = state.scope) {
        Scope.All -> "Alle Konten"
        is Scope.Group -> data.groups.firstOrNull { it.id == s.groupId }?.name ?: "Gruppe"
        is Scope.OneAccount -> account?.name ?: "Konto"
    }
    val subtitle = when {
        account != null -> listOfNotNull(account.bankName, account.iban?.let { maskIban(it, masked) }).joinToString(" · ")
        else -> "${state.scopedAccountIds.size} Konten"
    }
    Card(
        modifier.fillMaxWidth().padding(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                formatMoney(state.totalBalanceCents, masked = masked),
                style = MaterialTheme.typography.headlineMedium.copy(fontFeatureSettings = "tnum"),
                fontFamily = tabular,
                fontWeight = FontWeight.Bold,
            )
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = onFetch,
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0067C0), contentColor = Color.White),
                ) {
                    Icon(Icons.Filled.Sync, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Jetzt abrufen")
                }
                FilledTonalButton(
                    onClick = onNewTransfer,
                    colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFFE8F1FB), contentColor = Color(0xFF004E8C)),
                ) {
                    Icon(Icons.Filled.Send, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Neue Überweisung")
                }
                if (account != null) {
                    FilledTonalButton(onClick = onAccountSettings) {
                        Icon(Icons.Filled.Settings, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Kontoeinstellungen")
                    }
                }
            }
        }
    }
}

private fun maskIban(iban: String, masked: Boolean): String =
    if (masked) "•••• •••• ${iban.takeLast(4)}" else iban.chunked(4).joinToString(" ")

@Composable
private fun FilterBar(
    search: String,
    onSearch: (String) -> Unit,
    range: TimeRange,
    onRange: (TimeRange) -> Unit,
    flow: FlowFilter,
    onFlow: (FlowFilter) -> Unit,
    categories: List<Category>,
    categoryId: String?,
    onCategory: (String?) -> Unit,
    tags: List<Tag>,
    tagId: String?,
    onTag: (String?) -> Unit,
    docsOnly: Boolean,
    onDocs: (Boolean) -> Unit,
    analytics: Boolean,
    onAnalytics: (Boolean) -> Unit,
    count: Int,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OutlinedTextField(
            value = search,
            onValueChange = onSearch,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            placeholder = { Text("Suchen") },
            leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = {
                if (search.isNotEmpty()) IconButton({ onSearch("") }) { Icon(Icons.Filled.Close, "Suche löschen") }
            },
            keyboardOptions = KeyboardOptions.Default,
        )
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DropdownChip(range.label, TimeRange.entries.map { it.label to { onRange(it) } }, selected = range != TimeRange.All)
            DropdownChip(flow.label, FlowFilter.entries.map { it.label to { onFlow(it) } }, selected = flow != FlowFilter.All)
            val cat = categories.firstOrNull { it.id == categoryId }
            DropdownChip(
                cat?.name ?: "Kategorie",
                listOf("Alle Kategorien" to { onCategory(null) }) + categories.map { c -> c.name to { onCategory(c.id) } },
                selected = cat != null,
            )
            tags.forEach { t ->
                FilterChip(
                    selected = tagId == t.id,
                    onClick = { onTag(if (tagId == t.id) null else t.id) },
                    label = { Text("#${t.name}") },
                )
            }
            FilterChip(
                selected = docsOnly,
                onClick = { onDocs(!docsOnly) },
                label = { Text("Dokumente") },
                leadingIcon = { Icon(Icons.Filled.AttachFile, null, Modifier.size(16.dp)) },
            )
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            FilterChip(
                selected = analytics,
                onClick = { onAnalytics(!analytics) },
                label = { Text("Analysen") },
                leadingIcon = { Icon(Icons.Filled.Insights, null, Modifier.size(16.dp)) },
            )
            Spacer(Modifier.width(10.dp))
            Text(
                if (count == 1) "1 Buchung" else "$count Buchungen",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DropdownChip(label: String, options: List<Pair<String, () -> Unit>>, selected: Boolean) {
    var open by remember { mutableStateOf(false) }
    Box {
        AssistChip(
            onClick = { open = true },
            label = { Text(label, maxLines = 1) },
            trailingIcon = { Icon(Icons.Filled.ArrowDropDown, null, Modifier.size(18.dp)) },
            border = if (selected) androidx.compose.material3.AssistChipDefaults.assistChipBorder(
                enabled = true, borderColor = MaterialTheme.colorScheme.primary,
            ) else androidx.compose.material3.AssistChipDefaults.assistChipBorder(enabled = true),
        )
        DropdownMenu(open, { open = false }) {
            options.forEach { (text, action) ->
                DropdownMenuItem(text = { Text(text) }, onClick = { open = false; action() })
            }
        }
    }
}

@Composable
private fun AnalyticsPanel(bookings: List<Booking>, categories: List<Category>, masked: Boolean) {
    val income = bookings.filter { it.amountCents > 0 }.sumOf { it.amountCents }
    val expense = bookings.filter { it.amountCents < 0 }.sumOf { it.amountCents }
    val top = bookings.filter { it.amountCents < 0 }
        .groupBy { it.categoryId }
        .mapValues { -it.value.sumOf { b -> b.amountCents } }
        .entries.sortedByDescending { it.value }.take(5)
    Card(Modifier.fillMaxWidth().padding(12.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SumRow("Einnahmen", income, masked)
            SumRow("Ausgaben", expense, masked)
            SumRow("Saldo", income + expense, masked)
            if (top.isNotEmpty()) {
                Text("Top-Kategorien", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 6.dp))
                val max = top.first().value.coerceAtLeast(1)
                top.forEach { (id, cents) ->
                    val c = categories.firstOrNull { it.id == id }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(c?.name ?: "Ohne Kategorie", Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp)
                        Box(
                            Modifier.width((90f * cents / max).dp.coerceAtLeast(2.dp)).size(width = 90.dp, height = 6.dp)
                                .clip(RoundedCornerShape(3.dp)).background(color(c?.colorHex ?: 0xFF9E9E9E)),
                        )
                        Text(formatMoney(cents, masked = masked), Modifier.width(90.dp), fontFamily = tabular, style = tnum, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun SumRow(label: String, cents: Long, masked: Boolean) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(formatMoney(cents, masked = masked), fontFamily = tabular, style = tnum, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun MonthHeader(g: MonthGroup, masked: Boolean) {
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "${g.month.month.getDisplayName(TextStyle.FULL, DE)} ${g.month.year}",
            Modifier.weight(1f),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
        )
        Text(formatMoney(g.income, masked = masked), fontFamily = tabular, style = tnum, fontSize = 12.sp, color = Color(0xFF2E7D32))
        Spacer(Modifier.width(10.dp))
        Text(formatMoney(g.expense, masked = masked), fontFamily = tabular, style = tnum, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun BookingRow(
    booking: Booking,
    category: Category?,
    tags: List<Tag>,
    unchecked: Boolean,
    hasDocument: Boolean,
    masked: Boolean,
    onToggleChecked: () -> Unit,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.size(32.dp).clickable(onClick = onToggleChecked), contentAlignment = Alignment.Center) {
            if (unchecked) Box(Modifier.size(10.dp).clip(CircleShape).background(Color(0xFF1E88E5)))
        }
        Column(Modifier.weight(1f).padding(end = 8.dp)) {
            Text(
                if (masked) "••••••" else booking.counterparty.ifBlank { "—" },
                fontWeight = if (unchecked) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (booking.purpose.isNotBlank()) {
                Text(
                    if (masked) "••••••••••" else booking.purpose,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
            }
            Row(
                Modifier.padding(top = 4.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(booking.bookingDate.format(dayFmt), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (category != null) Pill(category.name, color(category.colorHex))
                tags.forEach { Pill("#${it.name}", color(it.colorHex)) }
                if (hasDocument) Icon(Icons.Filled.AttachFile, "Dokument", Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Text(
            formatMoney(booking.amountCents, booking.currency, masked),
            fontFamily = tabular, style = tnum,
            fontWeight = FontWeight.Medium,
            color = if (booking.amountCents > 0) Color(0xFF2E7D32) else MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            softWrap = false,
        )
    }
}

@Composable
private fun Pill(text: String, tint: Color) {
    Text(
        text,
        fontSize = 11.sp,
        maxLines = 1,
        color = tint,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(tint.copy(alpha = 0.15f)).padding(horizontal = 8.dp, vertical = 2.dp),
    )
}
