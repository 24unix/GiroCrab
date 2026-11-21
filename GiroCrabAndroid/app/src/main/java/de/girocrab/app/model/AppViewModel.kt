package de.girocrab.app.model

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.girocrab.app.ui.screens.SepaTransferDraft
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class VaultState { Locked, Demo, Own }

data class AppUiState(
    val vaultState: VaultState = VaultState.Locked,
    /** True once the own vault may contain real data; demo must then never overwrite it. */
    val vaultMayHoldRealData: Boolean = false,
    val loading: Boolean = false,
    val privacyMode: Boolean = false,
    val data: VaultSnapshot = VaultSnapshot(),
    val scope: Scope = Scope.All,
    val search: String = "",
    val filter: BookingFilter = BookingFilter(),
    val error: String? = null,
    val language: String = "de",
    /** #789: false = GiroCrab's built-in FinTS registration (no product ID asked). */
    val useOwnFintsId: Boolean = false,
    val fintsProductId: String = "",
) {
    val demoActive get() = vaultState == VaultState.Demo
    val isUnlocked get() = vaultState != VaultState.Locked

    val selectedAccountId get() = (scope as? Scope.OneAccount)?.accountId

    val scopedAccountIds: Set<String>
        get() = when (val s = scope) {
            Scope.All -> data.accounts.map { it.id }.toSet()
            is Scope.Group -> data.accounts.filter { it.groupId == s.groupId }.map { it.id }.toSet()
            is Scope.OneAccount -> setOf(s.accountId)
        }

    val totalBalanceCents get() = data.accounts.filter { it.id in scopedAccountIds }.sumOf { it.balanceCents }
}

class AppViewModel(private val core: CoreBridge = DefaultCoreBridge()) : ViewModel() {
    private val _state = MutableStateFlow(AppUiState())
    val state: StateFlow<AppUiState> = _state.asStateFlow()

