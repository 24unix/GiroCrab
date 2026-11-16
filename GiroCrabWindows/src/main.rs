//! GiroCrab for Windows (MVP): Slint front end directly on `girocrab_core`.
//! Unlock / create vault, demo mode (`GIROCRAB_DEMO_SEED=1`), accounts with balances,
//! bookings of the selected account and bank sync (FinTS PIN/TAN dialog, PSD2 browser redirect).

mod policy;
mod sync_flow;
mod vault_key;

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use girocrab_core::connectors::bank_directory::{BankAccessMode, BankSearchResult};
use girocrab_core::{BookingFilter, Challenge, ChallengeKind, ConnectorKind, SyncStep, Vault};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use zeroize::Zeroizing;

slint::include_modules!();

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn vault_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("XDG_DATA_HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(
                std::env::var_os("HOME")
                    .or_else(|| std::env::var_os("USERPROFILE"))
                    .unwrap_or_default(),
            )
            .join(".local/share")
        })
        .join("GiroCrab");
    let _ = std::fs::create_dir_all(&base);
    base.join(if vault_key::bypassed() {
        "demo-vault.sqlite"
    } else {
        "vault.sqlite"
    })
}

fn open_vault(demo: bool) -> Result<Arc<Vault>, String> {
    let path = vault_path();
    if demo {
        // The demo vault is throw-away: always start from fresh demo data.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
    }
    let allow_create = std::fs::metadata(&path).map_or(true, |m| m.len() == 0);
    let unlocked = vault_key::unlock(allow_create)?;
    let vault = Vault::open(path.display().to_string(), unlocked.key.to_vec())
        .map_err(|e| e.to_string())?;
    if demo {
        // `seed_demo_data` is a no-op on a vault that already has categories, so the starter
        // categories must NOT be seeded first (that left the demo vault empty at 0,00 EUR).
        vault.seed_demo_data().map_err(|e| e.to_string())?;
    } else {
        vault.seed_starter_categories().map_err(|e| e.to_string())?;
    }
    Ok(vault)
}

fn money(cents: i64, currency: &str) -> String {
    girocrab_core::format_cents(cents, currency.to_string())
}

/// "•••• 1234" from the last four characters; never the whole IBAN on screen.
fn mask_iban(iban: &str, number: &str) -> String {
    let src: String = if iban.trim().is_empty() { number } else { iban }
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    let n = src.chars().count();
    if n == 0 {
        return String::new();
    }
    let tail: String = src.chars().skip(n.saturating_sub(4)).collect();
    format!("•••• {tail}")
}

/// Stable accent colour per bank name (badge dot).
fn dot_color(name: &str) -> slint::Color {
    const PALETTE: [(u8, u8, u8); 7] = [
        (0x34, 0x78, 0xf6),
        (0x1e, 0x84, 0x49),
        (0xe6, 0x7e, 0x22),
        (0x8e, 0x44, 0xad),
        (0xc0, 0x39, 0x2b),
        (0x16, 0xa0, 0x85),
        (0xd4, 0xa0, 0x17),
    ];
    let h = name
        .bytes()
        .fold(0usize, |h, b| h.wrapping_mul(31).wrapping_add(b as usize));
    let (r, g, b) = PALETTE[h % PALETTE.len()];
    slint::Color::from_rgb_u8(r, g, b)
}

fn hex_color(hex: &str) -> Option<slint::Color> {
    let h = hex.trim().trim_start_matches('#');
    if h.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(h, 16).ok()?;
    Some(slint::Color::from_rgb_u8(
        (v >> 16) as u8,
        (v >> 8) as u8,
        v as u8,
    ))
}

