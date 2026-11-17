package de.girocrab.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AccountBalance
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.EventRepeat
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.FiberNew
import androidx.compose.material.icons.filled.Money
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.RequestQuote
import androidx.compose.material.icons.filled.Savings
import androidx.compose.material.icons.filled.ShowChart
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material.icons.filled.Wallet
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.girocrab.app.model.Account
import de.girocrab.app.model.AccountGroup
import de.girocrab.app.model.AccountKind
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.Booking
import de.girocrab.app.model.Holding
import de.girocrab.app.model.ConnectorKind
import java.text.NumberFormat
import java.util.Currency
import java.time.LocalDate
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

/** Sidebar destinations shown as scope cards (mirrors SidebarView). */
enum class ScopeCardKind(val title: String, val icon: ImageVector) {
    AllAccounts("Alle Konten", Icons.Default.AccountBalance),
    NetWorth("Vermögen", Icons.Default.TrendingUp),
    Depot("Depot / Wertpapiere", Icons.Default.ShowChart),
    Unread("Neu / Ungelesen", Icons.Default.FiberNew),
    Contracts("Verträge & Abos", Icons.Default.Autorenew),
    Planned("Geplante Zahlungen", Icons.Default.EventRepeat),
    DirectDebits("Lastschriften", Icons.Default.Payments),
    Documents("Dokumente", Icons.Default.Description),
}

/** Counters not derivable from the base snapshot; supplied by the caller (defaults = no badge). */
data class AccountsBadges(
    val unreadBookings: Int = 0,
    val documents: Int = 0,
    val contracts: Int = 0,
    val plannedPayments: Int = 0,
    val directDebits: Int = 0,
    val unreadByAccount: Map<String, Int> = emptyMap(),
    val documentsByAccount: Map<String, Int> = emptyMap(),
)

fun formatMoney(cents: Long, currency: String = "EUR", masked: Boolean = false): String {
    if (masked) return "••••"
    val nf = NumberFormat.getCurrencyInstance(Locale.GERMANY)
    runCatching { nf.currency = Currency.getInstance(currency) }
    return nf.format(cents / 100.0).replace('\u00A0', ' ').replace('\u202F', ' ')
}

fun accountKindLabel(k: AccountKind) = when (k) {
    AccountKind.Giro -> "Girokonto"
    AccountKind.Savings -> "Sparkonto"
    AccountKind.CreditCard -> "Kreditkarte"
    AccountKind.Depot -> "Depot"
    AccountKind.Loan -> "Kredit"
    AccountKind.Wallet -> "Wallet"
    AccountKind.Cash -> "Bargeld"
}

fun accountKindIcon(k: AccountKind): ImageVector = when (k) {
    AccountKind.Giro -> Icons.Default.AccountBalance
    AccountKind.Savings -> Icons.Default.Savings
    AccountKind.CreditCard -> Icons.Default.CreditCard
    AccountKind.Depot -> Icons.Default.ShowChart
    AccountKind.Loan -> Icons.Default.RequestQuote
    AccountKind.Wallet -> Icons.Default.Wallet
    AccountKind.Cash -> Icons.Default.Money
}

/** Pure composition of the net worth figures, kept out of the UI for testability. */
data class WealthBreakdown(
    val cash: Long,
    val depot: Long,
    val tangibles: Long,
    val loans: Long,
    val creditCards: Long,
) {
    val assets get() = cash + depot + tangibles
    val liabilities get() = loans + creditCards
    val net get() = assets - liabilities
}

fun wealthBreakdown(s: AppUiState): WealthBreakdown {
    val d = s.data
    val visible = d.accounts.filterNot { it.hidden }
    fun sumOf(vararg kinds: AccountKind) =
        visible.filter { it.kind in kinds }.sumOf { it.balanceCents }
    val depotFromHoldings = d.holdings.sumOf { it.valueCents }
    val depotAccounts = sumOf(AccountKind.Depot)
    val cards = sumOf(AccountKind.CreditCard)
    val loanAccounts = sumOf(AccountKind.Loan)
    return WealthBreakdown(
        cash = sumOf(AccountKind.Giro, AccountKind.Savings, AccountKind.Wallet, AccountKind.Cash),
        depot = if (depotFromHoldings > 0) depotFromHoldings else depotAccounts,
        tangibles = d.assets.sumOf { it.valueCents },
        loans = d.loans.sumOf { it.remainingCents } + abs(loanAccounts),
        creditCards = if (cards < 0) -cards else 0L,
    )
}