    /** Bookings after scope, search and filter, newest first. */
    val visibleBookings: StateFlow<List<Booking>> = _state
        .map { filterBookings(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    // Own vault snapshot is kept while demo is shown so switching back loses nothing.
    private var ownSnapshot: VaultSnapshot? = null

    init { bootstrap() }

    // ---- Vault lifecycle ----

    fun bootstrap() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true) }
            // No vault is opened here anymore: the own vault needs the device key, and that only
            // comes back from the biometric gate (#1428, 2.2/2.4). Until then the app starts in
            // demo mode, which is exactly what it did while `openOwnVault()` returned null.
            showDemo()
        }
    }

    private fun adoptOwn(snapshot: VaultSnapshot) {
        ownSnapshot = snapshot
        _state.update {
            it.copy(
                vaultState = VaultState.Own, vaultMayHoldRealData = true, loading = false,
                data = snapshot, scope = Scope.All, filter = BookingFilter(), search = "", error = null,
            )
        }
    }

    fun showDemo() {
        viewModelScope.launch {
            val demo = withContext(Dispatchers.Default) { core.demoSnapshot() }
            _state.update {
                it.copy(
                    vaultState = VaultState.Demo, loading = false, data = demo,
                    scope = Scope.All, filter = BookingFilter(), search = "", error = null,
                )
            }
        }
    }

    fun showOwnVault() {
        val own = ownSnapshot
        if (own != null) adoptOwn(own) else bootstrap()
    }

    fun lock() {
        ownSnapshot = null
        _state.update { AppUiState(privacyMode = it.privacyMode, vaultMayHoldRealData = it.vaultMayHoldRealData) }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    // ---- Selection / search / filters ----

    fun togglePrivacy() = _state.update { it.copy(privacyMode = !it.privacyMode) }
    fun selectAll() = _state.update { it.copy(scope = Scope.All) }
    fun selectGroup(groupId: String) = _state.update { it.copy(scope = Scope.Group(groupId)) }
    fun selectAccount(accountId: String) = _state.update { it.copy(scope = Scope.OneAccount(accountId)) }
    fun setSearch(text: String) = _state.update { it.copy(search = text) }
    fun setFilter(filter: BookingFilter) = _state.update { it.copy(filter = filter) }
    fun resetFilter() = _state.update { it.copy(filter = BookingFilter(), search = "") }

    // ---- Editing (categories, tags, notes, rules) ----

    private fun editData(f: (VaultSnapshot) -> VaultSnapshot) {
        _state.update { s ->
            val next = f(s.data)
            if (s.vaultState == VaultState.Own) ownSnapshot = next
            s.copy(data = next)
        }
    }

    private fun editBooking(id: String, f: (Booking) -> Booking) =
        editData { d -> d.copy(bookings = d.bookings.map { if (it.id == id) f(it) else it }) }

    fun setCategory(bookingId: String, categoryId: String?) =
        editBooking(bookingId) { it.copy(categoryId = categoryId, categoryByRule = false) }

    fun toggleTag(bookingId: String, tagId: String) =
        editBooking(bookingId) { it.copy(tagIds = if (tagId in it.tagIds) it.tagIds - tagId else it.tagIds + tagId) }

    fun toggleBookingChecked(id: String) = editBooking(id) { it.copy(checked = !it.checked) }

    /** Books a SEPA transfer as an outgoing booking and reduces the account balance (Demo/Own). */
    fun submitTransfer(draft: SepaTransferDraft) {
        val date = draft.executionDate ?: java.time.LocalDate.now()
        val amount = -kotlin.math.abs(draft.amountCents)
        editData { d ->
            val booking = Booking(
                id = "b_tr_${System.nanoTime()}", accountId = draft.accountId, bookingDate = date,
                amountCents = amount, counterparty = draft.recipient, purpose = draft.purpose,
                isTransfer = true, transferReason = draft.purpose, counterpartyIban = draft.iban,
            )
            d.copy(
                bookings = (d.bookings + booking).sortedByDescending { it.bookingDate },
                accounts = d.accounts.map { if (it.id == draft.accountId) it.copy(balanceCents = it.balanceCents + amount) else it },
            )
        }
    }

    fun setNote(bookingId: String, note: String) = editBooking(bookingId) { it.copy(note = note) }

    fun setSplits(bookingId: String, splits: List<SplitPart>) = editBooking(bookingId) { it.copy(splits = splits) }

    fun addTag(name: String, colorHex: Long = 0xFF1976D2) {
        if (name.isBlank()) return
        editData { it.copy(tags = it.tags + Tag("t_${System.nanoTime()}", name.trim(), colorHex)) }
    }

    fun deleteTag(tagId: String) = editData { d ->
        d.copy(
            tags = d.tags.filterNot { it.id == tagId },
            bookings = d.bookings.map { it.copy(tagIds = it.tagIds - tagId) },
            rules = d.rules.map { it.copy(tagIds = it.tagIds - tagId) },
        )
    }

    fun addCategory(name: String, colorHex: Long = 0xFF607D8B, parentId: String? = null) {
        if (name.isBlank()) return
        editData { it.copy(categories = it.categories + Category("c_${System.nanoTime()}", name.trim(), parentId, colorHex)) }
    }

    fun deleteCategory(categoryId: String) = editData { d ->
        d.copy(
            categories = d.categories.filterNot { it.id == categoryId }.map { if (it.parentId == categoryId) it.copy(parentId = null) else it },
            bookings = d.bookings.map { if (it.categoryId == categoryId) it.copy(categoryId = null) else it },
            rules = d.rules.filterNot { it.categoryId == categoryId },
        )
    }

    fun upsertRule(rule: Rule) = editData { d ->
        val exists = d.rules.any { it.id == rule.id }
        d.copy(rules = if (exists) d.rules.map { if (it.id == rule.id) rule else it } else d.rules + rule)
    }

    fun upsertLoan(loan: ManualLoan) = editData { d ->
        d.copy(loans = if (d.loans.any { it.id == loan.id }) d.loans.map { if (it.id == loan.id) loan else it } else d.loans + loan)
    }

    fun deleteLoan(id: String) = editData { d -> d.copy(loans = d.loans.filterNot { it.id == id }) }

    fun upsertAsset(asset: TangibleAsset) = editData { d ->
        d.copy(assets = if (d.assets.any { it.id == asset.id }) d.assets.map { if (it.id == asset.id) asset else it } else d.assets + asset)
    }

    fun deleteAsset(id: String) = editData { d -> d.copy(assets = d.assets.filterNot { it.id == id }) }

    fun deleteRule(ruleId: String) = editData { d -> d.copy(rules = d.rules.filterNot { it.id == ruleId }) }

    /** Applies enabled rules to uncategorized bookings (never overrides manual categories). Returns count changed. */
    fun applyRules(): Int {
        var changed = 0
        editData { d ->
            val active = d.rules.filter { it.enabled }
            d.copy(bookings = d.bookings.map { b ->
                if (b.categoryId != null) return@map b
                val r = active.firstOrNull { it.matches(b) } ?: return@map b
                changed++
                b.copy(categoryId = r.categoryId, categoryByRule = true, tagIds = b.tagIds + r.tagIds)
            })
        }
        return changed
    }

    /** Scoped apply (#759): only this rule, only uncategorized bookings in the current scope. Returns count. */
    fun applyRuleToUncategorized(rule: Rule): Int {
        var changed = 0
        val scoped = _state.value.scopedAccountIds
        editData { d ->
            d.copy(bookings = d.bookings.map { b ->
                if (b.categoryId != null || b.accountId !in scoped || !rule.matches(b)) return@map b
                changed++
                b.copy(categoryId = rule.categoryId, categoryByRule = true, tagIds = b.tagIds + rule.tagIds)
            })
        }
        return changed
    }

    // ---- Settings ----

    fun setLanguage(lang: String) = _state.update { it.copy(language = lang) }
    fun setOwnFintsId(own: Boolean) = _state.update { it.copy(useOwnFintsId = own) }
    fun setFintsProductId(id: String) = _state.update { it.copy(fintsProductId = id.trim()) }

    // ---- Derived values ----

    fun category(id: String?): Category? = id?.let { i -> _state.value.data.categories.firstOrNull { it.id == i } }
    fun account(id: String): Account? = _state.value.data.accounts.firstOrNull { it.id == id }

    /** Sum of expenses per category (cents, positive) for the current scope + filter. */
    fun spendingByCategory(): Map<String?, Long> =
        filterBookings(_state.value).filter { it.amountCents < 0 }
            .groupBy { it.categoryId }
            .mapValues { (_, v) -> -v.sumOf { it.amountCents } }

    fun netWorthCents(): Long {
        val d = _state.value.data
        return d.accounts.filterNot { it.hidden }.sumOf { it.balanceCents } +
            d.assets.sumOf { it.valueCents } - d.loans.sumOf { it.remainingCents }
    }

    companion object {
        fun filterBookings(s: AppUiState): List<Booking> {
            val ids = s.scopedAccountIds
            val f = s.filter
            val q = s.search.trim()
            return s.data.bookings.asSequence()
                .filter { it.accountId in ids }
                .filter { b ->
                    when (f.direction) {
                        Direction.Any -> true
                        Direction.Income -> b.amountCents > 0
                        Direction.Expense -> b.amountCents < 0
                    }
                }
                .filter { f.minCents == null || kotlin.math.abs(it.amountCents) >= f.minCents }
                .filter { f.maxCents == null || kotlin.math.abs(it.amountCents) <= f.maxCents }
                .filter { f.categoryId == null || it.categoryId == f.categoryId }
                .filter { f.tagId == null || f.tagId in it.tagIds }
                .filter { !f.uncategorizedOnly || it.categoryId == null }
                .filter { f.from == null || !it.bookingDate.isBefore(f.from) }
                .filter { f.to == null || !it.bookingDate.isAfter(f.to) }
                .filter { b ->
                    q.isEmpty() || listOf(b.counterparty, b.purpose, b.note, b.reference.orEmpty())
                        .any { it.contains(q, ignoreCase = true) }
                }
                .sortedByDescending { it.bookingDate }
                .toList()
        }
    }
}