fn account_rows(vault: &Vault) -> Result<(Vec<AccountRow>, String), String> {
    let accounts = vault.list_accounts().map_err(|e| e.to_string())?;
    let total: i64 = accounts
        .iter()
        .filter(|a| a.in_total && a.currency == "EUR")
        .map(|a| a.balance_cents)
        .sum();
    let rows = accounts
        .iter()
        .map(|a| AccountRow {
            id: a.id as i32,
            name: a.name.clone().into(),
            bank: a.bank_name.clone().into(),
            iban: mask_iban(&a.iban, &a.account_number).into(),
            dot: dot_color(&a.bank_name),
            balance: money(a.balance_cents, &a.currency).into(),
            currency: a.currency.clone().into(),
            negative: a.balance_cents < 0,
        })
        .collect();
    Ok((rows, money(total, "EUR")))
}

fn booking_rows(vault: &Vault, account_id: i64, search: &str) -> Result<Vec<BookingRow>, String> {
    let page = vault
        .list_transactions(BookingFilter {
            account_ids: vec![account_id],
            search: Some(search.trim().to_string()).filter(|q| !q.is_empty()),
            limit: 200,
            ..Default::default()
        })
        .map_err(|e| e.to_string())?;
    Ok(page
        .transactions
        .iter()
        .map(|b| BookingRow {
            date: b.booking_date.clone().into(),
            counterparty: if b.merchant_name.is_empty() {
                b.counterparty.clone()
            } else {
                b.merchant_name.clone()
            }
            .into(),
            category: if b.category_name.is_empty() {
                "Ohne Kategorie".into()
            } else {
                b.category_name.clone().into()
            },
            category_color: hex_color(&b.category_color_hex)
                .unwrap_or_else(|| slint::Color::from_rgb_u8(0x8e, 0x8e, 0x93)),
            purpose: b.purpose.clone().into(),
            amount: money(b.amount_cents, &b.currency).into(),
            negative: b.amount_cents < 0,
        })
        .collect())
}

/// Bridges the sync worker thread to the Slint dialog. The worker blocks on `replies` until the
/// user answers (`Some(text)`) or cancels (`None`); PIN / TAN pass through here only.
struct DialogBridge {
    win: slint::Weak<MainWindow>,
    replies: Mutex<Receiver<Option<String>>>,
}

impl DialogBridge {
    fn show(&self, mode: &'static str, title: String, message: String, image: Option<Vec<u8>>) {
        let _ = self.win.upgrade_in_event_loop(move |w| {
            let img = image.as_deref().and_then(decode_image);
            w.set_tan_has_image(img.is_some());
            w.set_tan_image(img.unwrap_or_default());
            w.set_tan_mode(mode.into());
            w.set_tan_title(title.into());
            w.set_tan_message(message.into());
            w.set_tan_open(true);
        });
    }

    fn hide(&self) {
        let _ = self.win.upgrade_in_event_loop(|w| {
            w.set_tan_open(false);
            w.set_tan_image(Default::default());
            w.set_tan_has_image(false);
        });
    }

    fn drain(&self) {
        while self.replies.lock().unwrap().try_recv().is_ok() {}
    }

    fn ask(&self, mode: &'static str, c: &Challenge) -> Option<Zeroizing<String>> {
        self.drain();
        let title = if c.title.is_empty() {
            "TAN eingeben".to_string()
        } else {
            c.title.clone()
        };
        self.show(mode, title, challenge_text(c), c.image.clone());
        self.replies
            .lock()
            .unwrap()
            .recv()
            .ok()
            .flatten()
            .map(Zeroizing::new)
    }
}

fn challenge_text(c: &Challenge) -> String {
    match (c.method_name.is_empty(), c.message.is_empty()) {
        (true, _) => c.message.clone(),
        (false, true) => c.method_name.clone(),
        (false, false) => format!("{}\n{}", c.method_name, c.message),
    }
}

fn decode_image(bytes: &[u8]) -> Option<slint::Image> {
    let rgba = image::load_from_memory(bytes).ok()?.to_rgba8();
    let buf = slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(
        rgba.as_raw(),
        rgba.width(),
        rgba.height(),
    );
    Some(slint::Image::from_rgba8(buf))
}

