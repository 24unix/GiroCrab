package de.girocrab.app.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.AppViewModel
import de.girocrab.app.model.Booking
import de.girocrab.app.model.Category
import de.girocrab.app.model.SplitPart
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

private val LongDate: DateTimeFormatter = DateTimeFormatter.ofPattern("d. MMMM yyyy", Locale.GERMANY)

/** SEPA purpose keys (EREF+/MREF+/CRED+/SVWZ+) split out of the raw purpose text. */
data class SepaFields(
    val endToEnd: String?,
    val mandate: String?,
    val creditorId: String?,
    val purpose: String,
)

private val sepaKey = Regex("""(EREF|MREF|CRED|SVWZ|KREF|ABWA|IBAN|BIC)\+""")

fun parseSepaFields(raw: String): SepaFields {
    val hits = sepaKey.findAll(raw).toList()
    if (hits.isEmpty()) return SepaFields(null, null, null, raw.trim())
    val map = mutableMapOf<String, String>()
    hits.forEachIndexed { i, m ->
        val end = hits.getOrNull(i + 1)?.range?.first ?: raw.length
        map[m.groupValues[1]] = raw.substring(m.range.last + 1, end).trim()
    }
    val head = raw.substring(0, hits.first().range.first).trim()
    val purpose = map["SVWZ"] ?: head.ifBlank { raw.trim() }
    return SepaFields(
        endToEnd = map["EREF"]?.takeIf { it.isNotBlank() && it != "NOTPROVIDED" },
        mandate = map["MREF"]?.takeIf { it.isNotBlank() },
        creditorId = map["CRED"]?.takeIf { it.isNotBlank() },
        purpose = purpose,
    )
}


private fun centsToInput(c: Long): String {
    val sign = if (c < 0) "-" else ""
    val a = abs(c)
    return "%s%d,%02d".format(sign, a / 100, a % 100)
}

private fun copyToClipboard(ctx: Context, label: String, text: String) {
    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText(label, text))
    Toast.makeText(ctx, "$label kopiert", Toast.LENGTH_SHORT).show()
}

