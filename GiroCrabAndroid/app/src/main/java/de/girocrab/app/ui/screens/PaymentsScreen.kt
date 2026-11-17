package de.girocrab.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import de.girocrab.app.model.Account
import de.girocrab.app.model.AccountKind
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.Booking
import de.girocrab.app.model.CorePaymentDetails
import de.girocrab.app.model.CorePaymentParser
import de.girocrab.app.model.DirectDebitMandate
import de.girocrab.app.model.Interval
import de.girocrab.app.model.StandingOrder
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs

// ---------------------------------------------------------------------------
// Pure helpers (testable without Compose)
// ---------------------------------------------------------------------------

/** Horizon filter of the planned-payments tab (mirrors `PlannedHorizon`). */
enum class PlannedHorizon(val label: String, val days: Long) {
    D30("30 Tage", 30), D90("90 Tage", 90), Y1("1 Jahr", 365)
}

enum class SequenceType(val code: String, val label: String) {
    FRST("FRST", "Erstlastschrift"), RCUR("RCUR", "Folgelastschrift"), OOFF("OOFF", "Einmalig")
}

enum class VopResult { None, Match, CloseMatch, NoMatch, Unavailable }

/** One planned payment, either from a standing order or a detected recurring contract. */
data class PlannedPayment(
    val id: String,
    val accountId: String,
    val counterparty: String,
    val purpose: String,
    val amountCents: Long,
    val date: LocalDate,
    val kindText: String,
)

/** A recurring contract detected from bookings (same counterparty, ≥3 months, stable amount). */
data class RecurringContract(
    val counterparty: String,
    val accountId: String,
    val amountCents: Long,
    val next: LocalDate,
)

fun Interval.advance(d: LocalDate): LocalDate = when (this) {
    Interval.Weekly -> d.plusWeeks(1)
    Interval.Monthly -> d.plusMonths(1)
    Interval.Quarterly -> d.plusMonths(3)
    Interval.Yearly -> d.plusYears(1)
}

fun intervalLabel(i: Interval) = when (i) {
    Interval.Weekly -> "wöchentlich"
    Interval.Monthly -> "monatlich"
    Interval.Quarterly -> "vierteljährlich"
    Interval.Yearly -> "jährlich"
}

/** Expands standing orders into dated occurrences within [today, today + horizon]. */
fun expandStandingOrders(orders: List<StandingOrder>, today: LocalDate, horizon: PlannedHorizon): List<PlannedPayment> {
    val end = today.plusDays(horizon.days)
    val out = mutableListOf<PlannedPayment>()
    for (o in orders) {
        var d = o.nextDate
        var guard = 0
        while (d <= end && guard++ < 400) {
            if (d >= today) out += PlannedPayment(
                "so-${o.id}-$d", o.accountId, o.recipient, o.purpose, -abs(o.amountCents), d,
                "Dauerauftrag · ${intervalLabel(o.interval)}",
            )
            d = o.interval.advance(d)
        }
    }
    return out
}

/** Detects monthly recurring expenses: ≥3 distinct months, amounts within 10 % of each other. */
fun detectRecurring(bookings: List<Booking>, today: LocalDate): List<RecurringContract> =
    bookings.filter { it.amountCents < 0 && it.counterparty.isNotBlank() }
        .groupBy { it.accountId to it.counterparty.trim().lowercase(Locale.ROOT) }
        .mapNotNull { (_, list) ->
            val months = list.map { it.bookingDate.withDayOfMonth(1) }.distinct().sorted()
            if (months.size < 3) return@mapNotNull null
            val amounts = list.map { abs(it.amountCents) }
            val min = amounts.min(); val max = amounts.max()
            if (max > min * 11 / 10) return@mapNotNull null
            val last = list.maxBy { it.bookingDate }
            var next = last.bookingDate.plusMonths(1)
            while (next < today) next = next.plusMonths(1)
            RecurringContract(last.counterparty, last.accountId, -amounts.average().toLong(), next)
        }