impl sync_flow::Ui for DialogBridge {
    fn ask_secret(&self, bank: &str) -> Option<Zeroizing<String>> {
        self.drain();
        self.show(
            "pin",
            "PIN eingeben".into(),
            format!(
                "PIN / Passwort für {bank}. Sie wird nur für diesen Abruf im Speicher gehalten."
            ),
            None,
        );
        self.replies
            .lock()
            .unwrap()
            .recv()
            .ok()
            .flatten()
            .map(Zeroizing::new)
    }

    fn ask_code(&self, c: &Challenge) -> Option<Zeroizing<String>> {
        match c.kind {
            ChallengeKind::Redirect => self.ask("redirect", c),
            _ => self.ask("code", c),
        }
    }

    fn wait_push(&self, c: &Challenge, interval: Duration) -> bool {
        let title = if c.title.is_empty() {
            "Freigabe in der Bank-App".to_string()
        } else {
            c.title.clone()
        };
        self.show("push", title, challenge_text(c), None);
        match self.replies.lock().unwrap().recv_timeout(interval) {
            Ok(None) | Err(RecvTimeoutError::Disconnected) => false,
            Ok(Some(_)) | Err(RecvTimeoutError::Timeout) => true,
        }
    }

    fn open_url(&self, url: &str) -> Result<(), String> {
        sync_flow::open_in_browser(url)
    }
}

/// `SyncSession` driven synchronously (the worker thread owns a small tokio runtime).
struct CoreStepper {
    session: Arc<girocrab_core::SyncSession>,
    rt: tokio::runtime::Runtime,
}

impl sync_flow::Stepper for CoreStepper {
    fn start(&self) -> Result<SyncStep, String> {
        self.rt
            .block_on(self.session.start())
            .map_err(|e| e.to_string())
    }
    fn submit_code(&self, code: String) -> Result<SyncStep, String> {
        self.rt
            .block_on(self.session.submit_code(code))
            .map_err(|e| e.to_string())
    }
    fn poll(&self) -> Result<SyncStep, String> {
        self.rt
            .block_on(self.session.poll())
            .map_err(|e| e.to_string())
    }
    fn cancel(&self) {
        self.rt.block_on(self.session.cancel());
    }
}

/// Manual sync: runs every connection to the end. Demo banks are simulated without network; real
/// banks go through the PIN / TAN / browser dialog. The signed banking policy is checked before
/// every connection (fail-closed: an unreadable or tampered policy blocks everything), and the
/// core enforces the same gate again inside `begin_sync`.
fn run_sync(vault: Arc<Vault>, demo: bool, ui: &DialogBridge) -> Result<String, String> {
    let connections = vault.list_bank_connections().map_err(|e| e.to_string())?;
    if connections.is_empty() {
        return Ok("Keine Bankverbindung eingerichtet.".into());
    }
    let rt = tokio_runtime()?;
    let (mut done, mut imported, mut problems) = (0u32, 0u32, vec![]);
    for c in connections.iter().filter(|c| !c.all_accounts_archived) {
        if policy::apply(VERSION).all {
            return Err(
                "Abruf gesperrt: Diese Version ist durch die Sicherheitssperre gesperrt.".into(),
            );
        }
        if demo || girocrab_core::demo::is_magic_demo_login(&c.login_name) {
            match sync_demo_connection(&vault, &rt, c.id) {
                Ok(()) => done += 1,
                Err(e) => problems.push(format!("{}: {e}", c.display_name)),
            }
            continue;
        }
        let result = sync_flow::sync_connection(c.connector, &c.display_name, ui, |secret| {
            // `secret` moves into the core, which wipes it when the session ends.
            let session = vault
                .clone()
                .begin_sync(c.id, secret, false)
                .map_err(|e| e.to_string())?;
            Ok(CoreStepper {
                session,
                rt: tokio_runtime()?,
            })
        });
        match result {
            Ok(s) => {
                done += 1;
                imported += s.transactions_imported;
            }
            Err(e) => problems.push(format!("{}: {e}", c.display_name)),
        }
    }
    ui.hide();
    let mut msg = format!("{done} Verbindung(en) abgerufen, {imported} neue Umsätze.");
    if !problems.is_empty() {
        msg.push_str(&format!(" Probleme: {}", problems.join(" · ")));
    }
    Ok(msg)
}

