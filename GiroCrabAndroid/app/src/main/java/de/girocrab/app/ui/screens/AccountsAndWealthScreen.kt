package de.girocrab.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
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
import androidx.compose.material3.Badge
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.girocrab.app.model.Account
import de.girocrab.app.model.AccountGroup
import de.girocrab.app.model.AccountKind
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.ConnectorKind
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
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
    modifier: Modifier = Modifier,
) {
    val masked = state.privacyMode
    var showWealth by rememberSaveable { mutableStateOf(false) }
    val wealth = remember(state.data) { wealthBreakdown(state) }
    val collapsed = remember { mutableStateOf(setOf<String>()) }

    LazyColumn(
        modifier = modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { ScopeGrid(state, badges, wealth, masked) { kind ->
            if (kind == ScopeCardKind.NetWorth) showWealth = !showWealth
            onSelectScope(kind)
        } }
        if (showWealth) item { WealthOverview(wealth, masked) }

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
                    onSelectAccount = onSelectAccount,
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
            WealthCard("Vermögenswerte", w.assets, Color(0xFF2E7D32), masked, Modifier.weight(1f))
            WealthCard("Verbindlichkeiten", w.liabilities, Color(0xFFC62828), masked, Modifier.weight(1f))
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
            Triple("Kredite", w.loans, Color(0xFFC62828)),
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