fun recurringToPlanned(r: List<RecurringContract>, today: LocalDate, horizon: PlannedHorizon): List<PlannedPayment> {
    val end = today.plusDays(horizon.days)
    return r.flatMap { c ->
        generateSequence(c.next) { it.plusMonths(1) }.takeWhile { it <= end }.take(14).map {
            PlannedPayment("rc-${c.counterparty}-$it", c.accountId, c.counterparty, "", c.amountCents, it, "Vertrag · monatlich")
        }.toList()
    }
}

/** ISO 13616 mod-97 check. */
fun isValidIban(raw: String): Boolean {
    val s = raw.filter { !it.isWhitespace() }.uppercase(Locale.ROOT)
    if (s.length !in 15..34 || !s.all { it.isLetterOrDigit() } || !s[0].isLetter() || !s[1].isLetter()) return false
    val r = s.substring(4) + s.substring(0, 4)
    var rem = 0
    for (ch in r) {
        val v = if (ch.isDigit()) ch - '0' else ch - 'A' + 10
        rem = if (v < 10) (rem * 10 + v) % 97 else (rem * 100 + v) % 97
    }
    return rem == 1
}

fun formatIban(raw: String) = raw.filter { !it.isWhitespace() }.uppercase(Locale.ROOT).chunked(4).joinToString(" ")

/** Parses an amount like "12,50" into cents; null if invalid or ≤ 0. */
fun parseCents(text: String): Long? {
    val t = text.trim().replace(".", "").replace(',', '.')
    val v = t.toBigDecimalOrNull() ?: return null
    val c = v.movePointRight(2).setScale(0, java.math.RoundingMode.HALF_UP).toLong()
    return c.takeIf { it > 0 }
}

/** Offline stand-in for the bank's Verification of Payee: compares the name with known recipients. */
fun verifyPayee(name: String, iban: String, known: List<KnownRecipient>): VopResult {
    if (name.isBlank() || !isValidIban(iban)) return VopResult.None
    val hit = known.firstOrNull { it.iban.filter { c -> !c.isWhitespace() } == iban.filter { c -> !c.isWhitespace() } }
        ?: return VopResult.Unavailable
    fun norm(s: String) = s.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }
    val a = norm(name); val b = norm(hit.name)
    return when {
        a == b -> VopResult.Match
        a.isNotEmpty() && (a in b || b in a) -> VopResult.CloseMatch
        else -> VopResult.NoMatch
    }
}

data class KnownRecipient(val name: String, val iban: String)

/** Known recipients from past outgoing bookings (name + IBAN pairs stored in the reference field if IBAN-like). */
fun knownRecipients(state: AppUiState): List<KnownRecipient> {
    val fromOrders = state.data.standingOrders.map { KnownRecipient(it.recipient, it.iban) }
    val fromBookings = state.data.bookings.filter { it.amountCents < 0 }.mapNotNull { b ->
        b.reference?.takeIf { isValidIban(it) }?.let { KnownRecipient(b.counterparty, it) }
    }
    return (fromOrders + fromBookings).distinctBy { it.name.lowercase(Locale.ROOT) + it.iban }
}

/** EPC-QR (GiroCode) payload: BCD/001/…; returns null if it is not a valid EPC payload. */
data class EpcPayload(val name: String, val iban: String, val amountCents: Long?, val purpose: String)

fun parseEpcQr(text: String): EpcPayload? {
    val l = text.lines().map { it.trim() }
    if (l.size < 7 || l[0] != "BCD" || l[3] != "SCT") return null
    val iban = l[6].filter { !it.isWhitespace() }
    if (!isValidIban(iban)) return null
    val amount = l.getOrNull(7)?.removePrefix("EUR")?.takeIf { it.isNotBlank() }?.let { parseCents(it.replace('.', ',')) }
    val purpose = l.getOrNull(10)?.takeIf { it.isNotBlank() } ?: l.getOrNull(9).orEmpty()
    return EpcPayload(l[5], iban, amount, purpose)
}

/**
 * Payment data from a scanned EPC QR or pasted text, via the core parser (EPC first, then free text).
 * Without the native core it falls back to [parseEpcQr]. A result needs an IBAN with a valid checksum.
 */