/// Simulated sync (no network): runs the demo bank to its end.
fn sync_demo_connection(
    vault: &Arc<Vault>,
    rt: &tokio::runtime::Runtime,
    id: i64,
) -> Result<(), String> {
    let session = vault
        .clone()
        .begin_sync(id, String::new(), true)
        .map_err(|e| e.to_string())?;
    match rt.block_on(session.start()).map_err(|e| e.to_string())? {
        SyncStep::Finished { .. } => Ok(()),
        _ => {
            rt.block_on(session.cancel());
            Err("Demo-Abruf verlangt eine Eingabe, die die Windows-App noch nicht hat.".into())
        }
    }
}

fn mode_label(m: BankAccessMode) -> &'static str {
    match m {
        BankAccessMode::FinTs => "FinTS (PIN/TAN)",
        BankAccessMode::OwnApi => "Eigene Schnittstelle",
        BankAccessMode::Psd2 => "PSD2",
    }
}

/// Bank picker rows: the demo bank first, then the core's directory search.
fn search_rows(query: &str) -> (Vec<BankHit>, Vec<Option<BankSearchResult>>) {
    let mut hits = vec![];
    let mut raw = vec![];
    let q = query.trim();
    if q.is_empty() || "demo-bank musterbank".contains(&q.to_lowercase()) {
        hits.push(BankHit {
            name: "Demo-Bank (Musterbank)".into(),
            detail: "Fiktive Konten und Umsätze, kein Netzwerk".into(),
        });
        raw.push(None);
    }
    if !q.is_empty() {
        for r in girocrab_core::connectors::bank_directory::search_banks(q.to_string(), vec![], 12)
        {
            let blz = if r.blz.is_empty() {
                String::new()
            } else {
                format!("BLZ {} · ", r.blz)
            };
            hits.push(BankHit {
                name: r.name.clone().into(),
                detail: format!("{blz}{}", mode_label(r.mode)).into(),
            });
            raw.push(Some(r));
        }
    }
    (hits, raw)
}

/// Adds the chosen bank (`None` = demo bank) and, for the demo bank, syncs it right away.
/// Real banks are stored; their first fetch starts with "Jetzt abrufen" (PIN/TAN or browser dialog).
fn add_bank(
    vault: &Arc<Vault>,
    hit: Option<&BankSearchResult>,
    login: &str,
) -> Result<String, String> {
    let e = |e: girocrab_core::CoreError| e.to_string();
    let Some(r) = hit else {
        let id = vault
            .add_bank_connection(
                ConnectorKind::VolksbankKasselGoettingen,
                "Demo-Bank".into(),
                "demo".into(),
            )
            .map_err(e)?;
        sync_demo_connection(vault, &tokio_runtime()?, id)?;
        return Ok("Demo-Bank hinzugefügt und abgerufen.".into());
    };
    let login = login.trim();
    if login.is_empty() {
        return Err("Bitte die Zugangskennung (Login) eingeben.".into());
    }
    match (r.mode, r.connector) {
        (BankAccessMode::FinTs, _) => {
            vault
                .add_fints_connection(
                    r.blz.clone(),
                    r.url.clone(),
                    r.name.clone(),
                    login.into(),
                    String::new(),
                )
                .map_err(e)?;
        }
        (_, Some(kind)) => {
            vault
                .add_bank_connection(kind, r.name.clone(), login.into())
                .map_err(e)?;
        }
        (_, None) => {
            vault
                .add_enable_banking_connection(
                    r.aspsp.clone(),
                    r.country.clone(),
                    r.name.clone(),
                    login.into(),
                )
                .map_err(e)?;
        }
    }
    Ok(format!(
        "{} hinzugefügt. Mit „Jetzt abrufen“ starten Sie den ersten Abruf.",
        r.name
    ))
}

