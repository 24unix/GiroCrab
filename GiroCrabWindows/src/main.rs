//! GiroCrab for Windows (MVP): Slint front end directly on `girocrab_core`.
//! Unlock / create vault, demo mode (`GIROCRAB_DEMO_SEED=1`), accounts with balances,
//! bookings of the selected account and bank sync (FinTS PIN/TAN dialog, PSD2 browser redirect).

mod cockpit;
mod daily;
mod lists;
mod logos;
mod manage;
mod manage_ui;
mod nav;
mod policy;
mod portfolio;
mod sync_flow;
mod transfer_flow;
mod vault_key;
mod views_ui;

use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use girocrab_core::connectors::bank_directory::{BankAccessMode, BankSearchResult};
use girocrab_core::connectors::PayeeCheck;
use girocrab_core::{
    BookingFilter, Category, Challenge, ChallengeKind, ConnectorKind, PeriodGranularity, SyncStep,
    TransferStep, Vault,
};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use zeroize::Zeroizing;

use daily::{Filter, Row, StatusFilter};
use nav::Target;

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

/// German amount with a currency symbol: `-1.234,50 €`.
fn money(cents: i64, currency: &str) -> String {
    let abs = cents.unsigned_abs();
    let whole = (abs / 100).to_string();
    let mut grouped = String::new();
    for (i, c) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i).is_multiple_of(3) {
            grouped.push('.');
        }
        grouped.push(c);
    }
    let symbol = match currency {
        "EUR" | "" => "€",
        "USD" => "$",
        "GBP" => "£",
        other => other,
    };
    let sign = if cents < 0 { "-" } else { "" };
    format!("{sign}{grouped},{:02} {symbol}", abs % 100)
}

/// `2026-11-13` -> `13.11.2026`; anything else is returned unchanged.
fn german_date(iso: &str) -> String {
    let head = iso.get(..10).unwrap_or(iso);
    let parts: Vec<&str> = head.split('-').collect();
    match parts.as_slice() {
        [y, m, d]
            if y.len() == 4
                && m.len() == 2
                && d.len() == 2
                && parts.iter().all(|p| p.bytes().all(|b| b.is_ascii_digit())) =>
        {
            format!("{d}.{m}.{y}")
        }
        _ => iso.to_string(),
    }
}