fun parsePaymentInput(text: String): EpcPayload? {
    val core = CorePaymentParser.parseEpcPayload(text)?.takeIf { it.hasValidIban() }
        ?: CorePaymentParser.parsePaymentText(text)?.takeIf { it.hasValidIban() }
    if (core != null) {
        return EpcPayload(core.name.orEmpty(), core.iban.orEmpty().filter { !it.isWhitespace() }, core.amountCents?.takeIf { it > 0 }, core.purpose.orEmpty())
    }
    return parseEpcQr(text)
}

private fun CorePaymentDetails.hasValidIban(): Boolean = iban?.let { isValidIban(it.filter { c -> !c.isWhitespace() }) } == true

fun sequenceTypeFor(m: DirectDebitMandate, oneOff: Set<String>): SequenceType = when {
    m.id in oneOff -> SequenceType.OOFF
    m.lastUsed == null -> SequenceType.FRST
    else -> SequenceType.RCUR
}

/** Minimal pain.008.001.02 skeleton for a collection (preview/export). */
fun buildPain008(
    creditorName: String, creditorIban: String, creditorId: String,
    items: List<Triple<DirectDebitMandate, Long, SequenceType>>, collectionDate: LocalDate,
): String {
    fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    val total = items.sumOf { it.second }
    fun eur(c: Long) = "%d.%02d".format(Locale.ROOT, c / 100, c % 100)
    return buildString {
        appendLine("""<?xml version="1.0" encoding="UTF-8"?>""")
        appendLine("""<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.008.001.02"><CstmrDrctDbtInitn>""")
        appendLine("<GrpHdr><MsgId>GC-${collectionDate}</MsgId><NbOfTxs>${items.size}</NbOfTxs><CtrlSum>${eur(total)}</CtrlSum><InitgPty><Nm>${esc(creditorName)}</Nm></InitgPty></GrpHdr>")
        for (seq in items.map { it.third }.distinct()) {
            val g = items.filter { it.third == seq }
            appendLine("<PmtInf><PmtMtd>DD</PmtMtd><NbOfTxs>${g.size}</NbOfTxs><PmtTpInf><SeqTp>${seq.code}</SeqTp></PmtTpInf>")
            appendLine("<ReqdColltnDt>$collectionDate</ReqdColltnDt><Cdtr><Nm>${esc(creditorName)}</Nm></Cdtr>")
            appendLine("<CdtrAcct><Id><IBAN>${creditorIban.filter { !it.isWhitespace() }}</IBAN></Id></CdtrAcct>")
            appendLine("<CdtrSchmeId><Id><PrvtId><Othr><Id>${esc(creditorId)}</Id></Othr></PrvtId></Id></CdtrSchmeId>")
            for ((m, cents, _) in g) {
                appendLine("<DrctDbtTxInf><InstdAmt Ccy=\"EUR\">${eur(cents)}</InstdAmt><DrctDbtTx><MndtRltdInf><MndtId>${esc(m.mandateRef)}</MndtId><DtOfSgntr>${m.signedDate}</DtOfSgntr></MndtRltdInf></DrctDbtTx><Dbtr><Nm>${esc(m.creditor)}</Nm></Dbtr></DrctDbtTxInf>")
            }
            appendLine("</PmtInf>")
        }
        append("</CstmrDrctDbtInitn></Document>")
    }
}

/** What the user entered in the transfer sheet; handed to the core/connector by the caller. */
data class SepaTransferDraft(
    val accountId: String,
    val recipient: String,
    val iban: String,
    val amountCents: Long,
    val purpose: String,
    val instant: Boolean,
    val executionDate: LocalDate?,
)

private val dateFmt = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.GERMANY)

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

private val MODES = listOf("Überweisung", "Fixkosten & Abos", "Daueraufträge")
private val TABS = listOf("Geplante Zahlungen", "Daueraufträge", "Lastschriften")