fn tokio_runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())
}

fn load_bookings(win: &MainWindow, vault: &Vault, id: i64) {
    match booking_rows(vault, id, &win.get_search_text()) {
        Ok(b) => win.set_bookings(ModelRc::new(VecModel::from(b))),
        Err(e) => win.set_sync_status(e.into()),
    }
}

fn show(win: &MainWindow, vault: &Vault, selected: Option<i64>) {
    match account_rows(vault) {
        Ok((rows, total)) => {
            let first = rows.first().map(|r| r.id as i64);
            let header: Vec<(i64, String, String, String)> = rows
                .iter()
                .map(|r| {
                    (
                        r.id as i64,
                        r.name.to_string(),
                        r.balance.to_string(),
                        r.currency.to_string(),
                    )
                })
                .collect();
            win.set_accounts(ModelRc::new(VecModel::from(rows)));
            win.set_total(total.into());
            let sel = selected.or(first);
            win.set_selected(sel.map_or(-1, |s| s as i32));
            let cur = header
                .iter()
                .find(|h| Some(h.0) == sel)
                .map(|h| (h.1.clone(), h.2.clone(), h.3.clone()))
                .unwrap_or_else(|| (String::new(), money(0, "EUR"), "EUR".into()));
            win.set_selected_name(cur.0.into());
            win.set_selected_balance(cur.1.into());
            win.set_selected_currency(cur.2.into());
            match sel {
                Some(id) => load_bookings(win, vault, id),
                None => win.set_bookings(ModelRc::new(VecModel::from(Vec::<BookingRow>::new()))),
            }
            win.set_unlocked(true);
        }
        Err(e) => win.set_message(e.into()),
    }
}