@Composable
fun AccountsAndWealthScreen(
    state: AppUiState,
    badges: AccountsBadges = AccountsBadges(),
    onSelectScope: (ScopeCardKind) -> Unit = {},
    onSelectGroup: (String) -> Unit = {},
    onSelectAccount: (String) -> Unit = {},
    onSync: (Account) -> Unit = {},
    /** #81/#813: persists a manual booking on an offline / cash account (amount signed, cents). */
    onAddManualBooking: (Booking) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val masked = state.privacyMode
    var showWealth by rememberSaveable { mutableStateOf(false) }
    val wealth = remember(state.data) { wealthBreakdown(state) }
    val collapsed = remember { mutableStateOf(setOf<String>()) }
    var showDepot by rememberSaveable { mutableStateOf(false) }
    var manualDialog by rememberSaveable { mutableStateOf(false) }
    val cashAccounts = state.data.accounts.filter { it.kind == AccountKind.Cash || it.kind == AccountKind.Wallet }

    LazyColumn(
        modifier = modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { ScopeGrid(state, badges, wealth, masked) { kind ->
            if (kind == ScopeCardKind.NetWorth) showWealth = !showWealth
            if (kind == ScopeCardKind.Depot) showDepot = !showDepot
            onSelectScope(kind)
        } }
        if (showWealth) item { WealthOverview(wealth, masked) }
        if (showDepot) item { DepotSection(state.data.holdings, masked) }

        if (cashAccounts.isNotEmpty()) item {
            Button(onClick = { manualDialog = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Default.Add, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text("+ Manuelle Buchung / Saldokorrektur")
            }
        }

        item { SectionTitle("Konten") }
        val visibleAccounts = state.data.accounts.filterNot { it.hidden }
        val groups = state.data.groups
        items(groups, key = { it.id }) { g ->
            val accs = visibleAccounts.filter { it.groupId == g.id }
            if (accs.isNotEmpty()) {
                AccountGroupSection(
                    group = g,
                    accounts = accs,
                    open = g.id !in collapsed.value,
                    badges = badges,
                    masked = masked,
                    onToggle = {
                        collapsed.value = if (g.id in collapsed.value) collapsed.value - g.id else collapsed.value + g.id
                    },
                    onSelectGroup = { onSelectGroup(g.id) },
                    onSelectAccount = { id ->
                        if (state.data.accounts.firstOrNull { it.id == id }?.kind == AccountKind.Depot) showDepot = true
                        onSelectAccount(id)
                    },
                    onSync = onSync,
                )
            }
        }
        // Accounts whose group is unknown must never disappear.
        val orphans = visibleAccounts.filter { a -> groups.none { it.id == a.groupId } }
        if (orphans.isNotEmpty()) {
            items(orphans, key = { "orphan-${it.id}" }) { a ->
                AccountRow(a, null, badges, masked, { onSelectAccount(a.id) }, { onSync(a) })
            }
        }
    }
    if (manualDialog) {
        ManualBookingDialog(cashAccounts, onDismiss = { manualDialog = false }) {
            onAddManualBooking(it); manualDialog = false
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
}

@Composable
private fun ScopeGrid(
    state: AppUiState,
    badges: AccountsBadges,
    wealth: WealthBreakdown,
    masked: Boolean,
    onClick: (ScopeCardKind) -> Unit,
) {
    val visible = state.data.accounts.filterNot { it.hidden }
    val total = visible.sumOf { it.balanceCents }
    val depotCount = state.data.holdings.size
    fun info(k: ScopeCardKind): Pair<String, Int> = when (k) {
        ScopeCardKind.AllAccounts -> formatMoney(total, masked = masked) to 0
        ScopeCardKind.NetWorth -> formatMoney(wealth.net, masked = masked) to 0
        ScopeCardKind.Depot -> (if (depotCount > 0) "$depotCount Positionen" else formatMoney(wealth.depot, masked = masked)) to 0
        ScopeCardKind.Unread -> (if (badges.unreadBookings > 0) "${badges.unreadBookings} neu" else "Alles gelesen") to badges.unreadBookings
        ScopeCardKind.Contracts -> "${badges.contracts} aktiv" to 0
        ScopeCardKind.Planned -> "${state.data.standingOrders.size + badges.plannedPayments} Zahlungen" to 0
        ScopeCardKind.DirectDebits -> "${state.data.mandates.size.coerceAtLeast(badges.directDebits)} Mandate" to 0
        ScopeCardKind.Documents -> (if (badges.documents > 0) "${badges.documents} Belege" else "Keine Belege") to badges.documents
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ScopeCardKind.entries.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                row.forEach { k ->
                    val (sub, badge) = info(k)
                    ScopeCard(k, sub, badge, Modifier.weight(1f)) { onClick(k) }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ScopeCard(kind: ScopeCardKind, subtitle: String, badge: Int, modifier: Modifier, onClick: () -> Unit) {
    Card(
        modifier = modifier.clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            BadgedBox(badge = { if (badge > 0) Badge { Text(if (badge > 99) "99+" else badge.toString()) } }) {
                Icon(kind.icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            }
            Spacer(Modifier.size(12.dp))
            Column {
                Text(kind.title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun AccountGroupSection(
    group: AccountGroup,
    accounts: List<Account>,
    open: Boolean,
    badges: AccountsBadges,
    masked: Boolean,
    onToggle: () -> Unit,
    onSelectGroup: () -> Unit,
    onSelectAccount: (String) -> Unit,
    onSync: (Account) -> Unit,
) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(1.dp)) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(Color(group.colorHex)))
                Spacer(Modifier.size(8.dp))
                Text(group.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f).clickable(onClick = onSelectGroup), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(formatMoney(accounts.sumOf { it.balanceCents }, masked = masked),
                    style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Icon(if (open) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (open) "Gruppe einklappen" else "Gruppe ausklappen")
            }
            AnimatedVisibility(open) {
                Column {
                    accounts.forEach { a ->
                        AccountRow(a, group, badges, masked, { onSelectAccount(a.id) }, { onSync(a) })
                    }
                }
            }
        }
    }
}

@Composable
private fun AccountRow(
    account: Account,
    group: AccountGroup?,
    badges: AccountsBadges,
    masked: Boolean,
    onClick: () -> Unit,
    onSync: () -> Unit,
) {
    val tint = Color(group?.colorHex ?: 0xFF607D8B)
    val unread = badges.unreadByAccount[account.id] ?: 0
    val docs = badges.documentsByAccount[account.id] ?: 0
    // Subtitle `Kind · Bank · Holder` (#587); holder falls back to the group name.
    val subtitle = listOfNotNull(
        accountKindLabel(account.kind),
        account.bankName.takeIf { it.isNotBlank() },
        account.holder.takeIf { it.isNotBlank() } ?: group?.name?.takeIf { it.isNotBlank() },
    ).joinToString(" · ")
    val canSync = group != null && group.connector != ConnectorKind.Manual && group.connector != ConnectorKind.Import

    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BadgedBox(badge = { if (unread > 0) Badge { Text(unread.toString()) } }) {
            Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center) {
                Icon(accountKindIcon(account.kind), contentDescription = null, tint = tint)
            }
        }
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(account.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (masked) "••••" else subtitle, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (docs > 0) {
            Icon(Icons.Default.Description, contentDescription = "$docs Belege", modifier = Modifier.size(16.dp).alpha(0.6f))
            Text(docs.toString(), style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(start = 2.dp, end = 8.dp))
        }
        val negative = account.balanceCents < 0
        Text(
            formatMoney(account.balanceCents, account.currency, masked),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
            color = if (negative) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        )
        if (canSync) {
            IconButton(onClick = onSync) { Icon(Icons.Default.Sync, contentDescription = "Abrufen") }
        }
    }
}

@Composable
fun WealthOverview(w: WealthBreakdown, masked: Boolean, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionTitle("Vermögen")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            WealthCard("Vermögenswerte", w.assets, Color(0xFF15803D), masked, Modifier.weight(1f))
            WealthCard("Verbindlichkeiten", w.liabilities, Color(0xFFB91C1C), masked, Modifier.weight(1f))
        }
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
            Row(Modifier.fillMaxWidth().padding(14.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Nettovermögen", fontWeight = FontWeight.SemiBold)
                Text(formatMoney(w.net, masked = masked), fontWeight = FontWeight.Bold)
            }
        }
        CompositionBar("Zusammensetzung Vermögen", w.assets, masked, listOf(
            Triple("Konten", w.cash, Color(0xFF1976D2)),
            Triple("Depot", w.depot, Color(0xFF7B1FA2)),
            Triple("Sachwerte", w.tangibles, Color(0xFFF9A825)),
        ))
        CompositionBar("Zusammensetzung Verbindlichkeiten", w.liabilities, masked, listOf(
            Triple("Kredite", w.loans, Color(0xFFB91C1C)),
            Triple("Kreditkarten", w.creditCards, Color(0xFFEF6C00)),
        ))
    }
}

@Composable
private fun WealthCard(title: String, cents: Long, color: Color, masked: Boolean, modifier: Modifier) {
    Card(modifier, colors = CardDefaults.cardColors(containerColor = color.copy(alpha = 0.12f))) {
        Column(Modifier.padding(12.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(formatMoney(cents, masked = masked), style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold, color = color)
        }
    }
}

@Composable
private fun CompositionBar(title: String, total: Long, masked: Boolean, parts: List<Triple<String, Long, Color>>) {
    val shown = parts.filter { it.second > 0 }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        if (shown.isEmpty() || total <= 0) {
            Text("Keine Daten", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            return@Column
        }
        Row(Modifier.fillMaxWidth().height(14.dp).clip(RoundedCornerShape(7.dp))) {
            shown.forEach { (_, v, c) ->
                Box(Modifier.weight(v.toFloat() / total).fillMaxHeight().background(c))
            }
        }
        shown.forEach { (label, v, c) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(c))
                Spacer(Modifier.size(8.dp))
                Text(label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                val pct = if (masked) "" else " · ${(v * 100.0 / total).toInt()} %"
                Text(formatMoney(v, masked = masked) + pct, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}


// ---- Depot value history (#578 / #761 / #829) ----------------------------------------------

private val DepotGreen = Color(0xFF34C759)
private val DepotTeal = Color(0xFF30B0C7)
private val DepotRanges = listOf("1M" to 30, "6M" to 180, "1J" to 365, "Max" to 730)

/**
 * Value curve ending at [endCents]. The snapshot holds no price history, so the curve is
 * interpolated from the cost basis (scaled by the range) with a stable wobble per [seed].
 */
private fun valueCurve(endCents: Long, costCents: Long, days: Int, seed: Int): List<Double> {
    val n = 32
    val gain = (endCents - costCents).toDouble() * (days.coerceAtMost(730) / 730.0)
    val start = endCents - gain
    val amp = abs(endCents.toDouble()) * 0.015
    return List(n) { i ->
        val t = i / (n - 1.0)
        val wobble = if (i == n - 1) 0.0 else kotlin.math.sin(i * 1.7 + seed) * amp * (1 - t)
        start + gain * t + wobble
    }
}

@Composable
private fun ValueChart(values: List<Double>, modifier: Modifier = Modifier) {
    if (values.size < 2) return
    val up = values.last() >= values.first()
    val line = if (up) DepotGreen else DepotTeal
    Canvas(modifier.fillMaxWidth().height(120.dp)) {
        val lo = values.min(); val hi = values.max()
        val span = (hi - lo).takeIf { it > 0 } ?: 1.0
        fun pt(i: Int) = Offset(
            size.width * i / (values.size - 1),
            (size.height * (1 - (values[i] - lo) / span)).toFloat().coerceIn(4f, size.height - 4f),
        )
        val path = Path().apply { moveTo(pt(0).x, pt(0).y); for (i in 1 until values.size) lineTo(pt(i).x, pt(i).y) }
        val fill = Path().apply { addPath(path); lineTo(size.width, size.height); lineTo(0f, size.height); close() }
        drawPath(fill, line.copy(alpha = 0.15f))
        drawPath(path, line, style = Stroke(width = 4f))
    }
}

@Composable
private fun RangeChips(selected: Int, onSelect: (Int) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        DepotRanges.forEachIndexed { i, (label, _) ->
            FilterChip(selected = selected == i, onClick = { onSelect(i) }, label = { Text(label) })
        }
    }
}

@Composable
fun DepotSection(holdings: List<Holding>, masked: Boolean, modifier: Modifier = Modifier) {
    var range by rememberSaveable { mutableStateOf(2) }
    var showSold by rememberSaveable { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(setOf<String>()) }
    val open = holdings.filter { it.quantity > 0 }
    val sold = holdings.filter { it.quantity <= 0 }
    val value = open.sumOf { it.valueCents }
    val cost = open.sumOf { it.costBasisCents }
    val gain = value - cost
    val pct = if (cost > 0) gain * 100.0 / cost else 0.0
    val days = DepotRanges[range].second
    val gainColor = if (gain >= 0) DepotGreen else MaterialTheme.colorScheme.error

    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionTitle("Depot-Wertverlauf")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(1.dp)) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    DepotMetric("Gesamtwert", formatMoney(value, masked = masked), MaterialTheme.colorScheme.onSurface)
                    DepotMetric("Kaufwert", formatMoney(cost, masked = masked), MaterialTheme.colorScheme.onSurface)
                    DepotMetric("GuV", if (masked) "••••" else
                        "${formatMoney(gain)} (%+.1f %%)".format(Locale.GERMANY, pct), gainColor)
                }
                if (!masked) ValueChart(valueCurve(value, cost, days, 7))
                RangeChips(range) { range = it }
            }
        }
        open.forEach { h ->
            val isOpen = h.id in expanded
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(1.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(h.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${h.isin.ifBlank { h.wkn }} · ${if (masked) "••" else "%.4g".format(Locale.GERMANY, h.quantity)} Stk. · " +
                                formatMoney(h.priceCents, h.currency, masked),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text(formatMoney(h.valueCents, masked = masked), fontWeight = FontWeight.Medium)
                            val c = if (h.gainCents >= 0) DepotGreen else MaterialTheme.colorScheme.error
                            Text(if (masked) "••••" else "%+.1f %%".format(Locale.GERMANY, h.gainPct),
                                style = MaterialTheme.typography.labelSmall, color = c,
                                modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(c.copy(alpha = 0.12f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp))
                        }
                        IconButton(onClick = { expanded = if (isOpen) expanded - h.id else expanded + h.id }) {
                            Icon(Icons.Default.ShowChart, contentDescription = "Verlauf anzeigen",
                                tint = if (isOpen) DepotGreen else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    AnimatedVisibility(isOpen && !masked) {
                        Column(Modifier.padding(top = 8.dp)) {
                            ValueChart(valueCurve(h.valueCents, h.costBasisCents, days, h.id.hashCode()))
                            RangeChips(range) { range = it }
                        }
                    }
                }
            }
        }
        // #829: closed positions.
        Row(Modifier.fillMaxWidth().clickable { showSold = !showSold }.padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("Verkaufte Positionen (${sold.size})", style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Icon(if (showSold) Icons.Default.ExpandLess else Icons.Default.ExpandMore, contentDescription = null)
        }
        AnimatedVisibility(showSold) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (sold.isEmpty()) Text("Keine verkauften Positionen", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                sold.forEach { h ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(h.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(h.isin.ifBlank { h.wkn }, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text(formatMoney(h.costBasisCents, masked = masked), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun DepotMetric(label: String, value: String, color: Color) {
    Column {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = color)
    }
}

// ---- Manual booking / balance correction on offline accounts (#81 / #813) ------------------

/** Parses "12,50" / "12.50" / "-3" into cents; null when invalid. */
private fun parseCents(text: String): Long? =
    text.trim().replace(',', '.').toBigDecimalOrNull()?.movePointRight(2)?.toLong()

@Composable
private fun ManualBookingDialog(accounts: List<Account>, onDismiss: () -> Unit, onSave: (Booking) -> Unit) {
    var accountId by remember { mutableStateOf(accounts.first().id) }
    var correction by remember { mutableStateOf(false) }
    var expense by remember { mutableStateOf(true) }
    var amount by remember { mutableStateOf("") }
    var counterparty by remember { mutableStateOf("") }
    var purpose by remember { mutableStateOf("") }
    val account = accounts.first { it.id == accountId }
    val entered = parseCents(amount)
    // Correction: the entered figure is the new balance; the booking is the difference.
    val cents = entered?.let { e ->
        if (correction) e - account.balanceCents else if (expense) -kotlin.math.abs(e) else kotlin.math.abs(e)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Manuelle Buchung / Saldokorrektur") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (accounts.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    accounts.forEach { a ->
                        FilterChip(selected = a.id == accountId, onClick = { accountId = a.id }, label = { Text(a.name) })
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilterChip(selected = !correction && expense, onClick = { correction = false; expense = true }, label = { Text("Ausgabe") })
                    FilterChip(selected = !correction && !expense, onClick = { correction = false; expense = false }, label = { Text("Einnahme") })
                    FilterChip(selected = correction, onClick = { correction = true }, label = { Text("Saldokorrektur") })
                }
                OutlinedTextField(amount, { amount = it },
                    label = { Text(if (correction) "Neuer Saldo (€)" else "Betrag (€)") }, singleLine = true)
                if (correction && cents != null) Text("Buchung: ${formatMoney(cents, account.currency)}",
                    style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(counterparty, { counterparty = it }, label = { Text("Empfänger / Quelle") }, singleLine = true)
                OutlinedTextField(purpose, { purpose = it }, label = { Text("Verwendungszweck") })
            }
        },
        confirmButton = {
            TextButton(enabled = cents != null && cents != 0L, onClick = {
                val today = LocalDate.now()
                onSave(Booking(
                    id = UUID.randomUUID().toString(), accountId = accountId, bookingDate = today,
                    amountCents = cents ?: return@TextButton,
                    counterparty = counterparty.ifBlank { if (correction) "Saldokorrektur" else "Barzahlung" },
                    purpose = purpose, currency = account.currency,
                ))
            }) { Text("Speichern") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } },
    )
}