/**
 * Payments screen. [onScanQr] starts the platform scanner and delivers the raw EPC text through the callback
 * (null = scanner unavailable, the button then offers pasting the payload instead).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaymentsScreen(
    state: AppUiState,
    onSubmitTransfer: (SepaTransferDraft) -> Unit,
    onScanQr: (((String) -> Unit) -> Unit)? = null,
    onPasteClipboard: () -> String? = { null },
    modifier: Modifier = Modifier,
    today: LocalDate = LocalDate.now(),
) {
    var tab by rememberSaveable { mutableStateOf(1) }
    var mode by rememberSaveable { mutableStateOf(0) }
    var showTransfer by rememberSaveable { mutableStateOf(false) }
    var prefill by remember { mutableStateOf<EpcPayload?>(null) }
    val masked = state.privacyMode

    Scaffold(
        modifier = modifier,
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { prefill = null; showTransfer = true },
                icon = { Icon(Icons.Default.Add, null) },
                text = { Text("Überweisung") },
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            if (state.demoActive) DemoHintBanner()
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                MODES.forEachIndexed { i, t ->
                    SegmentedButton(
                        selected = mode == i,
                        onClick = { mode = i },
                        shape = SegmentedButtonDefaults.itemShape(i, MODES.size),
                        icon = {},
                    ) { Text(t, maxLines = 1, style = MaterialTheme.typography.labelMedium) }
                }
            }
            when (mode) {
                0 -> TransferHome(
                    onNew = { prefill = null; showTransfer = true },
                    onQuickFill = {
                        if (onScanQr != null) onScanQr { raw -> parsePaymentInput(raw)?.let { prefill = it; showTransfer = true } }
                        else onPasteClipboard()?.let { raw -> parsePaymentInput(raw)?.let { prefill = it; showTransfer = true } }
                    },
                )
                1 -> FixedCostsTab(state, today, masked)
                else -> {
                    TabRow(selectedTabIndex = tab) {
                        TABS.forEachIndexed { i, t -> Tab(selected = tab == i, onClick = { tab = i }, text = { Text(t, maxLines = 1) }) }
                    }
                    when (tab) {
                        0 -> PlannedTab(state, today, masked)
                        1 -> StandingOrdersTab(state, masked)
                        else -> DirectDebitsTab(state, today, masked)
                    }
                }
            }
        }
    }

    if (showTransfer) {
        TransferSheet(
            state = state,
            prefill = prefill,
            today = today,
            onDismiss = { showTransfer = false },
            onSubmit = { onSubmitTransfer(it); showTransfer = false },
            onScanQr = onScanQr?.let { scan -> { scan { raw -> parsePaymentInput(raw)?.let { prefill = it } } } },
            onPaste = { onPasteClipboard()?.let { raw -> parsePaymentInput(raw)?.let { prefill = it } } },
        )
    }
}

/** Demo hint: nothing is sent to a bank while the demo vault is active. */
@Composable
fun DemoHintBanner(modifier: Modifier = Modifier) {
    Surface(
        modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.tertiaryContainer,
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Science, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Demo – Überweisungen werden nicht an eine Bank gesendet.", style = MaterialTheme.typography.labelLarge)
        }
    }
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