fn main() -> Result<(), slint::PlatformError> {
    let win = MainWindow::new()?;
    let demo_mode = vault_key::demo_seed_requested();
    let vault: Arc<Mutex<Option<Arc<Vault>>>> = Arc::new(Mutex::new(None));
    let demo_active = Arc::new(Mutex::new(demo_mode));
    let (reply_tx, reply_rx): (Sender<Option<String>>, _) = std::sync::mpsc::channel();
    let bridge = Arc::new(DialogBridge {
        win: win.as_weak(),
        replies: Mutex::new(reply_rx),
    });
    {
        let tx = reply_tx.clone();
        win.on_tan_submit(move |text| {
            let _ = tx.send(Some(text.to_string()));
        });
        win.on_tan_cancel(move || {
            let _ = reply_tx.send(None);
        });
    }
    win.set_first_run(std::fs::metadata(vault_path()).map_or(true, |m| m.len() == 0));

    let open = {
        let (weak, vault, demo_active) = (win.as_weak(), vault.clone(), demo_active.clone());
        move |demo: bool| {
            let Some(win) = weak.upgrade() else { return };
            policy::apply(VERSION);
            match open_vault(demo) {
                Ok(v) => {
                    *demo_active.lock().unwrap() = demo;
                    show(&win, &v, None);
                    *vault.lock().unwrap() = Some(v);
                    win.set_message(SharedString::new());
                }
                Err(e) => win.set_message(e.into()),
            }
        }
    };
    {
        let open = open.clone();
        win.on_unlock(move || open(vault_key::demo_seed_requested()));
    }
    {
        // "Demo-Modus" button: same as GIROCRAB_DEMO_SEED=1, but without touching the key store.
        let open = open.clone();
        win.on_demo(move || {
            std::env::set_var("GIROCRAB_DEMO_SEED", "1");
            open(true)
        });
    }
    {
        let (weak, vault) = (win.as_weak(), vault.clone());
        win.on_select_account(move |id| {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            show(&win, &v, Some(id as i64));
        });
    }
    {
        let (weak, vault) = (win.as_weak(), vault.clone());
        win.on_search_changed(move || {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            if win.get_selected() >= 0 {
                load_bookings(&win, &v, win.get_selected() as i64);
            }
        });
    }
    let hits: Arc<Mutex<Vec<Option<BankSearchResult>>>> = Arc::new(Mutex::new(vec![]));
    {
        let (weak, hits) = (win.as_weak(), hits.clone());
        win.on_bank_search(move |q| {
            let Some(win) = weak.upgrade() else { return };
            let (rows, raw) = search_rows(&q);
            *hits.lock().unwrap() = raw;
            win.set_bank_hits(ModelRc::new(VecModel::from(rows)));
            win.set_bank_choice(-1);
        });
    }
    {
        let (weak, vault, hits) = (win.as_weak(), vault.clone(), hits.clone());
        win.on_bank_add(move |choice, login| {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            let Some(hit) = hits.lock().unwrap().get(choice as usize).cloned() else {
                win.set_add_status("Bitte zuerst eine Bank auswählen.".into());
                return;
            };
            if hit.is_some() && policy::apply(VERSION).all {
                win.set_add_status("Gesperrt: Diese Version darf keine Bank hinzufügen.".into());
                return;
            }
            win.set_add_busy(true);
            win.set_add_status("Bank wird eingerichtet …".into());
            let weak = win.as_weak();
            let login = login.to_string();
            std::thread::spawn(move || {
                let result = add_bank(&v, hit.as_ref(), &login);
                let _ = weak.upgrade_in_event_loop(move |win| {
                    win.set_add_busy(false);
                    match result {
                        Ok(msg) => {
                            let sel = Some(win.get_selected() as i64).filter(|s| *s >= 0);
                            show(&win, &v, sel);
                            win.set_sync_status(msg.into());
                            win.set_add_open(false);
                        }
                        Err(e) => win.set_add_status(e.into()),
                    }
                });
            });
        });
    }
    {
        let (weak, vault, demo_active, bridge) = (
            win.as_weak(),
            vault.clone(),
            demo_active.clone(),
            bridge.clone(),
        );
        win.on_sync(move || {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            let demo = *demo_active.lock().unwrap();
            let bridge = bridge.clone();
            win.set_busy(true);
            win.set_sync_status("Abruf läuft …".into());
            let weak = win.as_weak();
            // The core call blocks (vault mutex, network): never on the UI thread.
            std::thread::spawn(move || {
                let result = run_sync(v.clone(), demo, &bridge);
                let _ = weak.upgrade_in_event_loop(move |win| {
                    let selected = Some(win.get_selected() as i64).filter(|s| *s >= 0);
                    show(&win, &v, selected);
                    win.set_busy(false);
                    win.set_sync_status(result.unwrap_or_else(|e| e).into());
                });
            });
        });
    }

    if demo_mode {
        open(true);
    }
    win.run()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demo_vault_has_accounts_and_bookings() {
        let path =
            std::env::temp_dir().join(format!("girocrab-win-demo-{}.sqlite", std::process::id()));
        let vault = Vault::open(path.display().to_string(), vec![7; 32]).unwrap();
        vault.seed_demo_data().unwrap();
        let (rows, _) = account_rows(&vault).unwrap();
        assert!(!rows.is_empty());
        assert!(!booking_rows(&vault, rows[0].id as i64, "")
            .unwrap()
            .is_empty());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn iban_is_masked() {
        assert_eq!(mask_iban("DE89 3704 0044 0532 0130 00", ""), "•••• 3000");
        assert_eq!(mask_iban("", ""), "");
    }
}
