package de.girocrab.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.background
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import de.girocrab.app.model.Announcement
import de.girocrab.app.model.AppUiState
import de.girocrab.app.model.Booking
import de.girocrab.app.model.MatchKind
import de.girocrab.app.model.Rule
import de.girocrab.app.model.RuleField
import java.time.format.DateTimeFormatter

// ---------------------------------------------------------------------------------------------
// Add Bank assistant (#789)
// ---------------------------------------------------------------------------------------------

enum class BankAccess(val label: String, val hint: String) {
    FinTS("FinTS", "Direkt zur Bank, ohne Anmeldung bei Dritten (empfohlen)."),
    Psd2("PSD2 (Enable Banking)", "Über einen Zugangsdienst; Freigabe in der Bank-App."),
}

data class BankEntry(val name: String, val blz: String, val ways: Set<BankAccess>)

/** Small built-in directory; the core bridge supplies the full BIC/FinTS directory later. */
val popularBanks = listOf(
    BankEntry("Sparkasse", "", setOf(BankAccess.FinTS, BankAccess.Psd2)),
    BankEntry("Volksbank Raiffeisenbank", "", setOf(BankAccess.FinTS, BankAccess.Psd2)),
    BankEntry("DKB", "12030000", setOf(BankAccess.FinTS, BankAccess.Psd2)),
    BankEntry("ING", "50010517", setOf(BankAccess.FinTS, BankAccess.Psd2)),
    BankEntry("comdirect", "20041111", setOf(BankAccess.FinTS)),
    BankEntry("Commerzbank", "50040000", setOf(BankAccess.FinTS, BankAccess.Psd2)),
    BankEntry("Deutsche Bank", "10070024", setOf(BankAccess.FinTS, BankAccess.Psd2)),
    BankEntry("N26", "10011001", setOf(BankAccess.Psd2)),
    BankEntry("Trade Republic", "", setOf(BankAccess.Psd2)),
)

data class BankConnectRequest(
    val bank: BankEntry,
    val access: BankAccess,
    val userId: String,
    val pin: String,
    /** Null whenever the built-in registration is active (#789). */
    val fintsProductId: String?,
)

/**
 * Three steps: bank -> access -> setup. The FinTS product ID field only exists when the user
 * chose "Own ID" in settings; with the built-in ID it is never asked for (#789).
 */