@Composable
private fun PlannedTab(state: AppUiState, today: LocalDate, masked: Boolean) {
    var horizon by rememberSaveable { mutableStateOf(PlannedHorizon.D30) }
    var accountFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var withContracts by rememberSaveable { mutableStateOf(true) }
    val accounts = state.data.accounts

    val planned = remember(state.data, horizon, accountFilter, withContracts, today) {
        val so = expandStandingOrders(state.data.standingOrders, today, horizon)
        val rc = if (withContracts) {
            val covered = state.data.standingOrders.map { it.recipient.lowercase(Locale.ROOT) }.toSet()
            recurringToPlanned(detectRecurring(state.data.bookings, today).filter { it.counterparty.lowercase(Locale.ROOT) !in covered }, today, horizon)
        } else emptyList()
        (so + rc).filter { accountFilter == null || it.accountId == accountFilter }.sortedBy { it.date }
    }
    val byMonth = planned.groupBy { it.date.withDayOfMonth(1) }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Text("Zahlungen, die bei der Bank bereits beauftragt, aber noch nicht gebucht sind – plus erkannte Verträge.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                PlannedHorizon.entries.forEach { h ->
                    FilterChip(selected = horizon == h, onClick = { horizon = h }, label = { Text(h.label) })
                }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AccountDropdown(accounts, accountFilter, allowAll = true, onSelect = { accountFilter = it })
                Spacer(Modifier.weight(1f))
                Text("Verträge", style = MaterialTheme.typography.labelLarge)
                Switch(checked = withContracts, onCheckedChange = { withContracts = it })
            }
        }
        item {
            val out = planned.filter { it.amountCents < 0 }.sumOf { it.amountCents }
            val inc = planned.filter { it.amountCents > 0 }.sumOf { it.amountCents }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TotalCell("Ausgehend", out, masked, Modifier.weight(1f))
                TotalCell("Eingehend", inc, masked, Modifier.weight(1f))
                TotalCell("Saldo", out + inc, masked, Modifier.weight(1f))
            }
        }
        if (planned.isEmpty()) {
            item {
                Column(Modifier.fillMaxWidth().padding(vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Keine geplanten Zahlungen", style = MaterialTheme.typography.titleMedium)
                    Text("Terminüberweisungen und Daueraufträge deiner Bank erscheinen hier bis zur Ausführung.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        byMonth.forEach { (month, list) ->
            item(key = "h-$month") {
                Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        month.format(DateTimeFormatter.ofPattern("LLLL yyyy", Locale.GERMANY)),
                        style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                    )
                    Text(formatMoney(list.sumOf { it.amountCents }, masked = masked), style = MaterialTheme.typography.labelLarge)
                }
            }
            items(list, key = { it.id }) { p ->
                val accName = accounts.firstOrNull { it.id == p.accountId }?.name.orEmpty()
                Card(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(if (masked) "••••••" else p.counterparty, fontWeight = FontWeight.Medium, maxLines = 1)
                            Text(
                                if (masked) accName else listOf(p.purpose, accName).filter { it.isNotBlank() }.joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                            )
                            Text(p.kindText, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text(formatMoney(p.amountCents, masked = masked), fontWeight = FontWeight.SemiBold, maxLines = 1)
                            Text(p.date.format(dateFmt), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TotalCell(label: String, cents: Long, masked: Boolean, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(formatMoney(cents, masked = masked), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun StandingOrdersTab(state: AppUiState, masked: Boolean) {
    val orders = state.data.standingOrders.sortedBy { it.nextDate }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (orders.isEmpty()) item { Text("Keine Daueraufträge vorhanden.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        items(orders, key = { it.id }) { o ->
            val acc = state.data.accounts.firstOrNull { it.id == o.accountId }
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(if (masked) "••••••" else o.recipient, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f), maxLines = 1)
                        Text(formatMoney(-abs(o.amountCents), masked = masked), fontWeight = FontWeight.SemiBold)
                    }
                    Text(if (masked) "••••" else formatIban(o.iban), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (o.purpose.isNotBlank() && !masked) Text(o.purpose, style = MaterialTheme.typography.bodySmall)
                    Text(
                        "${intervalLabel(o.interval)} · nächste Ausführung ${o.nextDate.format(dateFmt)}${acc?.let { " · ${it.name}" }.orEmpty()}",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }
    }
}

@Composable
private fun DirectDebitsTab(state: AppUiState, today: LocalDate, masked: Boolean) {
    var oneOff by rememberSaveable { mutableStateOf(setOf<String>()) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var pain by remember { mutableStateOf<String?>(null) }
    var showCollect by remember { mutableStateOf(false) }
    val mandates = state.data.mandates

    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("SEPA-Mandate", style = MaterialTheme.typography.titleMedium)
                OutlinedButton(onClick = { showCollect = true }, enabled = mandates.isNotEmpty()) { Text("Einzug (pain.008)") }
            }
        }
        if (mandates.isEmpty()) item { Text("Keine Lastschriftmandate vorhanden.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        items(mandates, key = { it.id }) { m ->
            val seq = sequenceTypeFor(m, oneOff)
            Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Text(if (masked) "••••••" else m.creditor, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f), maxLines = 1)
                        FilterChip(
                            selected = seq == SequenceType.OOFF,
                            onClick = { oneOff = if (m.id in oneOff) oneOff - m.id else oneOff + m.id },
                            label = { Text(seq.code) },
                        )
                    }
                    Text("Gläubiger-ID: ${if (masked) "••••" else m.creditorId}", style = MaterialTheme.typography.bodySmall)
                    Text("Mandatsreferenz: ${if (masked) "••••" else m.mandateRef}", style = MaterialTheme.typography.bodySmall)
                    Text(
                        "Unterschrieben ${m.signedDate.format(dateFmt)} · zuletzt genutzt ${m.lastUsed?.format(dateFmt) ?: "nie"}",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline,
                    )
                    Text(seq.label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                }
            }
        }
    }

    if (showCollect) {
        CollectionDialog(
            mandates = mandates, selected = selected, onSelected = { selected = it },
            seqOf = { sequenceTypeFor(it, oneOff) },
            accounts = state.data.accounts,
            today = today,
            onDismiss = { showCollect = false },
            onBuild = { pain = it; showCollect = false },
        )
    }
    pain?.let { xml ->
        AlertDialog(
            onDismissRequest = { pain = null },
            confirmButton = { TextButton(onClick = { pain = null }) { Text("Schließen") } },
            title = { Text("pain.008 Vorschau") },
            text = { Text(xml, style = MaterialTheme.typography.bodySmall, modifier = Modifier.verticalScroll(rememberScrollState())) },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CollectionDialog(
    mandates: List<DirectDebitMandate>,
    selected: Set<String>,
    onSelected: (Set<String>) -> Unit,
    seqOf: (DirectDebitMandate) -> SequenceType,
    accounts: List<Account>,
    today: LocalDate,
    onDismiss: () -> Unit,
    onBuild: (String) -> Unit,
) {
    var name by rememberSaveable { mutableStateOf("") }
    var creditorId by rememberSaveable { mutableStateOf("") }
    var accountId by rememberSaveable { mutableStateOf(accounts.firstOrNull { it.kind == AccountKind.Giro }?.id) }
    var amounts by remember { mutableStateOf(mapOf<String, String>()) }
    val acc = accounts.firstOrNull { it.id == accountId }
    val items = mandates.filter { it.id in selected }.mapNotNull { m -> parseCents(amounts[m.id].orEmpty())?.let { Triple(m, it, seqOf(m)) } }
    val valid = name.isNotBlank() && creditorId.isNotBlank() && acc?.iban?.let(::isValidIban) == true && items.isNotEmpty()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Lastschrifteinzug") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name des Gläubigers") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(creditorId, { creditorId = it.uppercase(Locale.ROOT) }, label = { Text("Gläubiger-ID") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                AccountDropdown(accounts, accountId, allowAll = false, onSelect = { accountId = it })
                mandates.forEach { m ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.Checkbox(m.id in selected, { c -> onSelected(if (c) selected + m.id else selected - m.id) })
                        Column(Modifier.weight(1f)) {
                            Text(m.creditor, maxLines = 1)
                            Text("${seqOf(m).code} · ${m.mandateRef}", style = MaterialTheme.typography.labelSmall)
                        }
                        OutlinedTextField(
                            amounts[m.id].orEmpty(), { amounts = amounts + (m.id to it) }, label = { Text("€") }, singleLine = true,
                            enabled = m.id in selected, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.width(100.dp),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = valid, onClick = {
                onBuild(buildPain008(name, acc!!.iban!!, creditorId, items, today.plusDays(5)))
            }) { Text("Erzeugen") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } },
    )
}

// ---------------------------------------------------------------------------
// Account picker
// ---------------------------------------------------------------------------

@Composable
private fun AccountDropdown(accounts: List<Account>, selectedId: String?, allowAll: Boolean, onSelect: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = accounts.firstOrNull { it.id == selectedId }?.name ?: if (allowAll) "Alle Konten" else "Konto wählen"
    Column {
        OutlinedButton(onClick = { open = true }) { Text(label, maxLines = 1) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (allowAll) DropdownMenuItem(text = { Text("Alle Konten") }, onClick = { onSelect(null); open = false })
            accounts.forEach { a ->
                DropdownMenuItem(text = { Text("${a.name} · ${a.bankName}") }, onClick = { onSelect(a.id); open = false })
            }
        }
    }
}

// ---------------------------------------------------------------------------
// SEPA transfer sheet
// ---------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TransferSheet(
    state: AppUiState,
    prefill: EpcPayload?,
    today: LocalDate,
    onDismiss: () -> Unit,
    onSubmit: (SepaTransferDraft) -> Unit,
    onScanQr: (() -> Unit)?,
    onPaste: () -> Unit,
) {
    val payable = state.data.accounts.filter { it.iban != null && it.kind in setOf(AccountKind.Giro, AccountKind.CreditCard, AccountKind.Savings) }
    val known = remember(state.data) { knownRecipients(state) }
    var accountId by remember { mutableStateOf(payable.firstOrNull()?.id) }
    var recipient by remember(prefill) { mutableStateOf(prefill?.name.orEmpty()) }
    var iban by remember(prefill) { mutableStateOf(prefill?.iban?.let(::formatIban).orEmpty()) }
    var amount by remember(prefill) { mutableStateOf(prefill?.amountCents?.let { "%d,%02d".format(it / 100, it % 100) }.orEmpty()) }
    var purpose by remember(prefill) { mutableStateOf(prefill?.purpose.orEmpty()) }
    var instant by remember { mutableStateOf(false) }
    var date by remember { mutableStateOf<LocalDate?>(null) }
    var pickDate by remember { mutableStateOf(false) }
    var suggestOpen by remember { mutableStateOf(false) }

    val cents = parseCents(amount)
    val ibanOk = isValidIban(iban)
    val vop = remember(recipient, iban, known) { verifyPayee(recipient, iban, known) }
    val suggestions = remember(recipient, known) {
        if (recipient.length < 2) emptyList() else known.filter { it.name.contains(recipient, ignoreCase = true) && it.name != recipient }.take(4)
    }
    val balance = payable.firstOrNull { it.id == accountId }?.balanceCents
    val canSend = accountId != null && recipient.isNotBlank() && ibanOk && cents != null && !(instant && date != null)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (state.demoActive) DemoHintBanner()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("SEPA-Überweisung", style = MaterialTheme.typography.titleLarge)
                OutlinedButton(onClick = { onScanQr?.invoke() ?: onPaste() }) {
                    Icon(Icons.Default.QrCodeScanner, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("GiroCode / Rechnung einlesen")
                }
            }
            Text("Von Konto", style = MaterialTheme.typography.labelMedium)
            AccountDropdown(payable, accountId, allowAll = false, onSelect = { accountId = it })
            if (balance != null) Text("Saldo ${formatMoney(balance, masked = state.privacyMode)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            Column {
                OutlinedTextField(
                    recipient, { recipient = it; suggestOpen = true }, label = { Text("Empfänger") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (suggestOpen) suggestions.forEach { k ->
                    Text(
                        "${k.name} · ${formatIban(k.iban)}",
                        Modifier.fillMaxWidth().clickable { recipient = k.name; iban = formatIban(k.iban); suggestOpen = false }.padding(8.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            OutlinedTextField(
                iban, { iban = formatIban(it) }, label = { Text("IBAN") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                isError = iban.isNotBlank() && !ibanOk,
                supportingText = {
                    when {
                        iban.isBlank() -> {}
                        ibanOk -> Text("✓ IBAN-Prüfsumme gültig (#571)")
                        else -> Text("✗ IBAN-Prüfsumme ungültig – bitte Tippfehler prüfen")
                    }
                },
            )
            VopBanner(vop)
            OutlinedTextField(
                amount, { amount = it }, label = { Text("Betrag (EUR)") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                isError = amount.isNotBlank() && cents == null,
            )
            OutlinedTextField(purpose, { purpose = it.take(140) }, label = { Text("Verwendungszweck") }, modifier = Modifier.fillMaxWidth(), supportingText = { Text("${purpose.length}/140") })

            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Echtzeitüberweisung", style = MaterialTheme.typography.bodyLarge)
                    Text("Gutschrift in Sekunden, nur sofortige Ausführung", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(instant, { instant = it; if (it) date = null })
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { pickDate = true }, enabled = !instant) { Text(date?.format(dateFmt) ?: "Ausführung: sofort") }
                if (date != null) TextButton(onClick = { date = null }) { Text("Zurücksetzen") }
            }

            Row(Modifier.fillMaxWidth().padding(bottom = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                TextButton(onClick = onDismiss) { Text("Abbrechen") }
                Button(
                    enabled = canSend,
                    onClick = { onSubmit(SepaTransferDraft(accountId!!, recipient.trim(), iban.filter { !it.isWhitespace() }, cents!!, purpose.trim(), instant, date)) },
                ) { Text(if (state.demoActive) "Testen" else "Weiter zur Freigabe") }
            }
        }
    }

    if (pickDate) {
        val st = rememberDatePickerState(initialSelectedDateMillis = today.plusDays(1).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
        AlertDialog(
            onDismissRequest = { pickDate = false },
            confirmButton = {
                TextButton(onClick = {
                    st.selectedDateMillis?.let { ms ->
                        val d = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate()
                        date = d.takeIf { it > today }
                    }
                    pickDate = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickDate = false }) { Text("Abbrechen") } },
            text = { DatePicker(state = st, showModeToggle = false) },
        )
    }
}

@Composable
private fun VopBanner(vop: VopResult) {
    val (text, icon, ok) = when (vop) {
        VopResult.None -> return
        VopResult.Match -> Triple("Empfängerprüfung: Name stimmt überein.", Icons.Default.CheckCircle, true)
        VopResult.CloseMatch -> Triple("Empfängerprüfung: Name stimmt nahezu überein. Bitte prüfen.", Icons.Default.Warning, false)
        VopResult.NoMatch -> Triple("Empfängerprüfung: Name passt nicht zur IBAN. Bei Fortfahren haftest du für Fehlüberweisungen.", Icons.Default.Warning, false)
        VopResult.Unavailable -> Triple("Empfängerprüfung (VoP) erfolgt durch deine Bank bei der Freigabe.", Icons.Default.Info, true)
    }
    Surface(
        Modifier.fillMaxWidth(),
        color = if (ok) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.errorContainer,
        shape = MaterialTheme.shapes.small,
    ) {
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(text, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun TransferHome(onNew: () -> Unit, onQuickFill: () -> Unit) {
    Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("SEPA-Überweisung", style = MaterialTheme.typography.titleMedium)
        Text(
            "Die IBAN wird live per Prüfsumme (#571) kontrolliert; der Empfängername wird vor dem Senden mit bekannten Empfängern abgeglichen (Empfängerprüfung).",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedButton(onClick = onQuickFill, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Default.QrCodeScanner, null, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("GiroCode / Rechnung einlesen")
        }
        Button(onClick = onNew, modifier = Modifier.fillMaxWidth()) { Text("Neue Überweisung") }
    }
}

@Composable
private fun FixedCostsTab(state: AppUiState, today: LocalDate, masked: Boolean) {
    val contracts = remember(state.data, today) { detectRecurring(state.data.bookings, today).sortedBy { it.next } }
    val monthly = contracts.sumOf { abs(it.amountCents) }
    val endOfMonth = today.withDayOfMonth(today.lengthOfMonth())
    val upcoming = contracts.filter { it.next <= endOfMonth }
    val dayFmt = remember { DateTimeFormatter.ofPattern("dd.MM.") }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Fixkosten pro Monat", style = MaterialTheme.typography.labelMedium)
                    Text(formatMoney(-monthly, masked = masked), style = MaterialTheme.typography.headlineSmall)
                    Text("${contracts.size} erkannte Verträge & Abos", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        item { Text("Noch bis Monatsende (Prognose, #550)", style = MaterialTheme.typography.titleSmall) }
        if (upcoming.isEmpty()) item { Text("Keine weiteren Abbuchungen in diesem Monat.", style = MaterialTheme.typography.bodySmall) }
        items(upcoming) { c ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("${c.next.format(dayFmt)}  ${c.counterparty}", style = MaterialTheme.typography.bodyMedium)
                Text(formatMoney(c.amountCents, masked = masked), style = MaterialTheme.typography.bodyMedium)
            }
        }
        item { Text("Erkannte Verträge", style = MaterialTheme.typography.titleSmall) }
        if (contracts.isEmpty()) item { Text("Noch keine wiederkehrenden Zahlungen erkannt.", style = MaterialTheme.typography.bodySmall) }
        items(contracts) { c ->
            Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                Row(Modifier.padding(12.dp).fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column {
                        Text(c.counterparty, style = MaterialTheme.typography.bodyLarge)
                        Text("monatlich · nächste ${c.next.format(dateFmt)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(formatMoney(c.amountCents, masked = masked), style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
    }
}
