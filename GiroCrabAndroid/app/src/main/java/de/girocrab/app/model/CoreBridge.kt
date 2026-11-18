package de.girocrab.app.model

import java.time.LocalDate
import org.json.JSONObject
import kotlin.random.Random

/**
 * Bridge to `girocrab-core`. The UniFFI-generated Kotlin bindings (package `uniffi.girocrab_core`)
 * are mapped to the models here once they are built by scripts/build-rust-android.sh.
 * Until then (or if the native library is missing) the app falls back to a rich demo seed.
 */
interface CoreBridge {
    /** True when the native core is linked and can open a real vault. */
    val nativeAvailable: Boolean

    /** Opens the user's own vault. Returns null when native core is unavailable or the vault is empty/locked. */
    fun openOwnVault(): VaultSnapshot?

    /** Demo data (always available). */
    fun demoSnapshot(): VaultSnapshot
}

class DefaultCoreBridge : CoreBridge {
    override val nativeAvailable: Boolean = runCatching {
        Class.forName("uniffi.girocrab_core.Vault")
    }.isSuccess

    // TODO(parity): map uniffi Vault -> VaultSnapshot once bindings are generated.
    override fun openOwnVault(): VaultSnapshot? = null

    override fun demoSnapshot(): VaultSnapshot = DemoData.build()
}

/** Payment fields found by the core parser; `null` = not found. Mirrors `PaymentDetails` in girocrab-core. */
data class CorePaymentDetails(
    val name: String?,
    val iban: String?,
    val bic: String?,
    val amountCents: Long?,
    val purpose: String?,
)

/**
 * Payment parser of `girocrab-core` (`payment_input.rs`), shared with the other front ends.
 * Like [DefaultCoreBridge] it reaches the UniFFI bindings by reflection, so the app builds and runs without
 * the native library; every function then returns null and the caller falls back to its own parser.
 * UniFFI puts the top-level functions of the namespace `girocrab_core` into the file `girocrab_core.kt`
 * (JVM class `Girocrab_coreKt`) and names them in lowerCamelCase; record fields become getters.
 * Never log the text: it is clipboard or QR content.
 */
object CorePaymentParser {
    private val bindings: Class<*>? by lazy {
        runCatching { Class.forName("uniffi.girocrab_core.Girocrab_coreKt") }.getOrNull()
    }

    /** EPC QR (GiroCode) payload, or null when it is none or the core is unavailable. */
    fun parseEpcPayload(payload: String): CorePaymentDetails? = call("parseEpcPayload", payload)

    /** Free text (clipboard): IBAN with valid checksum, BIC, amount, name and purpose. */
    fun parsePaymentText(text: String): CorePaymentDetails? = call("parsePaymentText", text)

    private fun call(function: String, input: String): CorePaymentDetails? = runCatching {
        val cls = bindings ?: return@runCatching null
        val record = cls.getMethod(function, String::class.java).invoke(null, input) ?: return@runCatching null
        fun field(getter: String): Any? = record.javaClass.getMethod(getter).invoke(record)
        CorePaymentDetails(
            name = field("getName") as String?,
            iban = field("getIban") as String?,
            bic = field("getBic") as String?,
            amountCents = (field("getAmountCents") as Number?)?.toLong(),
            purpose = field("getPurpose") as String?,
        )
    }.getOrNull()
}

/** Realistic German demo data across 7 banks. Deterministic (seeded). */
object AnnouncementLoader {
    /** Parses `policy/announcements.json` (bundled as a Java resource). Signature verification is the caller's job. */
    fun load(today: LocalDate = LocalDate.now(), lang: String = "de", version: String = "0.8.5"): List<Announcement> = runCatching {
        val raw = AnnouncementLoader::class.java.classLoader?.getResourceAsStream("announcements.json")
            ?.bufferedReader()?.use { it.readText() } ?: return emptyList()
        val arr = JSONObject(raw).getJSONArray("announcements")
        fun JSONObject.text(k: String): String = optJSONObject(k)?.let { it.optString(lang).ifBlank { it.optString("en") } } ?: optString(k)
        (0 until arr.length()).map { arr.getJSONObject(it) }.mapNotNull { o ->
            val until = o.optString("until").takeIf { it.isNotBlank() }?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            if (until != null && until.isBefore(today)) return@mapNotNull null
            Announcement(o.getString("id"), o.text("title"), o.text("body").ifBlank { o.text("summary") }, today, o.optString("link").takeIf { it.isNotBlank() })
        }
    }.getOrDefault(emptyList())
}

