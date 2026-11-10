//! Localisation of user-facing core texts (German source, English translation).
//!
//! German is the source language and the default. Every user-facing string is
//! written in German at its call site and routed through [`tr`] (static text)
//! or [`trf`] (text with `{0}`, `{1}` … placeholders). The English text is
//! looked up in [`english`]; a missing entry falls back to German, and a unit
//! test makes sure every `tr`/`trf` literal in the crate has an entry.
//!
//! The Swift app calls [`set_language`] once at start-up with
//! `Locale.preferredLanguages.first`. Tests never touch the process-wide
//! language: they use [`tr_in`] or [`with_language`] (a thread-local
//! override), so tests asserting German messages stay deterministic while
//! `cargo test` runs them in parallel threads.
//!
//! Built-in account group and starter category names are stored in German in
//! the vault (the code finds groups by name and classifies bookings by the
//! top-level category name). They are translated only on the way out via
//! [`display_name`] / [`display_path`], so user-renamed entries stay as written.

use std::cell::Cell;
use std::fmt::Display;
use std::sync::atomic::{AtomicU8, Ordering};

/// UI language of the core texts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    De,
    En,
}

impl Lang {
    fn to_u8(self) -> u8 {
        match self {
            Lang::De => 0,
            Lang::En => 1,
        }
    }
    fn from_u8(v: u8) -> Lang {
        if v == 1 {
            Lang::En
        } else {
            Lang::De
        }
    }
}

static LANGUAGE: AtomicU8 = AtomicU8::new(0);

thread_local! {
    static OVERRIDE: Cell<Option<Lang>> = const { Cell::new(None) };
}

/// Maps a BCP-47 tag ("en-US", "de-DE", "en") to a supported language:
/// any `en*` tag is English, everything else German.
pub fn parse_language(code: &str) -> Lang {
    let code = code.trim().to_ascii_lowercase();
    let primary = code.split(['-', '_']).next().unwrap_or("");
    if primary == "en" {
        Lang::En
    } else {
        Lang::De
    }
}

/// Sets the process-wide language of all core texts (BCP-47 tag, e.g.
/// "en-US" or "de-DE"). Any `en*` tag selects English, everything else German.
#[uniffi::export]
pub fn set_language(code: String) {
    LANGUAGE.store(parse_language(&code).to_u8(), Ordering::Relaxed);
}

/// The language in effect on this thread.
pub fn current() -> Lang {
    OVERRIDE
        .with(|o| o.get())
        .unwrap_or_else(|| Lang::from_u8(LANGUAGE.load(Ordering::Relaxed)))
}

/// Runs `f` with `lang` as the language of the current thread only
/// (for tests; the process-wide setting is left untouched).
pub fn with_language<R>(lang: Lang, f: impl FnOnce() -> R) -> R {
    struct Reset(Option<Lang>);
    impl Drop for Reset {
        fn drop(&mut self) {
            OVERRIDE.with(|o| o.set(self.0));
        }
    }
    let _reset = Reset(OVERRIDE.with(|o| o.replace(Some(lang))));
    f()
}