/**
 * Booking detail bottom sheet: counterparty, IBAN, dates, SEPA references, transfer banner (#574),
 * category/tag pickers, note, documents and the split editor (#654, mixed-sign splits allowed).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BookingDetailSheet(
    booking: Booking,
    state: AppUiState,
    vm: AppViewModel,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val ctx = LocalContext.current
    val masked = state.privacyMode
    val account = state.data.accounts.firstOrNull { it.id == booking.accountId }
    val sepa = remember(booking.purpose) { parseSepaFields(booking.purpose) }

    // #574: a booking is a transfer when the counterparty is one of the user's own accounts.
    val transferTarget = remember(booking, state.data.accounts) {
        val cp = booking.counterparty.trim().lowercase()
        state.data.accounts.firstOrNull { a ->
            a.id != booking.accountId && (
                (cp.isNotEmpty() && (cp == a.name.lowercase() || cp.contains(a.name.lowercase()))) ||
                    (a.iban != null && booking.purpose.replace(" ", "").contains(a.iban.replace(" ", ""), true))
                )
        }
    }
    val transferByText = booking.purpose.contains("umbuchung", true) || booking.purpose.contains("eigenübertrag", true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Header
            Column {
                Text(
                    if (masked) "••••••" else booking.counterparty.ifBlank { "Unbekannt" },
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    formatMoney(booking.amountCents, booking.currency, masked),
                    style = MaterialTheme.typography.headlineSmall,
                    color = if (booking.amountCents >= 0) Color(0xFF2E7D32) else MaterialTheme.colorScheme.onSurface,
                )
                account?.let {
                    Text(
                        "${it.bankName} · ${it.name}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (transferTarget != null || transferByText) {
                TransferBanner(
                    reason = when {
                        transferTarget != null ->
                            "Gegenkonto „${transferTarget.name}“ gehört zu Ihren eigenen Konten" +
                                (transferTarget.iban?.let { " (${formatIban(it)})" } ?: "") + "."
                        else -> "Der Verwendungszweck enthält einen Umbuchungs-Hinweis."
                    },
                    masked = masked,
                )
            }

            // Details
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    account?.iban?.let { iban ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("IBAN (Konto)", style = MaterialTheme.typography.labelSmall)
                                Text(if (masked) "•••• •••• ••••" else formatIban(iban), style = MaterialTheme.typography.bodyMedium)
                            }
                            if (!masked) {
                                IconButton(onClick = { copyToClipboard(ctx, "IBAN", iban.replace(" ", "")) }) {
                                    Icon(Icons.Filled.ContentCopy, contentDescription = "IBAN kopieren")
                                }
                            }
                        }
                    }
                    DetailRow("Buchungsdatum", booking.bookingDate.format(LongDate))
                    DetailRow("Wertstellung", booking.valueDate.format(LongDate))
                    DetailRow("Buchungsart", if (booking.amountCents >= 0) "Gutschrift" else "Lastschrift / Zahlung")
                    (sepa.endToEnd ?: booking.reference)?.let { DetailRow("End-to-End-Referenz", it, masked) }
                    sepa.mandate?.let { DetailRow("Mandatsreferenz", it, masked) }
                    sepa.creditorId?.let { DetailRow("Gläubiger-ID", it, masked) }
                }
            }

            Column {
                Text("Verwendungszweck", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    if (masked) "••••••••••••" else sepa.purpose.ifBlank { "–" },
                    style = MaterialTheme.typography.bodyMedium,
                )
            }

            HorizontalDivider()

            CategorySelector(
                categories = state.data.categories,
                selectedId = booking.categoryId,
                byRule = booking.categoryByRule,
                onSelect = { vm.setCategory(booking.id, it) },
            )

            TagSection(
                booking = booking,
                state = state,
                vm = vm,
            )

            NoteField(booking = booking, onSave = { vm.setNote(booking.id, it) })

            DocumentSection(bookingId = booking.id)

            HorizontalDivider()

            SplitEditor(
                booking = booking,
                categories = state.data.categories,
                masked = masked,
                onSave = { vm.setSplits(booking.id, it) },
            )

            Spacer(Modifier.size(16.dp))
        }
    }
}

@Composable
private fun TransferBanner(reason: String, masked: Boolean) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.SwapHoriz, contentDescription = null)
            Column {
                Text("⇄ Als Umbuchung erkannt …", fontWeight = FontWeight.SemiBold)
                Text(
                    if (masked) "••••••••" else reason,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "Umbuchungen zählen nicht zu Einnahmen und Ausgaben.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer.copy(alpha = 0.7f),
                )
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String, masked: Boolean = false) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.size(12.dp))
        Text(if (masked) "••••••" else value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
}

@Composable
private fun CategorySelector(
    categories: List<Category>,
    selectedId: String?,
    byRule: Boolean,
    onSelect: (String?) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val selected = categories.firstOrNull { it.id == selectedId }
    Column {
        SectionLabel("Kategorie")
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { open = true }) {
                Text(selected?.name ?: "Keine Kategorie")
            }
            if (byRule && selected != null) {
                AssistChip(onClick = {}, label = { Text("per Regel") })
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                DropdownMenuItem(text = { Text("Keine Kategorie") }, onClick = { onSelect(null); open = false })
                categories.sortedWith(compareBy({ it.parentId ?: it.id }, { it.parentId != null }, { it.name }))
                    .forEach { c ->
                        DropdownMenuItem(
                            text = { Text((if (c.parentId != null) "   ↳ " else "") + c.name) },
                            onClick = { onSelect(c.id); open = false },
                        )
                    }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TagSection(booking: Booking, state: AppUiState, vm: AppViewModel) {
    var newTag by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Tags")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            state.data.tags.forEach { t ->
                FilterChip(
                    selected = t.id in booking.tagIds,
                    onClick = { vm.toggleTag(booking.id, t.id) },
                    label = { Text("#${t.name}") },
                    trailingIcon = if (t.id in booking.tagIds) {
                        { Icon(Icons.Filled.Close, contentDescription = "Tag entfernen", modifier = Modifier.size(16.dp)) }
                    } else null,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = newTag,
                onValueChange = { newTag = it },
                singleLine = true,
                label = { Text("Neuer Tag") },
                modifier = Modifier.weight(1f),
            )
            IconButton(
                enabled = newTag.isNotBlank(),
                onClick = {
                    val name = newTag.trim()
                    val existing = state.data.tags.firstOrNull { it.name.equals(name, true) }
                    if (existing != null) {
                        if (existing.id !in booking.tagIds) vm.toggleTag(booking.id, existing.id)
                    } else {
                        vm.addTag(name)
                        // The new tag is the last one added; attach it on the next state emission.
                        vm.state.value.data.tags.lastOrNull { it.name == name }?.let { vm.toggleTag(booking.id, it.id) }
                    }
                    newTag = ""
                },
            ) { Icon(Icons.Filled.Add, contentDescription = "Tag hinzufügen") }
        }
    }
}

@Composable
private fun NoteField(booking: Booking, onSave: (String) -> Unit) {
    var text by remember(booking.id) { mutableStateOf(booking.note) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Notiz")
        OutlinedTextField(
            value = text,
            onValueChange = { text = it; onSave(it) },
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
            placeholder = { Text("Notiz hinzufügen …") },
        )
    }
}

@Composable
private fun DocumentSection(bookingId: String) {
    val ctx = LocalContext.current
    val docs = remember(bookingId) { mutableStateListOf<Pair<Uri, String>>() }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                ctx.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val name = ctx.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0 && c.moveToFirst()) c.getString(i) else null
            } ?: uri.lastPathSegment ?: "Beleg"
            docs.add(uri to name)
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Belege")
        docs.forEach { (uri, name) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(
                    onClick = {
                        val i = android.content.Intent(android.content.Intent.ACTION_VIEW)
                            .setData(uri)
                            .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        runCatching { ctx.startActivity(i) }
                    },
                    modifier = Modifier.weight(1f),
                ) { Icon(Icons.Filled.AttachFile, null); Spacer(Modifier.size(6.dp)); Text(name, maxLines = 1) }
                IconButton(onClick = { docs.remove(uri to name) }) {
                    Icon(Icons.Filled.Delete, contentDescription = "Beleg entfernen")
                }
            }
        }
        OutlinedButton(onClick = { picker.launch(arrayOf("application/pdf", "image/*")) }) {
            Icon(Icons.Filled.Add, null)
            Spacer(Modifier.size(6.dp))
            Text("Beleg hinzufügen")
        }
    }
}

private class SplitDraft(categoryId: String?, amount: String, note: String) {
    var amount by mutableStateOf(amount)
    var note by mutableStateOf(note)
    var categoryId2 by mutableStateOf(categoryId)
}

/** #654: multi-line split editor; parts may have mixed signs but must sum to the booking amount. */
@Composable
private fun SplitEditor(
    booking: Booking,
    categories: List<Category>,
    masked: Boolean,
    onSave: (List<SplitPart>) -> Unit,
) {
    val rows = remember(booking.id) {
        mutableStateListOf<SplitDraft>().apply {
            booking.splits.forEach { add(SplitDraft(it.categoryId, centsToInput(it.amountCents), it.note)) }
        }
    }
    val parsed = rows.map { parseCents(it.amount) }
    val valid = parsed.all { it != null }
    val sum = parsed.filterNotNull().sum()
    val remaining = booking.amountCents - sum
    val canSave = rows.isEmpty() && booking.splits.isNotEmpty() ||
        (rows.size >= 2 && valid && remaining == 0L)

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Buchung aufteilen")
        Text(
            "Teilbeträge dürfen unterschiedliche Vorzeichen haben; die Summe muss dem Buchungsbetrag entsprechen.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        rows.forEachIndexed { idx, row ->
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))) {
                Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        var open by remember { mutableStateOf(false) }
                        OutlinedButton(onClick = { open = true }, modifier = Modifier.weight(1f)) {
                            Text(categories.firstOrNull { it.id == row.categoryId2 }?.name ?: "Kategorie", maxLines = 1)
                        }
                        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                            DropdownMenuItem(text = { Text("Keine Kategorie") }, onClick = { row.categoryId2 = null; open = false })
                            categories.forEach { c ->
                                DropdownMenuItem(text = { Text(c.name) }, onClick = { row.categoryId2 = c.id; open = false })
                            }
                        }
                        OutlinedTextField(
                            value = if (masked) "•••" else row.amount,
                            onValueChange = { if (!masked) row.amount = it },
                            singleLine = true,
                            label = { Text("Betrag") },
                            isError = parseCents(row.amount) == null,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { rows.removeAt(idx) }) {
                            Icon(Icons.Filled.Delete, contentDescription = "Teil entfernen")
                        }
                    }
                    OutlinedTextField(
                        value = row.note,
                        onValueChange = { row.note = it },
                        singleLine = true,
                        label = { Text("Notiz (optional)") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = {
                val rest = if (rows.isEmpty()) booking.amountCents else remaining
                rows.add(SplitDraft(booking.categoryId, centsToInput(rest), ""))
                if (rows.size == 1) rows.add(SplitDraft(null, centsToInput(0), ""))
            }) {
                Icon(Icons.Filled.Add, null)
                Spacer(Modifier.size(6.dp))
                Text("Teil hinzufügen")
            }
            if (rows.isNotEmpty()) {
                Text(
                    if (remaining == 0L) "Summe stimmt" else "Rest: ${formatMoney(remaining, booking.currency, masked)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (remaining == 0L) Color(0xFF2E7D32) else MaterialTheme.colorScheme.error,
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                enabled = canSave,
                onClick = {
                    onSave(rows.mapIndexed { i, r -> SplitPart(r.categoryId2, parsed[i] ?: 0L, r.note.trim()) })
                },
            ) { Text("Aufteilung speichern") }
            if (booking.splits.isNotEmpty() || rows.isNotEmpty()) {
                TextButton(onClick = { rows.clear(); onSave(emptyList()) }) { Text("Aufteilung aufheben") }
            }
        }
    }
}