object DemoData {
    private fun cat(id: String, name: String, color: Long, icon: String, budget: Long? = null, parent: String? = null) =
        Category(id, name, parent, color, icon, budget)

    val categories = listOf(
        cat("c_income", "Einkommen", 0xFF2E7D32, "payments"),
        cat("c_rent", "Wohnen & Miete", 0xFF6D4C41, "home", 95_000),
        cat("c_groc", "Lebensmittel", 0xFF43A047, "shopping_cart", 40_000),
        cat("c_dining", "Restaurants & Café", 0xFFEF6C00, "restaurant", 15_000),
        cat("c_mobil", "Mobilität", 0xFF1E88E5, "directions_car", 20_000),
        cat("c_ins", "Versicherungen", 0xFF5E35B1, "shield"),
        cat("c_sub", "Abos & Medien", 0xFFD81B60, "subscriptions", 5_000),
        cat("c_shop", "Shopping", 0xFF8E24AA, "shopping_bag", 15_000),
        cat("c_energy", "Strom & Internet", 0xFFFDD835, "bolt"),
        cat("c_travel", "Reisen", 0xFF00ACC1, "flight"),
        cat("c_save", "Sparen & Anlage", 0xFF00897B, "savings"),
        cat("c_health", "Gesundheit", 0xFFE53935, "favorite"),
    )

    val tags = listOf(
        Tag("t_tax", "Steuerlich relevant", 0xFF455A64),
        Tag("t_vac", "Urlaub 2026", 0xFF00ACC1),
        Tag("t_fix", "Fixkosten", 0xFF6D4C41),
        Tag("t_refund", "Erstattung offen", 0xFFEF6C00),
    )

    val rules = listOf(
        Rule("r1", RuleField.Counterparty, MatchKind.Contains, "REWE", "c_groc"),
        Rule("r2", RuleField.Counterparty, MatchKind.Contains, "EDEKA", "c_groc"),
        Rule("r3", RuleField.Counterparty, MatchKind.Contains, "LIDL", "c_groc"),
        Rule("r4", RuleField.Counterparty, MatchKind.Contains, "Deutsche Bahn", "c_mobil", setOf("t_vac")),
        Rule("r5", RuleField.Counterparty, MatchKind.Contains, "Netflix", "c_sub", setOf("t_fix")),
        Rule("r6", RuleField.Counterparty, MatchKind.Contains, "Spotify", "c_sub", setOf("t_fix")),
        Rule("r7", RuleField.Purpose, MatchKind.Contains, "Gehalt", "c_income"),
        Rule("r8", RuleField.Counterparty, MatchKind.Contains, "Vattenfall", "c_energy", setOf("t_fix")),
        Rule("r9", RuleField.Counterparty, MatchKind.Contains, "Amazon", "c_shop"),
        Rule("r10", RuleField.Counterparty, MatchKind.Contains, "Allianz", "c_ins", setOf("t_fix")),
    )

