//! Times the core calls behind a category change (write + the reloads AppModel
//! used to run synchronously), on a throw-away demo vault whose bookings are
//! cloned COPIES times (each copy shifted further back).
//! Usage: COPIES=600 cargo run --release -q -p girocrab-core --example category_perf
//!
//! Reference (M-series Mac, release build, COPIES=600 → 31,252 bookings, 2026-11-12):
//!   set_transaction_category        0.6 ms
//!   list_transactions(limit 3000) 150 ms   (same as without limit: the page is cut last)
//!   list_categories                 35 ms
//!   list_account_groups / _user_groups  1.8 ms each (41 ms before the covering indexes)
//!   list_rules                      0.6 ms (84 ms before the covering indexes)
//!   investment_dashboard           150 ms
//!   merchant_stats / selection_flow ~150 ms each (a full pass over all bookings)
//! RULE_INDEX=1 creates the covering indexes by hand on a vault that lacks them.
use girocrab_core::models::{BookingFilter, BookingScope};
use girocrab_core::vault::Vault;

fn time<T>(label: &str, mut f: impl FnMut() -> T) -> f32 {
    let mut ms: Vec<f32> = (0..5)
        .map(|_| {
            let t = std::time::Instant::now();
            let _ = f();
            t.elapsed().as_secs_f32() * 1000.0
        })
        .collect();
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{label:<52} {:>8.1} ms", ms[2]);
    ms[2]
}

fn main() {
    let copies: usize = std::env::var("COPIES")
        .ok()
        .and_then(|x| x.parse().ok())
        .unwrap_or(80);
    let key = vec![9u8; 32];
    let tmp = std::env::temp_dir().join(format!("gc-cat-perf-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp).unwrap();
    let path = tmp.join("vault.db").to_string_lossy().to_string();
    {
        let v = Vault::open(path.clone(), key.clone()).unwrap();
        v.seed_demo_data().unwrap();
    }
    {
        // Clone the demo bookings straight in SQL (the vault's own connection is crate-private).
        let c = rusqlite::Connection::open(&path).unwrap();
        c.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hex::encode(&key)))
            .unwrap();
        let cols: Vec<String> = c
            .prepare("SELECT name FROM pragma_table_info('transactions') WHERE name != 'id'")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let tx = c.unchecked_transaction().unwrap();
        for k in 1..=copies {
            let select: Vec<String> = cols
                .iter()
                .map(|n| match n.as_str() {
                    "booking_date" | "value_date" => format!("date({n}, '-{} days')", k * 183),
                    "external_id" => format!("{n} || '#{k}'"),
                    "uuid" => "lower(hex(randomblob(16)))".into(),
                    "import_fp" => "''".into(),
                    _ => n.clone(),
                })
                .collect();
            tx.execute_batch(&format!(
                "INSERT INTO transactions ({}) SELECT {} FROM transactions WHERE external_id NOT LIKE '%#%'",
                cols.join(","),
                select.join(",")
            ))
            .unwrap();
        }
        tx.commit().unwrap();
        if std::env::var("RULE_INDEX").is_ok_and(|v| !v.is_empty()) {
            c.execute_batch("CREATE INDEX tx_rule_live ON transactions(rule_id, deleted_ms); CREATE INDEX tx_acct_live ON transactions(account_id, category_id, checked, deleted_ms); ANALYZE;").unwrap();
        }
    }
    let vault = Vault::open(path, key).unwrap();
    let all = vault
        .list_transactions(BookingFilter {
            scope: BookingScope::All,
            ..Default::default()
        })
        .unwrap();
    let cats = vault.list_categories(None, None).unwrap();
    println!(
        "bookings: {}, categories: {}\n",
        all.transactions.len(),
        cats.len()
    );
    let b = all.transactions[0].clone();
    let (c1, c2) = (cats[3].id, cats[5].id);

    // The UI's list filter: newest 3000 bookings, all accounts, current period.
    let ui_filter = || BookingFilter {
        scope: BookingScope::All,
        limit: 3000,
        ..Default::default()
    };
    let mut flip = false;
    let mut total = 0.0;
    total += time("set_transaction_category", || {
        flip = !flip;
        vault.set_transaction_category(b.id, Some(if flip { c1 } else { c2 }))
    });
    total += time("reloadBookings: list_transactions(limit 3000)", || {
        vault.list_transactions(ui_filter())
    });
    total += time("reloadCategories: list_categories", || {
        vault.list_categories(None, None)
    });
    total += time("reloadAccounts: list_account_groups", || {
        vault.list_account_groups()
    });
    total += time("reloadAccounts: list_user_groups", || {
        vault.list_user_groups()
    });
    total += time("reloadAccounts: list_bank_connections", || {
        vault.list_bank_connections()
    });
    total += time("reloadRules: list_rules", || vault.list_rules());
    total += time("reloadDashboard: investment_dashboard(6)", || {
        vault.investment_dashboard(6)
    });
    println!(
        "{:<52} {:>8.1} ms  (synchronous on the main thread)",
        "sum", total
    );
    println!();
    time(
        "merchant_stats (off main, ×2: reloadBookings + reloadMerchantStats)",
        || vault.merchant_stats(b.merchant.key.clone()),
    );
    time(
        "list_transactions(all, no limit) – what the dashboard reads",
        || {
            vault.list_transactions(BookingFilter {
                scope: BookingScope::All,
                ..Default::default()
            })
        },
    );
    time(
        "'Ohne Kategorie': list_transactions(uncategorized, 3000)",
        || {
            vault.list_transactions(BookingFilter {
                scope: BookingScope::All,
                uncategorized_only: true,
                limit: 3000,
                ..Default::default()
            })
        },
    );
    time(
        "'Ohne Kategorie': + selection_flow (reloadSelectionKPIs)",
        || vault.selection_flow(vec![], None, None),
    );
    let _ = std::fs::remove_dir_all(&tmp);
}