@Composable
fun AddBankDialog(
    state: AppUiState,
    onDismiss: () -> Unit,
    onConnect: (BankConnectRequest) -> Unit,
    onTryDemo: () -> Unit = {},
) {
    var step by rememberSaveable { mutableStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var bankName by rememberSaveable { mutableStateOf<String?>(null) }
    var access by rememberSaveable { mutableStateOf(BankAccess.FinTS) }
    var userId by rememberSaveable { mutableStateOf("") }
    var pin by rememberSaveable { mutableStateOf("") }
    var productId by rememberSaveable { mutableStateOf(state.fintsProductId) }
    var waitingTan by rememberSaveable { mutableStateOf(false) }

    val bank = popularBanks.firstOrNull { it.name == bankName }
    val needsProductId = access == BankAccess.FinTS && state.useOwnFintsId
    val canNext = when (step) {
        0 -> bank != null
        1 -> bank != null && access in bank.ways
        else -> if (access == BankAccess.FinTS)
            userId.isNotBlank() && pin.isNotBlank() && (!needsProductId || productId.isNotBlank())
        else true
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Bank hinzufügen") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.demoActive) DemoHintBanner()
                when {
                    waitingTan -> {
                        Text("Bitte bestätige die Anmeldung in deiner Banking-App (Decoupled TAN).")
                        Text(
                            "Nach der Freigabe wird automatisch fortgefahren.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    step == 0 -> {
                        OutlinedTextField(
                            value = query, onValueChange = { query = it }, singleLine = true,
                            leadingIcon = { Icon(Icons.Default.Search, null) },
                            label = { Text("Bank, BLZ oder IBAN suchen …") },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        val hits = popularBanks.filter {
                            query.isBlank() || it.name.contains(query, true) || (it.blz.isNotEmpty() && query.startsWith(it.blz.take(4)))
                        }
                        hits.forEach { b ->
                            ListItem(
                                headlineContent = { Text(b.name) },
                                supportingContent = { Text(b.ways.joinToString(" · ") { it.label }) },
                                modifier = Modifier.clickable { bankName = b.name },
                                colors = androidx.compose.material3.ListItemDefaults.colors(
                                    containerColor = if (b.name == bankName) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent,
                                ),
                            )
                        }
                        Text(
                            "Jede Sparkasse und Volksbank ist eine eigene Bank – suche sie über ihren Namen (meist mit Ort).",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        TextButton(onClick = onTryDemo) { Text("Demo-Bank ausprobieren") }
                    }
                    step == 1 -> {
                        Text(bank?.name.orEmpty(), style = MaterialTheme.typography.titleSmall)
                        BankAccess.entries.filter { bank != null && it in bank.ways }.forEach { a ->
                            FilterChip(selected = access == a, onClick = { access = a }, label = { Text(a.label) })
                            Text(a.hint, style = MaterialTheme.typography.bodySmall)
                        }
                        Text("GiroCrab empfiehlt FinTS: direkt zur Bank, ohne Anmeldung bei Dritten.", style = MaterialTheme.typography.bodySmall)
                    }
                    else -> if (access == BankAccess.FinTS) {
                        OutlinedTextField(userId, { userId = it }, label = { Text("Anmeldename") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(
                            pin, { pin = it }, label = { Text("PIN") }, singleLine = true,
                            visualTransformation = PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        if (needsProductId) {
                            OutlinedTextField(
                                productId, { productId = it }, label = { Text("FinTS-Produkt-ID") }, singleLine = true,
                                supportingText = { Text("Eigene ID aus den Einstellungen") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        } else {
                            Text("FinTS-Registrierung: GiroCrab (integriert) – keine Produkt-ID nötig.", style = MaterialTheme.typography.bodySmall)
                        }
                    } else {
                        Text("Du wirst zur Freigabe bei deiner Bank weitergeleitet.")
                    }
                }
            }
        },
        confirmButton = {
            if (!waitingTan) Button(enabled = canNext, onClick = {
                if (step < 2) step++ else {
                    onConnect(BankConnectRequest(bank!!, access, userId.trim(), pin, if (needsProductId) productId.trim() else null))
                    waitingTan = true
                }
            }) { Text(if (step < 2) "Weiter" else "Verbinden") }
        },
        dismissButton = {
            Row {
                if (step > 0 && !waitingTan) TextButton(onClick = { step-- }) { Text("Zurück") }
                TextButton(onClick = onDismiss) { Text(if (waitingTan) "Schließen" else "Abbrechen") }
            }
        },
    )
}

// ---------------------------------------------------------------------------------------------
// Rule editor (#759)
// ---------------------------------------------------------------------------------------------

private fun parseRuleCents(s: String): Long? =
    s.trim().replace(',', '.').toDoubleOrNull()?.let { Math.round(it * 100) }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RuleEditorDialog(
    state: AppUiState,
    initial: Rule?,
    onDismiss: () -> Unit,
    onSave: (Rule) -> Unit,
    /** Applies just this rule to uncategorized matches in the current scope; returns the count. */
    onApplyUncategorized: (Rule) -> Int,
) {
    val id = remember { initial?.id ?: "r_${System.nanoTime()}" }
    var field by remember { mutableStateOf(initial?.field ?: RuleField.Counterparty) }
    var kind by remember { mutableStateOf(initial?.matchKind ?: MatchKind.Contains) }
    var pattern by remember { mutableStateOf(initial?.pattern.orEmpty()) }
    var categoryId by remember { mutableStateOf(initial?.categoryId) }
    var tagIds by remember { mutableStateOf(initial?.tagIds ?: emptySet()) }
    var minText by remember { mutableStateOf(initial?.minCents?.let { "%.2f".format(it / 100.0) }.orEmpty()) }
    var maxText by remember { mutableStateOf(initial?.maxCents?.let { "%.2f".format(it / 100.0) }.orEmpty()) }
    var applied by remember { mutableStateOf<Int?>(null) }

    val rule = Rule(id, field, kind, pattern.trim(), categoryId, tagIds, initial?.enabled ?: true, parseRuleCents(minText), parseRuleCents(maxText))
    val scoped = state.scopedAccountIds
    val preview: List<Booking> = remember(rule, state.data.bookings, scoped) {
        state.data.bookings.filter { it.accountId in scoped && rule.matches(it) }
    }
    val uncategorized = preview.count { it.categoryId == null }
    val valid = categoryId != null && (pattern.isNotBlank() || rule.minCents != null || rule.maxCents != null)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (initial == null) "Neue Regel" else "Regel bearbeiten") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                EnumDropdown("Feld", field, RuleField.entries) { field = it }
                EnumDropdown("Vergleich", kind, MatchKind.entries) { kind = it }
                OutlinedTextField(pattern, { pattern = it }, label = { Text("Muster") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        minText, { minText = it }, label = { Text("Betrag ab") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        maxText, { maxText = it }, label = { Text("Betrag bis") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.weight(1f),
                    )
                }
                Text("Kategorie", style = MaterialTheme.typography.labelMedium)
                Row(Modifier.horizontalScrollCompat(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    state.data.categories.forEach { c ->
                        FilterChip(selected = categoryId == c.id, onClick = { categoryId = c.id }, label = { Text(c.name) })
                    }
                }
                if (state.data.tags.isNotEmpty()) {
                    Text("Tags", style = MaterialTheme.typography.labelMedium)
                    Row(Modifier.horizontalScrollCompat(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        state.data.tags.forEach { t ->
                            FilterChip(
                                selected = t.id in tagIds,
                                onClick = { tagIds = if (t.id in tagIds) tagIds - t.id else tagIds + t.id },
                                label = { Text(t.name) },
                            )
                        }
                    }
                }
                HorizontalDivider()
                Text("Vorschau: ${preview.size} Treffer, davon $uncategorized ohne Kategorie", style = MaterialTheme.typography.titleSmall)
                preview.take(5).forEach {
                    Text(
                        "${it.counterparty} – ${"%.2f".format(it.amountCents / 100.0)} €",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.alpha(if (state.privacyMode) 0f else 1f),
                    )
                }
                OutlinedButton(
                    enabled = valid && uncategorized > 0,
                    onClick = { applied = onApplyUncategorized(rule) },
                ) { Text("Auf unkategorisierte Treffer anwenden") }
                applied?.let { Text("$it Buchungen kategorisiert.", style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = { Button(enabled = valid, onClick = { onSave(rule); onDismiss() }) { Text("Speichern") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } },
    )
}

@Composable
private fun Modifier.horizontalScrollCompat(): Modifier =
    this.then(Modifier.horizontalScroll(rememberScrollState()))

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T : Enum<T>> EnumDropdown(label: String, value: T, options: List<T>, onSelect: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = value.name, onValueChange = {}, readOnly = true, label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
            modifier = Modifier.menuAnchor().fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { o -> DropdownMenuItem(text = { Text(o.name) }, onClick = { onSelect(o); open = false }) }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Tag & category managers
// ---------------------------------------------------------------------------------------------

@Composable
fun TagManagerDialog(state: AppUiState, onAdd: (String) -> Unit, onDelete: (String) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Tags verwalten") },
        text = {
            Column {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    OutlinedTextField(name, { name = it }, label = { Text("Neuer Tag") }, singleLine = true, modifier = Modifier.weight(1f))
                    TextButton(enabled = name.isNotBlank(), onClick = { onAdd(name); name = "" }) { Text("Hinzufügen") }
                }
                LazyColumn(Modifier.weight(1f, fill = false)) {
                    items(state.data.tags, key = { it.id }) { t ->
                        val uses = state.data.bookings.count { t.id in it.tagIds }
                        ListItem(
                            leadingContent = { Box(Modifier.size(14.dp).background(Color(t.colorHex), CircleShape)) },
                            headlineContent = { Text(t.name) },
                            supportingContent = { Text("$uses Buchungen") },
                            trailingContent = { IconButton(onClick = { onDelete(t.id) }) { Icon(Icons.Default.Delete, "Löschen") } },
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Fertig") } },
    )
}

@Composable
fun CategoryManagerDialog(
    state: AppUiState,
    onAdd: (name: String, parentId: String?) -> Unit,
    onDelete: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var parent by remember { mutableStateOf<String?>(null) }
    val roots = state.data.categories.filter { it.parentId == null }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Kategorien verwalten") },
        text = {
            Column {
                OutlinedTextField(name, { name = it }, label = { Text("Neue Kategorie") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(Modifier.horizontalScrollCompat(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilterChip(selected = parent == null, onClick = { parent = null }, label = { Text("Oberkategorie") })
                    roots.forEach { c -> FilterChip(selected = parent == c.id, onClick = { parent = c.id }, label = { Text("in ${c.name}") }) }
                }
                TextButton(enabled = name.isNotBlank(), onClick = { onAdd(name, parent); name = "" }) { Text("Hinzufügen") }
                LazyColumn(Modifier.weight(1f, fill = false)) {
                    val ordered = roots.flatMap { r -> listOf(r to 0) + state.data.categories.filter { it.parentId == r.id }.map { it to 1 } }
                    items(ordered, key = { it.first.id }) { (c, depth) ->
                        ListItem(
                            modifier = Modifier.padding(start = (depth * 20).dp),
                            leadingContent = { Box(Modifier.size(14.dp).background(Color(c.colorHex), CircleShape)) },
                            headlineContent = { Text(c.name) },
                            trailingContent = { IconButton(onClick = { onDelete(c.id) }) { Icon(Icons.Default.Delete, "Löschen") } },
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Fertig") } },
    )
}

// ---------------------------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------------------------

/**
 * Announcements come from the signed `policy/announcements.json`. [announcements] must already
 * be signature-verified by the caller; unverified content is never passed in.
 */
@Composable
fun AnnouncementsBanner(announcements: List<Announcement>, modifier: Modifier = Modifier) {
    var open by remember { mutableStateOf<Announcement?>(null) }
    val latest = announcements.maxByOrNull { it.date } ?: return
    Card(
        modifier.fillMaxWidth().clickable { open = latest },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer),
    ) {
        Column(Modifier.padding(12.dp)) {
            Text(latest.title, style = MaterialTheme.typography.titleSmall)
            Text(latest.date.format(DateTimeFormatter.ISO_LOCAL_DATE), style = MaterialTheme.typography.bodySmall)
        }
    }
    open?.let { a ->
        AlertDialog(
            onDismissRequest = { open = null },
            title = { Text(a.title) },
            text = { Text(a.body) },
            confirmButton = { TextButton(onClick = { open = null }) { Text("Schließen") } },
        )
    }
}

@Composable
fun SettingsScreen(
    state: AppUiState,
    onLanguage: (String) -> Unit,
    onTogglePrivacy: () -> Unit,
    onUseOwnFintsId: (Boolean) -> Unit,
    onFintsProductId: (String) -> Unit,
    onExportBackup: () -> Unit,
    onRestoreBackup: () -> Unit,
    onOpenRules: () -> Unit,
    onOpenTags: () -> Unit,
    onOpenCategories: () -> Unit,
    onAddBank: () -> Unit,
    verifiedAnnouncements: List<Announcement> = state.data.announcements,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        AnnouncementsBanner(verifiedAnnouncements)

        SettingsSection("Verwalten") {
            ListItem(headlineContent = { Text("Bank hinzufügen") }, modifier = Modifier.clickable(onClick = onAddBank))
            ListItem(headlineContent = { Text("Regeln (${state.data.rules.size})") }, modifier = Modifier.clickable(onClick = onOpenRules))
            ListItem(headlineContent = { Text("Kategorien (${state.data.categories.size})") }, modifier = Modifier.clickable(onClick = onOpenCategories))
            ListItem(headlineContent = { Text("Tags (${state.data.tags.size})") }, modifier = Modifier.clickable(onClick = onOpenTags))
        }

        SettingsSection("Allgemein") {
            Text("Sprache", style = MaterialTheme.typography.labelMedium)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("de" to "Deutsch", "en" to "English").forEachIndexed { i, (code, label) ->
                    SegmentedButton(
                        selected = state.language == code, onClick = { onLanguage(code) },
                        shape = SegmentedButtonDefaults.itemShape(i, 2),
                    ) { Text(label) }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Privatsphäre-Modus")
                    Text("Blendet Beträge aus und sperrt Screenshots.", style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = state.privacyMode, onCheckedChange = { onTogglePrivacy() })
            }
        }

        SettingsSection("FinTS-Produkt-ID") {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf(false to "GiroCrab (integriert)", true to "Eigene ID").forEachIndexed { i, (own, label) ->
                    SegmentedButton(
                        selected = state.useOwnFintsId == own, onClick = { onUseOwnFintsId(own) },
                        shape = SegmentedButtonDefaults.itemShape(i, 2),
                    ) { Text(label) }
                }
            }
            if (state.useOwnFintsId) {
                OutlinedTextField(
                    state.fintsProductId, onFintsProductId, label = { Text("Produkt-ID") },
                    singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
            } else {
                Text("Die integrierte Registrierung wird verwendet; es wird keine Produkt-ID abgefragt.", style = MaterialTheme.typography.bodySmall)
            }
        }

        SettingsSection("Verschlüsseltes Backup") {
            Text("Der Tresor wird unverändert (weiterhin verschlüsselt) exportiert.", style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onExportBackup, enabled = !state.demoActive) { Text("Exportieren") }
                OutlinedButton(onClick = onRestoreBackup, enabled = !state.demoActive) { Text("Wiederherstellen") }
            }
            if (state.demoActive) Text("Im Demo-Modus nicht verfügbar.", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            content()
        }
    }
}