    fun build(today: LocalDate = LocalDate.now()): VaultSnapshot {
        val rnd = Random(42)
        val groups = listOf(
            AccountGroup("g_spk", "Sparkasse", ConnectorKind.FinTS, 0xFFE53935),
            AccountGroup("g_ing", "ING", ConnectorKind.FinTS, 0xFFFF6200),
            AccountGroup("g_dkb", "DKB", ConnectorKind.EnableBanking, 0xFF1E88E5),
            AccountGroup("g_cbk", "Commerzbank", ConnectorKind.FinTS, 0xFFFBC02D),
            AccountGroup("g_cdi", "comdirect", ConnectorKind.Comdirect, 0xFFF9A825),
            AccountGroup("g_tr", "Trade Republic", ConnectorKind.TradeRepublic, 0xFF212121),
            AccountGroup("g_pp", "PayPal", ConnectorKind.PayPal, 0xFF003087),
        )
        val accounts = listOf(
            Account("a_spk", "g_spk", "Sparkasse", "Girokonto", "DE89370400440532013000", AccountKind.Giro, 284_512, holder = "Max Mustermann"),
            Account("a_ing", "g_ing", "ING", "Extra-Konto", "DE02500105170137075030", AccountKind.Savings, 1_250_000),
            Account("a_dkb", "g_dkb", "DKB", "Visa Kreditkarte", "DE12120300001234567890", AccountKind.CreditCard, -64_230),
            Account("a_cbk", "g_cbk", "Commerzbank", "Girokonto", "DE75512108001245126199", AccountKind.Giro, 91_877),
            Account("a_cdi", "g_cdi", "comdirect", "Verrechnungskonto", "DE68210501700012345678", AccountKind.Giro, 342_050),
            Account("a_tr", "g_tr", "Trade Republic", "Depot", null, AccountKind.Depot, 0),
            Account("a_pp", "g_pp", "PayPal", "PayPal-Konto", null, AccountKind.Wallet, 12_340),
        )

        val bookings = mutableListOf<Booking>()
        var n = 0
        fun add(acc: String, date: LocalDate, cents: Long, who: String, purpose: String, cat: String? = null, tags: Set<String> = emptySet()) {
            val i = n++
            bookings += Booking(
                "b$i", acc, date, amountCents = cents, counterparty = who, purpose = purpose, categoryId = cat, tagIds = tags,
                checked = !(date.isAfter(today.minusDays(20)) && i % 3 == 0),
                documentCount = if (cat == "c_ins" || cat == "c_shop" || cat == "c_travel") 1 else 0,
            )
        }

        for (m in 0 until 12) {
            val first = today.minusMonths(m.toLong()).withDayOfMonth(1)
            fun d(day: Int) = first.plusDays((day - 1).toLong().coerceAtMost(first.lengthOfMonth() - 1L)).let { if (it.isAfter(today)) today else it }
            add("a_spk", d(1), 385_000, "Muster GmbH", "Gehalt ${first.month.value}/${first.year}", "c_income")
            add("a_spk", d(2), -98_000, "Hausverwaltung Berlin", "Miete ${first.month.value}/${first.year}", "c_rent", setOf("t_fix"))
            add("a_spk", d(5), -7_890, "Vattenfall Strom", "Abschlag Kundennr. 40012345", "c_energy", setOf("t_fix"))
            add("a_cbk", d(6), -3_999, "Telekom Deutschland", "Internet & Mobilfunk", "c_energy", setOf("t_fix"))
            add("a_dkb", d(7), -1_299, "Netflix", "Abo", "c_sub", setOf("t_fix"))
            add("a_dkb", d(8), -999, "Spotify", "Premium", "c_sub", setOf("t_fix"))
            add("a_cbk", d(10), -12_450, "Allianz Versicherung", "Haftpflicht/Hausrat", "c_ins", setOf("t_fix"))
            add("a_cdi", d(15), -50_000, "Trade Republic", "Sparplan Überweisung", "c_save")
            add("a_ing", d(16), 30_000, "Eigenübertrag", "Sparrate", "c_save")
            repeat(7 + rnd.nextInt(4)) {
                val store = listOf("REWE Markt", "EDEKA Center", "LIDL Dienstleistung", "dm-drogerie markt", "Bäckerei Schmidt").random(rnd)
                add(listOf("a_spk", "a_dkb").random(rnd), d(1 + rnd.nextInt(27)), -(1_200L + rnd.nextInt(7_500)), store, "Kartenzahlung $store", "c_groc")
            }
            repeat(3 + rnd.nextInt(3)) {
                val p = listOf("Restaurant Zur Linde", "Café Einstein", "Burgerei", "Vapiano").random(rnd)
                add("a_dkb", d(1 + rnd.nextInt(27)), -(1_800L + rnd.nextInt(5_500)), p, "Kartenzahlung $p", "c_dining")
            }
            repeat(1 + rnd.nextInt(3)) {
                add("a_pp", d(1 + rnd.nextInt(27)), -(1_990L + rnd.nextInt(12_000)), "Amazon EU S.a.r.l.", "Bestellung 302-${rnd.nextInt(1_000_000)}", "c_shop")
            }
            add("a_cbk", d(12), -(3_200L + rnd.nextInt(6_000)), "Deutsche Bahn", "Fahrkarte", "c_mobil")
            add("a_spk", d(20), -(5_000L + rnd.nextInt(5_500)), "Shell Tankstelle", "Kartenzahlung Kraftstoff", "c_mobil")
            if (m % 4 == 2) add("a_dkb", d(18), -(18_000L + rnd.nextInt(30_000)), "Booking.com", "Hotel Reservierung", "c_travel", setOf("t_vac"))
            if (m % 5 == 1) add("a_pp", d(22), 4_500, "Kleinanzeigen Käufer", "Verkauf Fahrrad", null, setOf("t_refund"))
            if (m % 3 == 0) add("a_cbk", d(25), -2_850, "Apotheke am Markt", "Rezeptzuzahlung", "c_health", setOf("t_tax"))
        }
        val sorted = bookings.sortedByDescending { it.bookingDate }

        val holdings = listOf(
            Holding("h1", "a_tr", "iShares Core MSCI World", "IE00B4L5Y983", 42.35, 9_812, 360_000),
            Holding("h2", "a_tr", "Vanguard FTSE All-World", "IE00BK5BQT80", 28.10, 12_054, 300_000),
            Holding("h3", "a_tr", "Xtrackers MSCI Emerging Markets", "IE00BTJRMP35", 55.0, 5_430, 270_000),
            Holding("h4", "a_tr", "Apple Inc.", "US0378331005", 12.0, 23_150, 24_000, wkn = "865985", currency = "USD", fxRateToEur = 0.92),
            Holding("h5", "a_tr", "iShares MSCI World (USD)", "IE00B0M62Q58", 20.0, 11_240, 19_500, currency = "USD", fxRateToEur = 0.92),
        )
        return VaultSnapshot(
            groups = groups,
            accounts = accounts.map { if (it.kind == AccountKind.Depot) it.copy(balanceCents = holdings.sumOf { h -> h.valueCents }) else it },
            bookings = sorted,
            categories = categories,
            tags = tags,
            rules = rules,
            standingOrders = listOf(
                StandingOrder("so1", "a_spk", "Hausverwaltung Berlin", "DE44500105175407324931", -98_000, Interval.Monthly, today.withDayOfMonth(1).plusMonths(1), "Miete"),
                StandingOrder("so2", "a_cdi", "Trade Republic", "DE86100123456789012345", -50_000, Interval.Monthly, today.withDayOfMonth(15).plusMonths(if (today.dayOfMonth > 15) 1 else 0), "Sparplan"),
                StandingOrder("so3", "a_cbk", "Allianz Versicherung", "DE23100400000123456789", -12_450, Interval.Quarterly, today.plusMonths(1), "Versicherung"),
            ),
            mandates = listOf(
                DirectDebitMandate("m1", "a_spk", "Vattenfall Europe Sales", "DE12ZZZ00000012345", "VAT-2024-0042", today.minusYears(2), today.withDayOfMonth(5)),
                DirectDebitMandate("m2", "a_cbk", "Telekom Deutschland GmbH", "DE98ZZZ00000054321", "TEL-7781234", today.minusYears(3), today.withDayOfMonth(6)),
                DirectDebitMandate("m3", "a_dkb", "Netflix International B.V.", "NL08ZZZ0000001234", "NFX-5599", today.minusYears(1), today.withDayOfMonth(7)),
            ),
            holdings = holdings,
            loans = listOf(ManualLoan("l1", "Autokredit", 1_800_000, 1_120_000, 3.9, 38_500, today.minusYears(2))),
            assets = listOf(
                TangibleAsset("ta1", "Fahrrad (E-Bike)", 180_000, today.minusYears(1), "Kaufbeleg im Ordner"),
                TangibleAsset("ta2", "Pkw", 1_450_000, today.minusYears(3)),
            ),
            announcements = AnnouncementLoader.load(today).ifEmpty {
                listOf(Announcement("n1", "Willkommen bei GiroCrab", "Du siehst Demodaten. Verbinde eine Bank oder öffne deinen Tresor, um echte Umsätze zu nutzen.", today))
            },
        )
    }
}