/// Translates a static German text into the current language.
pub fn tr(de: &'static str) -> &'static str {
    tr_in(current(), de)
}

/// Translates a static German text into `lang` (pure; used by tests).
pub fn tr_in(lang: Lang, de: &'static str) -> &'static str {
    match lang {
        Lang::De => de,
        Lang::En => english(de).unwrap_or(de),
    }
}

/// Translates a German template and fills its `{0}`, `{1}` … placeholders.
pub fn trf(de: &'static str, args: &[&dyn Display]) -> String {
    trf_in(current(), de, args)
}

/// [`trf`] for an explicit language.
pub fn trf_in(lang: Lang, de: &'static str, args: &[&dyn Display]) -> String {
    fill(tr_in(lang, de), args)
}

fn fill(template: &str, args: &[&dyn Display]) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let idx = after
            .find('}')
            .and_then(|end| after[..end].parse::<usize>().ok().map(|i| (i, end)));
        match idx {
            Some((i, end)) if i < args.len() => {
                out.push_str(&args[i].to_string());
                rest = &after[end + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Display name of a stored account group or category name: built-in German
/// defaults are translated, anything else (user names) is returned as is.
pub fn display_name(stored: &str) -> String {
    display_name_in(current(), stored)
}

pub fn display_name_in(lang: Lang, stored: &str) -> String {
    match lang {
        Lang::De => stored.to_string(),
        Lang::En => default_name_en(stored).unwrap_or(stored).to_string(),
    }
}

/// [`display_name`] for every segment of a "Parent › Child" category path.
pub fn display_path(path: &str) -> String {
    display_path_in(current(), path)
}

pub fn display_path_in(lang: Lang, path: &str) -> String {
    match lang {
        Lang::De => path.to_string(),
        Lang::En => path
            .split(" › ")
            .map(|p| display_name_in(lang, p))
            .collect::<Vec<_>>()
            .join(" › "),
    }
}

/// English names of the built-in account groups (`connectors::group_for`) and
/// the starter categories (`demo.rs`). Keys are the German names stored in
/// the vault.
fn default_name_en(de: &str) -> Option<&'static str> {
    Some(match de {
        // Account groups (sidebar sections).
        "Giro & Tagesgeld" => "Checking & savings",
        "Kreditkarten" => "Credit cards",
        "Depots & ETFs" => "Portfolios & ETFs",
        "Darlehen & Kredite" => "Loans",
        "Importierte Konten" => "Imported accounts",
        // Starter categories.
        "Einnahmen" => "Income",
        "Gehalt" => "Salary",
        "Zinsen & Dividenden" => "Interest & dividends",
        "Erstattungen" => "Refunds",
        "Sonstige Einnahmen" => "Other income",
        "Wohnen & Energie" => "Housing & utilities",
        "Miete" => "Rent",
        "Energie" => "Energy",
        "Internet & Telefon" => "Internet & phone",
        "Haushalt" => "Household",
        "Lebensmittel" => "Food",
        "Supermarkt" => "Supermarket",
        "Bäcker & Metzger" => "Bakery & butcher",
        "Lebensmittelrettung" => "Food rescue",
        "Restaurants & Cafés" => "Restaurants & cafés",
        "Lieferdienste" => "Food delivery",
        "Mobilität" => "Transport",
        "ÖPNV & Bahn" => "Public transport & rail",
        "Tanken" => "Fuel",
        "Fahrrad" => "Bike",
        "Reisen" => "Travel",
        "Einkaufen" => "Shopping",
        "Online-Shopping" => "Online shopping",
        "Elektronik" => "Electronics",
        "Drogerie" => "Drugstore",
        "Freizeit" => "Leisure",
        "Streaming & Musik" => "Streaming & music",
        "Sport & Fitness" => "Sports & fitness",
        "Spiele" => "Games",
        "Versicherungen" => "Insurance",
        "Krankenversicherung" => "Health insurance",
        "Haftpflicht & Hausrat" => "Liability & home insurance",
        "Mitgliedschaften" => "Memberships",
        "Gebühren & Bargeld" => "Fees & cash",
        "Bankgebühren" => "Bank fees",
        "Bargeld" => "Cash",
        "Kredite & Darlehen" => "Loans & credit",
        "Darlehensraten" => "Loan payments",
        "Sparen & Investieren" => "Saving & investing",
        "ETF-Sparpläne" => "ETF savings plans",
        "Krypto" => "Crypto",
        "Aktien" => "Stocks",
        "Saveback & Round up" => "Saveback & round up",
        "Umbuchungen" => "Transfers",
        "Kreditkartenabrechnung" => "Credit card statement",
        "Tagesgeld" => "Savings account",
        "Eigene Konten" => "Own accounts",
        _ => return None,
    })
}

/// English text for a German source string; `None` = no translation.
fn english(de: &str) -> Option<&'static str> {
    Some(match de {
        // ------------------------------------------------------------ error.rs
        "Datenbankfehler: {0}" => "Database error: {0}",
        "Der Tresor konnte nicht entsperrt werden (falscher Schlüssel oder beschädigte Datei)" => {
            "The vault could not be unlocked (wrong key or damaged file)"
        }
        "Nicht gefunden: {0}" => "Not found: {0}",
        "Ungültige Eingabe: {0}" => "Invalid input: {0}",
        "Einstellung fehlt: {0}. Bitte in den Einstellungen eintragen." => {
            "Missing setting: {0}. Please enter it in Settings."
        }
        "Netzwerkfehler: {0}" => "Network error: {0}",
        "Die Bank hat die Anfrage abgelehnt: {0} {1}" => "The bank rejected the request: {0} {1}",
        "Anmeldung fehlgeschlagen: {0}" => "Sign-in failed: {0}",
        "Protokollfehler: {0}" => "Protocol error: {0}",
        "Browser-Anmeldung nötig: {0}" => "Browser sign-in required: {0}",
        "Dieser Abruf ist nicht mehr aktiv" => "This sync is no longer active",
        // ------------------------------------------------------------ connectors/mod.rs
        "VR-NetKey oder Alias" => "VR-NetKey or alias",
        "Online-Banking-PIN" => "Online banking PIN",
        "Die BLZ muss aus genau 8 Ziffern bestehen." => "The bank code (BLZ) must be exactly 8 digits.",
        "Die FinTS-URL muss mit https:// beginnen." => "The FinTS URL must start with https://.",
        "FinTS-Bank" => "FinTS bank",
        "Anmeldename / VR-NetKey / Kontonummer" => "Login name / VR-NetKey / account number",
        "Beliebige FinTS-3.0-Bank (PIN/TAN). BLZ und FinTS-URL stehen im Bankzugang." => "Any FinTS 3.0 (PIN/TAN) bank. Bank code and FinTS URL are stored with the login.",
        "Freigabe in der SecureGo-plus-App (Decoupled, TAN-Prozess 4, HKTAN v7). Server: fints1.atruvia.de" => "Approve in the SecureGo plus app (decoupled, TAN process 4, HKTAN v7). Server: fints1.atruvia.de",
        "Anmeldename / Kontonummer" => "Login name / account number",
        "pushTAN-App (Decoupled) oder chipTAN. Server: banking-hs5.s-fints-pt-hs.de" => "pushTAN app (decoupled) or chipTAN. Server: banking-hs5.s-fints-pt-hs.de",
        "comdirect REST-API (OAuth2 + Session-TAN)" => "comdirect REST API (OAuth2 + session TAN)",
        "Zugangsnummer" => "Access number",
        "Session-TAN per photoTAN-Push, photoTAN-Grafik oder mobileTAN." => "Session TAN via photoTAN push, photoTAN image or mobileTAN.",
        "PayPal Transaction Search REST-API" => "PayPal Transaction Search REST API",
        "E-Mail (nur Anzeige)" => "Email (display only)",
        "(nicht nötig – nutzt Ihre REST-App)" => "(not needed – uses your REST app)",
        "OAuth2 Client Credentials; Historie in 31-Tage-Fenstern." => "OAuth2 client credentials; history in 31-day windows.",
        "WebSocket-API + 2FA" => "WebSocket API + 2FA",
        "Telefonnummer (+49…)" => "Phone number (+49…)",
        "4-stellige App-PIN" => "4-digit app PIN",
        "Web-Login mit 4-stelligem Code aus der App/SMS. Inoffizielle Schnittstelle – kann sich jederzeit ändern." => "Web login with a 4-digit code from the app or SMS. Unofficial interface – may change at any time.",
        "Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug" => "Direct login (web session) or CSV/PDF statement",
        "Kartenbezeichnung" => "Card name",
        "(Anmeldung im Browser-Fenster)" => "(sign in via the browser window)",
        "Anmeldung im eingebetteten Browser (Benutzername, Passwort, 2FA wie gewohnt) – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“." => "Sign in via the built-in browser (user name, password, 2FA as usual) – no API keys needed. Optional: your own PSD2/Enable Banking API under “Advanced”.",
        "Herausgeber: Open Bank S.A. (Zinia). Anmeldung im eingebetteten Browser – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“." => "Issuer: Open Bank S.A. (Zinia). Sign in via the built-in browser – no API keys needed. Optional: your own PSD2/Enable Banking API under “Advanced”.",
        "Für diese Bank werden Überweisungen nicht unterstützt." => "Transfers aren’t supported for this bank.",
        "Der Betrag muss größer als 0 sein." => "The amount must be greater than 0.",
        "Die Empfänger-IBAN ist ungültig." => "The recipient IBAN is invalid.",
        "Die BIC ist ungültig." => "The BIC is invalid.",
        "Der Empfängername fehlt." => "The recipient name is missing.",
        "Der Verwendungszweck darf höchstens 140 Zeichen lang sein." => "The payment reference can be at most 140 characters.",
        "Dieses Konto hat keine Bankverbindung." => "This account has no bank connection.",
        "Überweisungen sind nur für FinTS- und bunq-Konten möglich." => "Transfers are only possible for FinTS and bunq accounts.",
        "Das Konto hat keine IBAN." => "The account has no IBAN.",
        "Bankverbindung {0}" => "bank connection {0}",
        "Konto {0}" => "account {0}",
        // ------------------------------------------------------------ connectors/fints
        "Bitte in der Banking-App freigeben" => "Approve in your banking app",
        "TAN eingeben" => "Enter TAN",
        "Dieses Konto oder diese Bank erlaubt keine SEPA-Überweisungen per FinTS (HKCCS). Bitte in der Banking-App überweisen." => "This account or bank doesn’t allow SEPA transfers via FinTS (HKCCS). Please make the transfer in your banking app.",
        "Für Überweisungen ist ein TAN-Verfahren nötig; es wurde keines gefunden. Bitte zuerst eine Synchronisation mit TAN-Verfahren durchführen." => "Transfers need a TAN method, but none was found. Please sync with a TAN method first.",
        "PIN ist leer" => "PIN is empty",
        "TAN-Verfahren {0}" => "TAN method {0}",
        "{0}: Freigabe ohne Auftragsreferenz" => "{0}: approval without task reference",
        "Die Bank verlangt für {0} eine TAN-Eingabe. Bitte ein Push-/App-Verfahren (z. B. SecureGo plus) verwenden oder „Tage beim ersten Abruf“ auf höchstens 90 setzen." => "The bank requires a TAN for {0}. Use a push/app method (e.g. SecureGo plus) or set “Days on first sync” to 90 or less.",
        "Kontenliste (HKSPA) – {0}" => "Account list (HKSPA) – {0}",
        "Kontoauszug {0}" => "Statement {0}",
        "Konto {0} bei der Bank{1}" => "account {0} at the bank{1}",
        "{0}: Saldo – {1}" => "{0}: balance – {1}",
        "{0}: Umsätze (HKCAZ/camt.052) – {1}" => "{0}: transactions (HKCAZ/camt.052) – {1}",
        "{0}: Umsätze (HKKAZ/MT940) – {1}" => "{0}: transactions (HKKAZ/MT940) – {1}",
        // ------------------------------------------------------------ connectors/fints transfer codes
        "Die Nachricht enthält Fehler." => "The message contains errors.",
        "Die Bank hat die Nachricht nicht verarbeitet." => "The bank didn’t process the message.",
        "Ein Pflichtfeld der Überweisung fehlt oder ist ungültig." => "A required field of the transfer is missing or invalid.",
        "Der Auftrag wurde abgelehnt (Daten ungültig oder nicht erlaubt)." => "The order was rejected (invalid or not permitted data).",
        "Der Auftrag ist ungültig; bitte IBAN, Betrag und Name prüfen." => "The order is invalid; please check IBAN, amount and name.",
        "Der Betrag überschreitet das Limit des Kontos." => "The amount exceeds the account limit.",
        "Das Konto lässt diese Überweisung nicht zu." => "The account doesn’t allow this transfer.",
        "Das Konto ist für Überweisungen gesperrt." => "The account is blocked for transfers.",
        "PIN oder Zugangsdaten wurden abgelehnt." => "PIN or login details were rejected.",
        "Die TAN ist ungültig oder abgelaufen." => "The TAN is invalid or has expired.",
        "Die Freigabe wurde abgelehnt oder ist abgelaufen." => "The approval was rejected or has expired.",
        "Starke Kundenauthentifizierung ist erforderlich, wurde aber nicht abgeschlossen." => "Strong customer authentication is required but wasn’t completed.",
        "{0} Die Bank hat die Überweisung abgelehnt: {1}{2}" => "{0} The bank rejected the transfer: {1}{2}",
        "{0} {1} Bank: {2}{3}" => "{0} {1} Bank: {2}{3}",
        // ------------------------------------------------------------ connectors/comdirect.rs
        "In der comdirect photoTAN-App freigeben" => "Approve in the comdirect photoTAN app",
        "Öffnen Sie die photoTAN-App und geben Sie die Session-TAN frei." => "Open the photoTAN app and approve the session TAN.",
        "photoTAN-Grafik scannen" => "Scan the photoTAN image",
        "mobileTAN eingeben" => "Enter mobileTAN",
        "Scannen Sie die Grafik mit der photoTAN-App und geben Sie die TAN ein." => "Scan the image with the photoTAN app and enter the TAN.",
        "Eine TAN wurde an {0} gesendet." => "A TAN was sent to {0}.",
        "Ihr Telefon" => "your phone",
        // ------------------------------------------------------------ connectors/trade_republic.rs
        " – AWS-WAF-Schutz von Trade Republic. Bitte „Im Browser-Fenster anmelden“ verwenden." => " – Trade Republic’s AWS WAF protection. Please use “Sign in with browser”.",
        " – CLIENT_VERSION_OUTDATED: Trade Republic verlangt einen neueren Client. Bitte „Im Browser-Fenster anmelden“ verwenden." => " – CLIENT_VERSION_OUTDATED: Trade Republic requires a newer client. Please use “Sign in with browser”.",
        " – PIN, Code oder Sitzung ungültig." => " – invalid PIN, code or session.",
        " – zu viele Versuche, bitte etwas warten." => " – too many attempts, please wait a moment.",
        "App-Code (oder SMS)" => "App code (or SMS)",
        "Trade Republic schützt die Anmeldung mit AWS WAF. Bitte im Browser-Fenster anmelden – die Sitzung wird danach gespeichert und wiederverwendet." => "Trade Republic protects its login with AWS WAF. Please sign in using the browser window – the session is then saved and reused.",
        "Bitte die 4-stellige Trade-Republic-PIN eingeben (oder „Im Browser-Fenster anmelden“)." => "Please enter your 4-digit Trade Republic PIN (or use “Sign in with browser”).",
        "Login (keine processId)" => "login (no processId)",
        "Geben Sie den 4-stelligen Code ein, der in der Trade-Republic-App angezeigt wird. Keine Push-Nachricht erhalten? „Code per SMS“ wählen." => "Enter the 4-digit code shown in the Trade Republic app. No push notification? Choose “Code via SMS”.",
        "Trade Republic benötigt den 4-stelligen Code" => "Trade Republic needs the 4-digit code",
        "SMS-Anforderung" => "SMS request",
        "Der Code wurde per SMS gesendet. Bitte die 4 Ziffern eingeben." => "The code was sent by SMS. Please enter the 4 digits.",
        "Der Code muss aus 4 Ziffern bestehen." => "The code must be 4 digits.",
        "2FA-Bestätigung" => "2FA confirmation",
        "Trade Republic {0}{1} Antwort: {2}" => "Trade Republic {0}{1} Response: {2}",
        "Telefonnummer fehlt oder ist ungültig („{0}“). Bitte z. B. +4915112345678 eintragen." => "Phone number missing or invalid (“{0}”). Please enter e.g. +4915112345678.",
        "AWS WAF hat den Login abgelehnt (HTTP {0}). Bitte im Browser-Fenster anmelden." => "AWS WAF rejected the login (HTTP {0}). Please sign in using the browser window.",
        "Trade Republic hat keine Sitzung (tr_session) gesetzt. HTTP {0}, Antwort: {1}" => "Trade Republic didn’t set a session (tr_session). HTTP {0}, response: {1}",
        "Trade-Republic-Sitzung abgelaufen ({0}). Bitte im Browser-Fenster neu anmelden." => "Trade Republic session expired ({0}). Please sign in again using the browser window.",
        "WebSocket-Verbindung abgelehnt: {0}" => "WebSocket connection refused: {0}",
        "Trade Republic hat „connect 31“ nicht bestätigt (Zeitüberschreitung)." => "Trade Republic didn’t confirm “connect 31” (timeout).",
        "WebSocket wurde vor „connected“ geschlossen – Sitzung abgelaufen?" => "WebSocket closed before “connected” – session expired?",
        "Unerwartete Antwort auf connect: {0}" => "Unexpected response to connect: {0}",
        "Trade Republic hat auf „{0}“ nicht geantwortet." => "Trade Republic didn’t respond to “{0}”.",
        "WebSocket während „{0}“ geschlossen." => "WebSocket closed during “{0}”.",
        "Fehler-Frame: {0}" => "Error frame: {0}",
        // ------------------------------------------------------------ connectors/enable_banking.rs
        "Zustimmung beim Kartenherausgeber erteilen" => "Grant consent at the card issuer",
        "Seite öffnen, anmelden und Zugriff erlauben. Danach die Adresse einfügen, auf die der Browser weitergeleitet wurde." => "Open the page, sign in and allow access. Then paste the address the browser was redirected to.",
        "PSD2-Weiterleitung" => "PSD2 redirect",
        "Bitte die Weiterleitungsadresse einfügen" => "Please paste the redirect address",
        "Status stimmt nicht überein – bitte die Zustimmung neu starten" => "State mismatch – please start the consent again",
        "Kein „code“ in der eingefügten Adresse" => "No “code” in the pasted address",
        "Bitte die Adresse einfügen, auf die Sie weitergeleitet wurden" => "Paste the address you were redirected to",
        "Zustimmung verweigert: {0}" => "Consent refused: {0}",
        "ASPSP „{0}“: {1}" => "ASPSP “{0}”: {1}",
        // ------------------------------------------------------------ connectors/demo.rs
        "Demo: Eine Push-Nachricht wurde „gesendet“. Die Freigabe wird nach wenigen Sekunden simuliert." => "Demo: a push notification was “sent”. Approval is simulated after a few seconds.",
        "Demo: beliebigen 4-stelligen Code eingeben." => "Demo: enter any 4-digit code.",
        "App-Code (Demo)" => "App code (demo)",
        "Demo: Es wird keine echte Seite geöffnet. Beliebigen Text einfügen (z. B. https://localhost/cb?code=demo)." => "Demo: no real page is opened. Paste any text (e.g. https://localhost/cb?code=demo).",
        "PSD2-Weiterleitung (Demo)" => "PSD2 redirect (demo)",
        "Demo: Der Code muss 4 Ziffern haben" => "Demo: the code must be 4 digits",
        "Überweisung in der Banking-App freigeben" => "Approve the transfer in your banking app",
        "Demo: {0} an {1} wird nach wenigen Sekunden „freigegeben“." => "Demo: {0} to {1} will be “approved” in a few seconds.",
        // ------------------------------------------------------------ connectors/portal_import.rs
        "Keine Umsätze erkannt." => "No transactions found.",
        // ------------------------------------------------------------ connectors/moneymoney_import.rs
        "Keine MoneyMoney-Kopfzeile (Datum/Buchungstag und Betrag) gefunden." => "No MoneyMoney header row (date/booking date and amount) found.",
        // ------------------------------------------------------------ connectors/moneymoney_db.rs
        "Falsches Passwort oder keine MoneyMoney-Datenbank." => "Wrong password or not a MoneyMoney database.",
        "MoneyMoney-Datenbank" => "MoneyMoney database",
        "Anfangssaldo laut MoneyMoney-Saldenverlauf ({0}) + Umsätze" => {
            "Opening balance from MoneyMoney balance history ({0}) + transactions"
        }
        "Anfangssaldo des Kontos + Umsätze" => "Account opening balance + transactions",
        "Summe der Umsätze" => "Sum of transactions",
        // ------------------------------------------------------------ connections.rs
        "Bankzugang {0}" => "bank connection {0}",
        "Keine Sitzungs-Cookies übergeben" => "No session cookies were passed",
        // ------------------------------------------------------------ documents.rs
        "Leere Datei" => "Empty file",
        "Beleg {0}" => "receipt {0}",
        "Buchung {0}" => "transaction {0}",
        "Beleg bereits vorhanden" => "Receipt already exists",
        "Dokument bereits vorhanden" => "Document already exists",
        "Export fehlgeschlagen: {0}" => "Export failed: {0}",
        "GiroCrab-Belege" => "GiroCrab Receipts",
        "ohne-Datum" => "no-date",
        // ------------------------------------------------------------ money.rs
        "Kein Betrag angegeben" => "No amount entered",
        "Kein gültiger Betrag: „{0}“" => "Not a valid amount: “{0}”",
        "Zu viele Nachkommastellen in „{0}“" => "Too many decimal places in “{0}”",
        "Betrag zu groß: „{0}“" => "Amount too large: “{0}”",
        // ------------------------------------------------------------ vault.rs
        "Der Kategoriename ist leer." => "The category name is empty.",
        "Eine Kategorie kann nicht in sich selbst verschoben werden." => "A category can’t be moved into itself.",
        "Das Suchmuster ist leer." => "The pattern is empty.",
        "FinTS-Produktregistrierung" => "FinTS product registration",
        "Kostenlos bei der Deutschen Kreditwirtschaft registrieren (fints.org › Hersteller › Produktregistrierung). Pflicht für alle FinTS-Banken." => "Register for free with Die Deutsche Kreditwirtschaft (fints.org › Hersteller › Produktregistrierung). Required for all FinTS banks.",
        "FinTS-Produktversion" => "FinTS product version",
        "Versionsangabe, die mit HKVVB gesendet wird." => "Version string sent with HKVVB.",
        "Server Volksbank Kassel Göttingen (BLZ 52090000)" => "Server Volksbank Kassel Göttingen (bank code 52090000)",
        "FinTS-PIN/TAN-Adresse laut öffentlicher DK-Institutsliste." => "FinTS PIN/TAN address from the public DK institute list.",
        "Server 1822direkt (BLZ 50050201)" => "Server 1822direkt (bank code 50050201)",
        "comdirect Client-ID" => "comdirect client ID",
        "Aus dem comdirect-Entwicklerportal (Persönlicher Bereich › Einstellungen › API)." => "From the comdirect developer portal (Persönlicher Bereich › Einstellungen › API).",
        "comdirect Client-Secret" => "comdirect client secret",
        "Wird beim Freischalten des API-Zugangs einmalig angezeigt." => "Shown once when API access is activated.",
        "comdirect REST-API" => "comdirect REST API",
        "PayPal Client-ID" => "PayPal client ID",
        "REST-App auf developer.paypal.com mit aktivierter „Transaction Search“ anlegen." => "Create a REST app on developer.paypal.com with “Transaction Search” enabled.",
        "Secret derselben REST-App." => "Secret of the same REST app.",
        "PayPal-Umgebung" => "PayPal environment",
        "live oder sandbox" => "live or sandbox",
        "Enable Banking Application-ID" => "Enable Banking application ID",
        "Anwendung auf enablebanking.com registrieren (wird als JWT-„kid“ verwendet)." => "Register an application on enablebanking.com (used as the JWT “kid”).",
        "RSA-Schlüssel der Anwendung; signiert das RS256-JWT." => "The application’s RSA key; signs the RS256 JWT.",
        "Redirect-URL" => "Redirect URL",
        "Muss in Ihrer Enable-Banking-Anwendung freigegeben sein." => "Must be allowed in your Enable Banking application.",
        "ASPSP-Name American Express" => "ASPSP name American Express",
        "Exakter Name aus GET /aspsps." => "Exact name from GET /aspsps.",
        "Land American Express" => "Country American Express",
        "Zweistelliger Ländercode." => "Two-letter country code.",
        "ASPSP-Name Amazon Visa" => "ASPSP name Amazon Visa",
        "Herausgeber in Deutschland: Open Bank S.A. (Marke Zinia). Je nach Listung „Open Bank“ oder „Zinia“ eintragen." => "Issuer in Germany: Open Bank S.A. (brand Zinia). Enter “Open Bank” or “Zinia”, depending on the listing.",
        "Land Amazon Visa" => "Country Amazon Visa",
        "Händler-Logos online laden" => "Load merchant logos online",
        "Logos per Google-Favicon-Dienst (Ersatz: DuckDuckGo) laden und verschlüsselt zwischenspeichern. Dabei wird nur die Händler-Domain (z. B. lidl.de) übertragen. Standard: an." => "Load logos via Google’s favicon service (fallback: DuckDuckGo) and cache them encrypted. Only the merchant domain (e.g. lidl.de) is sent. Default: on.",
        "Händler-Logos" => "Merchant logos",
        "Tage beim ersten Abruf" => "Days on first sync",
        "Ältere Umsätze werden nur einmal abgefragt." => "Older transactions are only fetched once.",
        "Allgemein" => "General",
        // ------------------------------------------------------------ vault.rs settings (same in both languages)
        "PayPal Secret" => "PayPal secret",
        "Enable Banking Private Key (PEM)" => "Enable Banking private key (PEM)",
        "FinTS 3.0" => "FinTS 3.0",
        "PayPal" => "PayPal",
        "Enable Banking (PSD2)" => "Enable Banking (PSD2)",
        // ------------------------------------------------------------ merchants.rs (payment method labels, asset classes)
        "Saveback" => "Saveback",
        "Round up" => "Round up",
        "Sparplan" => "Savings plan",
        "Zinsen" => "Interest",
        "Dauerauftrag" => "Standing order",
        "Lastschrift" => "Direct debit",
        "Kartenzahlung" => "Card payment",
        "Entgelt" => "Fee",
        "Kreditkarte" => "Credit card",
        "Gutschrift" => "Credit",
        "Überweisung" => "Transfer",
        "Buchung" => "Transaction",
        "ETF" => "ETF",
        "Aktie" => "Stock",
        "Gehalt" => "Salary",
        "Bargeld" => "Cash",
        "Krypto" => "Crypto",
        // ------------------------------------------------------------ bunq
        "bunq Public API (eigener API-Schlüssel)" => "bunq public API (your own API key)",
        "API-Schlüssel" => "API key",
        "API-Schlüssel in der bunq-App unter Profil → Einstellungen → Entwickler → API-Schlüssel erstellen und „Alle IP-Adressen erlauben“ aktivieren. Keine PSD2-Registrierung nötig." => {
            "Create an API key in the bunq app under Profile → Settings → Developers → API keys and enable “Allow all IP addresses”. No PSD2 registration needed."
        }
        "bunq hat den API-Schlüssel oder diese IP-Adresse abgelehnt. Erstellen Sie in der bunq-App einen API-Schlüssel mit „Alle IP-Adressen erlauben“ und tragen Sie ihn neu ein." => {
            "bunq rejected the API key or this IP address. Create an API key with “Allow all IP addresses” in the bunq app and enter it again."
        }
        "Die Antwort von bunq ist nicht korrekt signiert." => "The response from bunq is not correctly signed.",
        "Bitte den bunq-API-Schlüssel eingeben." => "Please enter your bunq API key.",
        "Sparen" => "Savings",
        "Rückbuchung" => "Reversal",
        "Abhebung" => "Withdrawal",
        "Kontoauszug {0} – {1}" => "Statement {0} – {1}",
        "vorgemerkt" => "pending",
        "Originalbetrag {0}" => "Original amount {0}",
        "Überweisung in der bunq-App freigeben" => "Approve the transfer in the bunq app",
        "Freigabe in der bunq-App" => "Approval in the bunq app",
        "bunq hat die Überweisung abgelehnt oder sie wurde abgebrochen." => "bunq rejected the transfer or it was cancelled.",
        "Das Quellkonto wurde bei bunq nicht gefunden." => "The source account was not found at bunq.",
        "{0} an {1}: Bitte öffnen Sie die bunq-App und bestätigen Sie die Zahlung." => "{0} to {1}: please open the bunq app and confirm the payment.",
        "bunq" => "bunq",
        "bunq-Umgebung" => "bunq environment",
        "production oder sandbox (Test-API von bunq)." => "production or sandbox (bunq's test API).",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_german() {
        // The process-wide default is German; tests never change it.
        assert_eq!(Lang::from_u8(LANGUAGE.load(Ordering::Relaxed)), Lang::De);
        assert_eq!(
            tr("Dieser Abruf ist nicht mehr aktiv"),
            "Dieser Abruf ist nicht mehr aktiv"
        );
    }

    #[test]
    fn parses_language_tags() {
        assert_eq!(parse_language("en-US"), Lang::En);
        assert_eq!(parse_language("en"), Lang::En);
        assert_eq!(parse_language("EN_gb"), Lang::En);
        assert_eq!(parse_language("de-DE"), Lang::De);
        assert_eq!(parse_language("fr-FR"), Lang::De);
        assert_eq!(parse_language(""), Lang::De);
        assert_eq!(parse_language("eng"), Lang::De);
    }

    #[test]
    fn thread_override_is_scoped() {
        with_language(Lang::En, || {
            assert_eq!(current(), Lang::En);
            assert_eq!(
                tr("Dieser Abruf ist nicht mehr aktiv"),
                "This sync is no longer active"
            );
        });
        assert_eq!(current(), Lang::De);
    }

    #[test]
    fn templates_fill_placeholders() {
        assert_eq!(
            trf_in(
                Lang::En,
                "Die Bank hat die Anfrage abgelehnt: {0} {1}",
                &[&"9050", &"x"]
            ),
            "The bank rejected the request: 9050 x"
        );
        assert_eq!(
            trf_in(Lang::De, "Netzwerkfehler: {0}", &[&"timeout"]),
            "Netzwerkfehler: timeout"
        );
        // Unknown or out-of-range placeholders and stray braces are kept.
        assert_eq!(fill("a {1} {x} {", &[&1]), "a {1} {x} {");
    }

    #[test]
    fn unknown_text_falls_back_to_german() {
        assert_eq!(tr_in(Lang::En, "Gibt es nicht"), "Gibt es nicht");
    }

    #[test]
    fn default_names_translate() {
        assert_eq!(
            display_name_in(Lang::En, "Giro & Tagesgeld"),
            "Checking & savings"
        );
        assert_eq!(display_name_in(Lang::En, "Lebensmittel"), "Food");
        assert_eq!(
            display_name_in(Lang::En, "Meine Kategorie"),
            "Meine Kategorie"
        );
        assert_eq!(display_name_in(Lang::De, "Kreditkarten"), "Kreditkarten");
        assert_eq!(
            display_path_in(Lang::En, "Lebensmittel › Supermarkt"),
            "Food › Supermarket"
        );
        assert_eq!(
            display_path_in(Lang::En, "Lebensmittel › Wochenmarkt"),
            "Food › Wochenmarkt"
        );
    }

    #[test]
    fn sample_messages_in_english() {
        assert_eq!(tr_in(Lang::En, "TAN eingeben"), "Enter TAN");
        assert_eq!(
            tr_in(Lang::En, "Der Betrag muss größer als 0 sein."),
            "The amount must be greater than 0."
        );
        assert_eq!(
            trf_in(Lang::En, "Eine TAN wurde an {0} gesendet.", &[&"+49 151 …"]),
            "A TAN was sent to +49 151 …."
        );
        assert_eq!(
            trf_in(Lang::De, "Eine TAN wurde an {0} gesendet.", &[&"+49 151 …"]),
            "Eine TAN wurde an +49 151 … gesendet."
        );
        let e = crate::error::CoreError::Bank {
            code: "9050".into(),
            message: "x".into(),
        };
        assert_eq!(
            with_language(Lang::En, || e.to_string()),
            "The bank rejected the request: 9050 x"
        );
        assert_eq!(e.to_string(), "Die Bank hat die Anfrage abgelehnt: 9050 x");
        assert_eq!(
            with_language(Lang::En, || crate::merchants::payment_method(
                "KARTENZAHLUNG",
                "",
                crate::models::AccountKind::Checking,
                -5_00
            )),
            "Card payment"
        );
    }

    #[test]
    fn settings_catalogue_is_translated() {
        for (key, label, help, group, ..) in crate::vault::KNOWN_SETTINGS {
            for de in [label, help, group] {
                assert!(english(de).is_some(), "{key}: no English for {de}");
            }
        }
    }

    /// Every `tr("…")` / `trf("…", …)` literal in the crate needs an English
    /// entry, otherwise English users would silently see German.
    #[test]
    fn every_source_string_has_an_english_translation() {
        let re = regex::Regex::new(r#"\btrf?\(\s*"((?:[^"\\]|\\.)*)""#).unwrap();
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = vec![root.clone()];
        let mut missing = Vec::new();
        let mut count = 0;
        while let Some(p) = files.pop() {
            if p.is_dir() {
                for e in std::fs::read_dir(&p).unwrap() {
                    files.push(e.unwrap().path());
                }
                continue;
            }
            if p.extension().and_then(|e| e.to_str()) != Some("rs") || p.ends_with("i18n.rs") {
                continue;
            }
            let src = std::fs::read_to_string(&p).unwrap();
            for c in re.captures_iter(&src) {
                let de = c[1]
                    .replace("\\\"", "\"")
                    .replace("\\n", "\n")
                    .replace("\\\\", "\\");
                count += 1;
                if english(&de).is_none() {
                    missing.push(format!("{}: {de}", p.display()));
                }
            }
        }
        assert!(count > 10, "scanner found only {count} strings");
        assert!(
            missing.is_empty(),
            "missing English:\n{}",
            missing.join("\n")
        );
    }
}