/// Up to two capital letters for the account badge: initials of the first two words, or the
/// first two letters of a single word.
fn monogram(name: &str) -> String {
    let words: Vec<&str> = name
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();
    let letters: Vec<char> = match words.as_slice() {
        [] => return "•".into(),
        [one] => one.chars().take(2).collect(),
        [a, b, ..] => a.chars().take(1).chain(b.chars().take(1)).collect(),
    };
    letters.iter().flat_map(|c| c.to_uppercase()).collect()
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
        (0x3b, 0x82, 0xf6),
        (0x10, 0xb9, 0x81),
        (0xd9, 0x77, 0x06),
        (0xa8, 0x55, 0xf7),
        (0xef, 0x44, 0x44),
        (0xe1, 0x1d, 0x48),
        (0x6e, 0x76, 0x81),
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

fn account_rows(vault: &Vault, privacy: bool) -> Result<(Vec<AccountRow>, String), String> {
    let accounts = vault.list_accounts().map_err(|e| e.to_string())?;
    let total: i64 = accounts
        .iter()
        .filter(|a| a.in_total && a.currency == "EUR")
        .map(|a| a.balance_cents)
        .sum();
    // Accounts are grouped under their bank; the sort is stable, so the order inside a group stays.
    let mut sorted: Vec<&_> = accounts.iter().collect();
    sorted.sort_by_key(|a| a.bank_name.to_lowercase());
    let mut last_group = String::new();
    let rows = sorted
        .into_iter()
        .map(|a| {
            let group = if a.bank_name.trim().is_empty() {
                "Sonstige".to_string()
            } else {
                a.bank_name.clone()
            };
            let header = if group == last_group {
                String::new()
            } else {
                last_group = group.clone();
                group
            };
            AccountRow {
                header: header.into(),
                monogram: monogram(&a.name).into(),
                id: a.id as i32,
                name: a.name.clone().into(),
                bank: a.bank_name.clone().into(),
                iban: daily::mask(&mask_iban(&a.iban, &a.account_number), privacy).into(),
                dot: hex_color(&a.color_hex).unwrap_or_else(|| dot_color(&a.bank_name)),
                balance: daily::mask(&money(a.balance_cents, &a.currency), privacy).into(),
                currency: a.currency.clone().into(),
                negative: a.balance_cents < 0 && !privacy,
                archived: a.archived_unix.is_some(),
            }
        })
        .collect();
    Ok((rows, daily::mask(&money(total, "EUR"), privacy)))
}

/// Most bookings the list keeps in memory per account scope; filters run on these without the vault.
const ROW_LIMIT: u32 = 2000;

/// Bookings of a listing target (one account, all, unchecked, uncategorized or one category).
fn load_rows(vault: &Vault, target: Target) -> Result<Vec<Row>, String> {
    let page = vault
        .list_transactions(BookingFilter {
            limit: ROW_LIMIT,
            ..nav::booking_filter(target)
        })
        .map_err(|e| e.to_string())?;
    Ok(page.transactions.iter().map(Row::from).collect())
}

/// UI-thread state behind the booking list, filter bar and inspector.
#[derive(Default)]
struct State {
    rows: Vec<Row>,
    shown: Vec<usize>,
    categories: Vec<Category>,
    filter: Filter,
    selected_booking: Option<i64>,
    /// Drops the result of a superseded background load.
    generation: u64,
    /// (account id, label, bank name) of the accounts a transfer can start from.
    transfer_sources: Vec<(i64, String, String)>,
    /// What the sidebar selected; decides which bookings `reload` loads.
    target: Target,
    /// Decoded merchant logos by candidate key (`logos::key`); lives for the session.
    logos: std::collections::HashMap<String, slint::Image>,
    /// Keys already requested this session (hit or miss), so a miss is not retried on every redraw.
    logos_requested: std::collections::HashSet<String>,
}

/// One-booking edit run against the vault for the selected booking id.
type EditFn = Box<dyn Fn(&Vault, i64) -> Result<(), String>>;

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> R {
    STATE.with(|s| f(&mut s.borrow_mut()))
}

fn privacy_on(win: &MainWindow) -> bool {
    daily::effective_privacy(win.get_privacy(), win.get_unlocked())
}

fn tint(hex: &str) -> slint::Color {
    hex_color(hex).unwrap_or_else(|| slint::Color::from_rgb_u8(0x8e, 0x8e, 0x93))
}

/// Logo of a row, if loaded. Never in privacy mode: the logo would give the counterparty away.
fn logo_of(st: &State, r: &Row, privacy: bool) -> Option<slint::Image> {
    if privacy || r.logo_domains.is_empty() {
        return None;
    }
    st.logos.get(&logos::key(&r.logo_domains)).cloned()
}

fn booking_row(st: &State, b: &Row, privacy: bool) -> BookingRow {
    let logo = logo_of(st, b, privacy);
    let detail = if b.booking_text.is_empty() {
        b.purpose.clone()
    } else {
        cockpit::booking_type_label(&b.booking_text)
    };
    BookingRow {
        id: b.id as i32,
        counterparty: daily::mask(&b.counterparty, privacy).into(),
        account: b.account_name.clone().into(),
        category: if b.category_name.is_empty() {
            "Ohne Kategorie".into()
        } else {
            b.category_name.clone().into()
        },
        category_color: tint(&b.category_color_hex),
        detail: daily::mask(
            &detail,
            privacy,
        )
        .into(),
        amount: daily::mask(&money(b.amount_cents, &b.currency), privacy).into(),
        negative: b.amount_cents < 0 && !privacy,
        checked: b.checked,
        monogram: if privacy {
            "•".into()
        } else if b.monogram.is_empty() {
            monogram(&b.counterparty).into()
        } else {
            b.monogram.clone().into()
        },
        tint: tint(&b.tint_hex),
        has_logo: logo.is_some(),
        logo: logo.unwrap_or_default(),
    }
}

/// Builds the day cards and the inspector from the cached rows; never touches the vault.
fn render_bookings(win: &MainWindow) {
    let privacy = privacy_on(win);
    let (days, inspector, cat_index) = with_state(|st| {
        let shown: Vec<&Row> = st.shown.iter().map(|&i| &st.rows[i]).collect();
        let days: Vec<DayGroup> = cockpit::group_by_day(&shown)
            .into_iter()
            .map(|d| DayGroup {
                title: cockpit::day_title(&d.date).into(),
                sum: daily::mask(
                    &cockpit::day_sum_text(d.sum_cents, &money, &d.currency),
                    privacy,
                )
                .into(),
                negative: d.sum_cents < 0 || privacy,
                rows: ModelRc::new(VecModel::from(
                    d.indices
                        .iter()
                        .map(|&i| booking_row(st, shown[i], privacy))
                        .collect::<Vec<_>>(),
                )),
            })
            .collect();
        let insp = st
            .selected_booking
            .and_then(|id| st.rows.iter().find(|r| r.id == id))
            .map(|r| {
                let logo = logo_of(st, r, privacy);
                let row = booking_row(st, r, privacy);
                (daily::inspect(r, privacy, money), row, logo, r.recurring)
            });
        let idx = insp
            .as_ref()
            .and_then(|i| i.0.category_id)
            .and_then(|cid| st.categories.iter().position(|c| c.id == cid))
            .map_or(0, |p| p as i32 + 1);
        (days, insp, idx)
    });
    win.set_days(ModelRc::new(VecModel::from(days)));
    match inspector {
        Some((i, row, logo, recurring)) => {
            // The note box keeps unsaved typing while the same booking stays selected.
            if win.get_selected_booking() != i.id as i32 {
                win.set_note_text(i.note.clone().into());
            }
            win.set_selected_booking(i.id as i32);
            win.set_inspector_checked(i.checked);
            let subtitle = [i.account.as_str(), i.purpose.as_str()]
                .iter()
                .filter(|t| !t.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join(" · ");
            win.set_inspector(InspectorData {
                counterparty: i.counterparty.into(),
                iban: i.iban.into(),
                purpose: i.purpose.into(),
                booking_date: german_date(&i.booking_date).into(),
                value_date: i.value_date.into(),
                account: i.account.into(),
                amount: i.amount.into(),
                note: i.note.into(),
                read_only: i.read_only,
                monogram: row.monogram,
                tint: row.tint,
                has_logo: logo.is_some(),
                logo: logo.unwrap_or_default(),
                subtitle: subtitle.into(),
                recurring,
            });
            win.set_inspector_category(cat_index);
            win.set_has_inspector(true);
        }
        None => {
            win.set_selected_booking(-1);
            win.set_has_inspector(false);
        }
    }
}

/// Starts loading the logos of the loaded rows that are not known yet (off the UI thread).
fn request_logos(win: &MainWindow, vault: Arc<Vault>) {
    let wanted: Vec<Vec<String>> = with_state(|st| {
        let mut out: Vec<Vec<String>> = Vec::new();
        for r in st.rows.iter().filter(|r| !r.logo_domains.is_empty()) {
            let key = logos::key(&r.logo_domains);
            if out.len() < logos::MAX_PER_LOAD && st.logos_requested.insert(key) {
                out.push(r.logo_domains.clone());
            }
        }
        out
    });
    if wanted.is_empty() {
        return;
    }
    let weak = win.as_weak();
    logos::load(vault, wanted, move |batch| {
        let _ = weak.upgrade_in_event_loop(move |win| {
            with_state(|st| {
                for (key, buf) in batch {
                    st.logos.insert(key, slint::Image::from_rgba8(buf));
                }
            });
            render_bookings(&win);
        });
    });
}

/// Fills the cashflow chart and the budget card. The core calls run on a worker thread.
fn refresh_dashboard(win: &MainWindow, vault: Arc<Vault>) {
    let gran = match win.get_cashflow_period() {
        1 => PeriodGranularity::Quarter,
        2 => PeriodGranularity::Year,
        _ => PeriodGranularity::Month,
    };
    let (year, month) = cockpit::current_year_month();
    let period = win.get_cashflow_period();
    let account_flow = with_state(|st| match st.target {
        Target::Account(_) => Some(cockpit::cashflow_from_rows(
            &st.rows,
            period,
            (year, month),
            6,
        )),
        _ => None,
    });
    let weak = win.as_weak();
    std::thread::spawn(move || {
        // One account: sum its loaded bookings; everything else: the core's all-account figures.
        let flow = match account_flow {
            Some(f) => f,
            None => vault.cashflow_by_period(gran, 6).unwrap_or_default(),
        };
        let status = vault
            .list_category_budget_progress(year, month)
            .unwrap_or_default();
        let _ = weak.upgrade_in_event_loop(move |win| {
            let privacy = privacy_on(&win);
            let (bars, ticks) = cockpit::chart(&flow);
            win.set_cashflow_bars(ModelRc::new(VecModel::from(
                bars.into_iter()
                    .map(|b| BarGroup {
                        label: b.label.into(),
                        income: if privacy { 0.0 } else { b.income },
                        expense: if privacy { 0.0 } else { b.expense },
                    })
                    .collect::<Vec<_>>(),
            )));
            let ticks: Vec<SharedString> = ticks
                .into_iter()
                .map(|t| if privacy { "•".into() } else { t.into() })
                .collect();
            win.set_cashflow_ticks(ModelRc::new(VecModel::from(ticks)));
            let mut lines = cockpit::budgets(&status);
            let has_budgets = !lines.is_empty();
            if !has_budgets {
                lines = with_state(|st| cockpit::top_spending(&st.rows, year, month, 4));
            }
            win.set_budget_title(if has_budgets {
                "Monatsbudgets".into()
            } else {
                "Größte Ausgaben".into()
            });
            win.set_budget_lines(ModelRc::new(VecModel::from(
                lines
                    .into_iter()
                    .map(|l| {
                        let spent = daily::mask(&money(l.spent_cents, "EUR"), privacy);
                        BudgetLine {
                            name: daily::mask(&l.name, false).into(),
                            amount: match l.limit_cents {
                                Some(limit) if !privacy => format!(
                                    "{} / {}",
                                    money(l.spent_cents, "EUR"),
                                    money(limit, "EUR")
                                )
                                .into(),
                                _ => spent.into(),
                            },
                            progress: l.progress,
                            over: l.limit_cents.is_some() && l.progress > 1.0,
                            color: match l.limit_cents {
                                Some(_) => tint(cockpit::budget_color_hex(l.progress)),
                                None => tint(&l.color_hex),
                            },
                        }
                    })
                    .collect::<Vec<_>>(),
            )));
        });
    });
}

/// Re-applies the filter bar to the cached rows (no vault access) and redraws.
fn apply_filter(win: &MainWindow) {
    with_state(|st| {
        st.filter = Filter {
            search: win.get_search_text().to_string(),
            uncategorized_only: win.get_uncategorized_only(),
            status: StatusFilter::from_index(win.get_status_index()),
        };
        st.shown = daily::visible(&st.rows, &st.filter);
        st.selected_booking = daily::keep_selection(&st.rows, &st.shown, st.selected_booking)
            .or_else(|| st.shown.first().map(|&i| st.rows[i].id));
    });
    render_bookings(win);
}

/// Loads the bookings of the current account scope on a worker thread, then redraws.
fn reload(win: &MainWindow, vault: Arc<Vault>) {
    let target = with_state(|st| st.target);
    let generation = with_state(|st| {
        st.generation += 1;
        st.generation
    });
    let weak = win.as_weak();
    std::thread::spawn(move || {
        let rows = load_rows(&vault, target);
        let cats = vault.list_categories(None, None).map_err(|e| e.to_string());
        let _ = weak.upgrade_in_event_loop(move |win| {
            let vault = vault.clone();
            if with_state(|st| st.generation) != generation {
                return;
            }
            match (rows, cats) {
                (Ok(rows), Ok(cats)) => {
                    let mut names = vec![SharedString::from("Ohne Kategorie")];
                    names.extend(cats.iter().map(|c| SharedString::from(c.path.as_str())));
                    win.set_category_names(ModelRc::new(VecModel::from(names)));
                    let mut tiles = vec![TileRow {
                        index: 0,
                        name: "Ohne Kategorie".into(),
                        color: tint(""),
                    }];
                    tiles.extend(cats.iter().enumerate().map(|(i, c)| TileRow {
                        index: i as i32 + 1,
                        name: c.name.clone().into(),
                        color: tint(&c.color_hex),
                    }));
                    win.set_category_tiles(ModelRc::new(VecModel::from(tiles)));
                    with_state(|st| {
                        st.rows = rows;
                        st.categories = cats;
                    });
                    apply_filter(&win);
                    request_logos(&win, vault.clone());
                    refresh_dashboard(&win, vault);
                }
                (Err(e), _) | (_, Err(e)) => win.set_sync_status(e.into()),
            }
        });
    });
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

    fn ask_import_password(&self) -> Option<Zeroizing<String>> {
        self.drain();
        self.show(
            "pin",
            "Passwort der MoneyMoney-Datenbank".into(),
            "Das Passwort wird nur für diesen Import im Speicher gehalten.".into(),
            None,
        );
        self.replies
            .lock()
            .unwrap()
            .recv()
            .ok()
            .flatten()
            .filter(|p| !p.is_empty())
            .map(Zeroizing::new)
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

/// Redraws the account list and header (balances follow privacy mode).
/// `selected`: account id, 0 = all accounts, `None` = the first account. Returns the selection.
fn render_header(
    win: &MainWindow,
    vault: &Vault,
    selected: Option<i64>,
) -> Result<Option<i64>, String> {
    let (rows, total) = account_rows(vault, win.get_privacy())?;
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
    win.set_total(total.clone().into());
    let sel = selected.or(first);
    win.set_selected(sel.map_or(-1, |s| s as i32));
    let cur = if sel == Some(0) {
        ("Alle Konten".to_string(), total, "EUR".to_string())
    } else {
        header
            .iter()
            .find(|h| Some(h.0) == sel)
            .map(|h| (h.1.clone(), h.2.clone(), h.3.clone()))
            .unwrap_or_else(|| (String::new(), money(0, "EUR"), "EUR".into()))
    };
    win.set_selected_name(cur.0.into());
    win.set_selected_balance(cur.1.into());
    win.set_selected_currency(cur.2.into());
    Ok(sel)
}

/// Header plus the view of the selected target (bookings reload, or the depot / list view).
fn show(win: &MainWindow, vault: &Arc<Vault>, selected: Option<i64>) {
    match render_header(win, vault, selected) {
        Ok(sel) => {
            refresh_transfer_sources(win, vault);
            views_ui::sync_target(sel);
            if sel.is_some() {
                views_ui::apply_view(win, vault);
            } else {
                with_state(|st| {
                    st.rows.clear();
                    st.shown.clear();
                    st.selected_booking = None;
                });
                render_bookings(win);
            }
            views_ui::refresh_sidebar(win, vault);
            win.set_unlocked(true);
            manage_ui::refocus_later(win);
        }
        Err(e) => win.set_message(e.into()),
    }
}

/// Accounts a transfer can start from: those that belong to a bank connection.
fn refresh_transfer_sources(win: &MainWindow, vault: &Vault) {
    let sources: Vec<(i64, String, String)> = vault
        .list_accounts()
        .unwrap_or_default()
        .iter()
        .filter(|a| a.connection_id.is_some())
        .map(|a| (a.id, a.name.clone(), a.bank_name.clone()))
        .collect();
    let labels: Vec<SharedString> = sources
        .iter()
        .map(|s| SharedString::from(s.1.as_str()))
        .collect();
    win.set_transfer_accounts(ModelRc::new(VecModel::from(labels)));
    with_state(|st| st.transfer_sources = sources);
}

/// Result line of an import run.
fn import_file(
    vault: &Arc<Vault>,
    path: &std::path::Path,
    target_account: Option<i64>,
    ui: &DialogBridge,
) -> Result<String, String> {
    let e = |e: girocrab_core::CoreError| e.to_string();
    let kind = daily::import_kind(path)
        .ok_or("Dieser Dateityp wird nicht unterstützt (.moneymoney, .csv, .xml, .sta, .mt940).")?;
    match kind {
        daily::ImportKind::Statement => {
            let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let r = vault
                .import_moneymoney_data(bytes, name, target_account, true, true)
                .map_err(e)?;
            Ok(format!(
                "Import: {} neu, {} bereits vorhanden, {} ergänzt.",
                r.imported, r.duplicates, r.enriched
            ))
        }
        daily::ImportKind::MoneyMoneyDb => {
            let pw = ui
                .ask_import_password()
                .ok_or("Import abgebrochen.".to_string())?;
            let location = path.display().to_string();
            let preview = vault
                .preview_moneymoney_database(location.clone(), pw.to_string(), None)
                .map_err(e)?;
            let options = girocrab_core::importers::moneymoney_db::MoneyMoneyDbImportOptions {
                accounts: preview
                    .accounts
                    .iter()
                    .map(
                        |a| girocrab_core::importers::moneymoney_db::MoneyMoneyDbAccountChoice {
                            mm_id: a.mm_id,
                            import: true,
                            kind: a.suggested_kind,
                            target_account_id: a.existing_account_id,
                        },
                    )
                    .collect(),
                import_categories: true,
                import_notes: true,
                create_connections: false,
                import_groups: false,
                import_statements: false,
                statements_dir: None,
                bank_choices: vec![],
                import_transfer_templates: true,
            };
            let r = vault
                .import_moneymoney_database(location, pw.to_string(), options)
                .map_err(e)?;
            Ok(format!(
                "MoneyMoney-Import: {} neue Umsätze, {} Duplikate, {} Konten neu, {} zusammengeführt.",
                r.bookings_new, r.bookings_duplicates, r.accounts_created, r.accounts_merged
            ))
        }
    }
}

/// Native file dialog (Windows). Elsewhere (development builds) there is none.
#[cfg(windows)]
fn pick_import_file() -> Option<PathBuf> {
    rfd::FileDialog::new()
        .set_title("Umsätze importieren")
        .add_filter(
            "MoneyMoney, CSV, CAMT",
            &["moneymoney", "csv", "xml", "sta", "mt940", "txt"],
        )
        .pick_file()
}

#[cfg(not(windows))]
fn pick_import_file() -> Option<PathBuf> {
    std::env::var_os("GIROCRAB_IMPORT_FILE").map(PathBuf::from)
}

/// `TransferSession` driven synchronously.
struct CoreTransfer {
    session: Arc<girocrab_core::TransferSession>,
    rt: tokio::runtime::Runtime,
}

impl transfer_flow::TransferStepper for CoreTransfer {
    fn start(&self) -> Result<TransferStep, String> {
        self.rt
            .block_on(self.session.start())
            .map_err(|e| e.to_string())
    }
    fn submit_code(&self, code: String) -> Result<TransferStep, String> {
        self.rt
            .block_on(self.session.submit_code(code))
            .map_err(|e| e.to_string())
    }
    fn poll(&self) -> Result<TransferStep, String> {
        self.rt
            .block_on(self.session.poll())
            .map_err(|e| e.to_string())
    }
    fn confirm_payee(&self) -> Result<TransferStep, String> {
        self.rt
            .block_on(self.session.confirm_payee())
            .map_err(|e| e.to_string())
    }
    fn cancel(&self) {
        let _ = self.rt.block_on(self.session.cancel());
    }
}

impl transfer_flow::TransferUi for DialogBridge {
    fn confirm_payee(&self, check: &PayeeCheck) -> bool {
        self.drain();
        self.show(
            "confirm",
            "Empfänger prüfen".into(),
            transfer_flow::payee_text(check),
            None,
        );
        matches!(self.replies.lock().unwrap().recv(), Ok(Some(_)))
    }
}

fn run_transfer(
    vault: Arc<Vault>,
    demo: bool,
    request: girocrab_core::SepaTransferRequest,
    bank: &str,
    ui: &DialogBridge,
) -> Result<String, String> {
    if policy::apply(VERSION).all {
        return Err(
            "Überweisung gesperrt: Diese Version ist durch die Sicherheitssperre gesperrt.".into(),
        );
    }
    let mut secret = if demo {
        Zeroizing::new(String::new())
    } else {
        use sync_flow::Ui;
        match ui.ask_secret(bank) {
            Some(s) if !s.trim().is_empty() => s,
            Some(_) => return Err("Bitte die PIN eingeben.".into()),
            None => return Err(transfer_flow::CANCELLED_TRANSFER.into()),
        }
    };
    let session = vault
        .begin_transfer(request, std::mem::take(&mut *secret), demo)
        .map_err(|e| e.to_string())?;
    transfer_flow::drive_transfer(
        &CoreTransfer {
            session,
            rt: tokio_runtime()?,
        },
        ui,
    )
}

fn main() -> Result<(), slint::PlatformError> {
    views_ui::purge_stale_documents();
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
                    views_ui::invalidate_planned_count();
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
            views_ui::select_target(
                &win,
                &v,
                if id > 0 {
                    Target::Account(id as i64)
                } else {
                    Target::AllAccounts
                },
            );
        });
    }
    {
        // Search text, "ohne Kategorie" toggle and status filter: in memory, no vault access.
        let weak = win.as_weak();
        win.on_search_changed(move || {
            if let Some(win) = weak.upgrade() {
                apply_filter(&win);
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
                            views_ui::invalidate_planned_count();
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
                    views_ui::invalidate_planned_count();
                    show(&win, &v, selected);
                    win.set_busy(false);
                    win.set_sync_status(result.unwrap_or_else(|e| e).into());
                });
            });
        });
    }

    {
        let (weak, vault) = (win.as_weak(), vault.clone());
        win.on_cashflow_changed(move || {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            refresh_dashboard(&win, v);
        });
    }
    {
        let weak = win.as_weak();
        win.on_select_booking(move |id| {
            let Some(win) = weak.upgrade() else { return };
            with_state(|st| st.selected_booking = Some(id as i64));
            render_bookings(&win);
        });
    }
    {
        // Privacy mode: only the rendering changes; the cached rows stay as they are.
        let (weak, vault) = (win.as_weak(), vault.clone());
        win.on_privacy_changed(move || {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            let sel = Some(win.get_selected() as i64).filter(|s| *s >= 0);
            let _ = render_header(&win, &v, sel);
            render_bookings(&win);
            views_ui::rerender(&win);
        });
    }
    {
        let (weak, vault) = (win.as_weak(), vault.clone());
        win.on_lock(move || {
            let Some(win) = weak.upgrade() else { return };
            *vault.lock().unwrap() = None;
            with_state(|st| *st = State::default());
            win.set_unlocked(false);
            win.set_days(ModelRc::new(VecModel::from(Vec::<DayGroup>::new())));
            win.set_accounts(ModelRc::new(VecModel::from(Vec::<AccountRow>::new())));
            win.set_has_inspector(false);
            views_ui::on_lock(&win);
            win.set_first_run(false);
        });
    }
    {
        // Inspector edits: one-row updates, applied to the cache so the list needs no reload.
        let (weak, vault) = (win.as_weak(), vault.clone());
        let edit = move |f: EditFn| {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            if privacy_on(&win) {
                return;
            }
            let Some(id) = with_state(|st| st.selected_booking) else {
                return;
            };
            if let Err(e) = f(&v, id) {
                win.set_sync_status(e.into());
                return;
            }
            apply_filter(&win);
        };
        let edit = Arc::new(edit);
        {
            let edit = edit.clone();
            win.on_set_category(move |index| {
                edit(Box::new(move |v, id_| {
                    let cat = with_state(|st| {
                        (index > 0)
                            .then(|| st.categories.get(index as usize - 1).cloned())
                            .flatten()
                    });
                    v.set_transaction_category(id_, cat.as_ref().map(|c| c.id))
                        .map_err(|e| e.to_string())?;
                    with_state(|st| {
                        if let Some(r) = st.rows.iter_mut().find(|r| r.id == id_) {
                            r.category_id = cat.as_ref().map(|c| c.id);
                            r.category_name =
                                cat.as_ref().map(|c| c.name.clone()).unwrap_or_default();
                            r.category_color_hex = cat
                                .as_ref()
                                .map(|c| c.color_hex.clone())
                                .unwrap_or_default();
                        }
                    });
                    Ok(())
                }))
            });
        }
        {
            let edit = edit.clone();
            win.on_set_checked(move |checked| {
                edit(Box::new(move |v, id_| {
                    v.set_transaction_checked(id_, checked)
                        .map_err(|e| e.to_string())?;
                    with_state(|st| {
                        if let Some(r) = st.rows.iter_mut().find(|r| r.id == id_) {
                            r.checked = checked;
                        }
                    });
                    Ok(())
                }))
            });
        }
        {
            let edit = edit.clone();
            win.on_save_note(move |text| {
                let text = text.trim().to_string();
                edit(Box::new(move |v, id_| {
                    v.update_transaction_note(id_, text.clone())
                        .map_err(|e| e.to_string())?;
                    with_state(|st| {
                        if let Some(r) = st.rows.iter_mut().find(|r| r.id == id_) {
                            r.note = text.clone();
                        }
                    });
                    Ok(())
                }))
            });
        }
    }
    {
        let (weak, vault) = (win.as_weak(), vault.clone());
        win.on_apply_rules(move || {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            win.set_busy(true);
            win.set_sync_status("Regeln werden angewendet …".into());
            let weak = win.as_weak();
            std::thread::spawn(move || {
                let result = v.apply_rules(true).map_err(|e| e.to_string());
                let _ = weak.upgrade_in_event_loop(move |win| {
                    win.set_busy(false);
                    match result {
                        Ok(n) => {
                            win.set_sync_status(
                                format!("Regeln angewendet: {n} Umsätze kategorisiert.").into(),
                            );
                            reload(&win, v);
                        }
                        Err(e) => win.set_sync_status(e.into()),
                    }
                });
            });
        });
    }
    {
        let (weak, vault, bridge) = (win.as_weak(), vault.clone(), bridge.clone());
        win.on_import_file(move || {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            let target = Some(win.get_selected() as i64).filter(|s| *s > 0);
            win.set_busy(true);
            win.set_sync_status("Import: Datei wählen …".into());
            let (weak, bridge) = (win.as_weak(), bridge.clone());
            // The file dialog and the core import block: worker thread.
            std::thread::spawn(move || {
                let result = match pick_import_file() {
                    None => Err("Import abgebrochen.".to_string()),
                    Some(path) => import_file(&v, &path, target, &bridge),
                };
                bridge.hide();
                let _ = weak.upgrade_in_event_loop(move |win| {
                    win.set_busy(false);
                    let ok = result.is_ok();
                    let sel = Some(win.get_selected() as i64).filter(|s| *s >= 0);
                    if ok {
                        views_ui::invalidate_planned_count();
                        show(&win, &v, sel);
                    }
                    win.set_sync_status(result.unwrap_or_else(|e| e).into());
                });
            });
        });
    }
    {
        let weak = win.as_weak();
        win.on_transfer_start(move || {
            let Some(win) = weak.upgrade() else { return };
            win.set_transfer_status(SharedString::new());
            win.set_transfer_open(true);
        });
    }
    {
        let (weak, vault, demo_active, bridge) = (
            win.as_weak(),
            vault.clone(),
            demo_active.clone(),
            bridge.clone(),
        );
        win.on_transfer_submit(move |index, name, iban, amount, purpose| {
            let (Some(win), Some(v)) = (weak.upgrade(), vault.lock().unwrap().clone()) else {
                return;
            };
            let source = with_state(|st| st.transfer_sources.get(index.max(0) as usize).cloned());
            let input = daily::TransferInput {
                account_id: source.as_ref().map_or(0, |s| s.0),
                name: name.to_string(),
                iban: iban.to_string(),
                amount: amount.to_string(),
                purpose: purpose.to_string(),
            };
            let request = match daily::validate_transfer(&input) {
                Ok(r) => r,
                Err(e) => {
                    win.set_transfer_status(e.into());
                    return;
                }
            };
            let bank = source.map(|s| s.2).unwrap_or_default();
            let demo = *demo_active.lock().unwrap();
            win.set_transfer_open(false);
            win.set_busy(true);
            win.set_sync_status("Überweisung läuft …".into());
            let (weak, bridge) = (win.as_weak(), bridge.clone());
            std::thread::spawn(move || {
                let result = run_transfer(v.clone(), demo, request, &bank, &bridge);
                bridge.hide();
                let _ = weak.upgrade_in_event_loop(move |win| {
                    let sel = Some(win.get_selected() as i64).filter(|s| *s >= 0);
                    views_ui::invalidate_planned_count();
                    show(&win, &v, sel);
                    win.set_busy(false);
                    win.set_sync_status(result.unwrap_or_else(|e| e).into());
                });
            });
        });
    }

    manage_ui::wire(&win, vault.clone());
    views_ui::wire(&win, vault.clone());

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
        let (rows, _) = account_rows(&vault, false).unwrap();
        assert!(!rows.is_empty());
        let first = Target::Account(rows[0].id as i64);
        assert!(!load_rows(&vault, first).unwrap().is_empty());
        // All accounts (scope 0) holds at least as many rows as one account.
        assert!(
            load_rows(&vault, Target::AllAccounts).unwrap().len()
                >= load_rows(&vault, first).unwrap().len()
        );
        // Privacy hides balances and the IBAN tail.
        let (hidden, total) = account_rows(&vault, true).unwrap();
        assert!(hidden
            .iter()
            .all(|r| r.balance == daily::MASK && r.iban != "•••• 3000"));
        assert_eq!(total, daily::MASK);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn amounts_use_euro_sign_and_german_separators() {
        assert_eq!(money(428050, "EUR"), "4.280,50 €");
        assert_eq!(money(-3999, "EUR"), "-39,99 €");
        assert_eq!(money(-64280, "EUR"), "-642,80 €");
        assert_eq!(money(5, "EUR"), "0,05 €");
        assert_eq!(money(-123456789, "EUR"), "-1.234.567,89 €");
        assert_eq!(money(100, "CHF"), "1,00 CHF");
    }

    #[test]
    fn dates_are_german() {
        assert_eq!(german_date("2026-11-13"), "13.11.2026");
        assert_eq!(german_date("2026-11-13T10:00:00"), "13.11.2026");
        assert_eq!(german_date("13.11.2026"), "13.11.2026");
        assert_eq!(german_date(""), "");
    }

    #[test]
    fn monograms() {
        assert_eq!(monogram("Musterbank Girokonto"), "MG");
        assert_eq!(monogram("Einzeltitel-Depot"), "ED");
        assert_eq!(monogram("Bargeld"), "BA");
        assert_eq!(monogram(""), "•");
    }

    #[test]
    fn iban_is_masked() {
        assert_eq!(mask_iban("DE89 3704 0044 0532 0130 00", ""), "•••• 3000");
        assert_eq!(mask_iban("", ""), "");
    }
}
