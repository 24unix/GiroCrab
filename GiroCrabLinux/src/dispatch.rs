//! Name → core call. Each `Vault` method is one line in `vault_methods!`;
//! argument types come from the method signature, names are the Rust
//! parameter names (snake_case), missing arguments are `null` (→ `None`).

use std::sync::{Arc, Mutex};

use girocrab_core::Vault;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};

type R = Result<Value, String>;

extern "C" {
    fn girocrab_grab_window(path: *const std::os::raw::c_char) -> bool;
    fn girocrab_print_pdf(
        path: *const std::os::raw::c_char,
        job_name: *const std::os::raw::c_char,
    ) -> i32;
    fn girocrab_print_pdf_supported() -> bool;
    fn girocrab_grab_window_titled(
        path: *const std::os::raw::c_char,
        title: *const std::os::raw::c_char,
    ) -> bool;
    fn girocrab_copy_secret(text: *const std::os::raw::c_char);
}

/// The vault on screen (demo or personal) – `AppModel.vault`. `None` = locked.
static VAULT: Mutex<Option<Arc<Vault>>> = Mutex::new(None);
/// The unlocked personal vault – `AppModel.ownVault` (stays open while the demo is shown).
static OWN: Mutex<Option<Arc<Vault>>> = Mutex::new(None);

/// `AppModel.vaultURL`: ~/.local/share/GiroCrab/tresor.girocrab (XDG data dir);
/// the keychain bypass uses a separate file, so the real vault is never opened
/// with the throw-away key.
pub fn vault_path() -> std::path::PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".local/share")
        })
        .join("GiroCrab");
    let _ = std::fs::create_dir_all(&base);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o700));
    }
    base.join(if crate::vault_key::keychain_bypassed() {
        "tresor-dev.girocrab"
    } else {
        "tresor.girocrab"
    })
}

fn file_size(p: &std::path::Path) -> i64 {
    std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(-1)
}

/// `AppModel.unlock()` (core part): key from the keyring, open, starter categories.
fn unlock_own(a: &Value) -> R {
    let path = vault_path();
    let allow_create: bool =
        arg::<Option<bool>>(a, "allow_create")?.unwrap_or(false) && file_size(&path) <= 0;
    let u = crate::vault_key::unlock(allow_create)?;
    let v = Vault::open(path.display().to_string(), u.key.to_vec()).map_err(|e| e.to_string())?;
    v.seed_starter_categories().map_err(|e| e.to_string())?;
    let accounts = v.account_count().map_err(|e| e.to_string())?;
    let connections = v.list_bank_connections().map_err(|e| e.to_string())?.len();
    *OWN.lock().unwrap() = Some(v);
    ok(
        json!({ "account_count": accounts, "has_connections": connections > 0, "created_key": u.created }),
    )
}

/// Settings › Sicherheit: restore / adopt a key (rekeys the open vault, then stores it).
fn import_key(a: &Value) -> R {
    let text: String = arg(a, "text")?;
    let key = crate::vault_key::parse_key(&text)?;
    let Some(own) = OWN.lock().unwrap().clone() else {
        return restore_key(&key);
    };
    // Open vault whose key went missing from the keyring meanwhile: without the
    // previous key there is nothing to roll back to, so no rekey – the pasted
    // key must be the one that opens the vault, and is then just stored.
    let Ok(previous) = crate::vault_key::unlock(false) else {
        let _ = own.checkpoint();
        return restore_key(&key);
    };
    own.rekey(key.to_vec()).map_err(|e| e.to_string())?;
    if let Err(e) = crate::vault_key::store(&key) {
        // keep vault and keyring consistent: both on the previous key again
        let _ = own.rekey(previous.key.to_vec());
        return Err(e);
    }
    ok(())
}

/// Locked vault whose key is missing from (or wrong in) the keyring: the key
/// must open the existing vault file before it is stored. Never creates a vault.
fn restore_key(key: &[u8]) -> R {
    let path = vault_path();
    if file_size(&path) <= 0 {
        return Err(crate::i18n::tr(
            "Es gibt noch keinen Tresor, zu dem der Schlüssel passen könnte.",
        ));
    }
    let v = Vault::open(path.display().to_string(), key.to_vec()).map_err(|e| match e {
        girocrab_core::CoreError::WrongKey => {
            crate::i18n::tr("Der Schlüssel passt nicht zu diesem Tresor.")
        }
        e => e.to_string(),
    })?;
    drop(v);
    crate::vault_key::store(key)?;
    ok(())
}

/// Text file chosen in a file dialog (Enable Banking .pem key); at most 1 MB.
fn read_text_file(a: &Value) -> R {
    let path: String = arg(a, "path")?;
    let path = path.strip_prefix("file://").unwrap_or(&path).to_string();
    let size = file_size(std::path::Path::new(&path));
    if !(0..=1_048_576).contains(&size) {
        return Err(crate::i18n::tr("Die Datei ist zu groß oder nicht lesbar."));
    }
    ok(std::fs::read_to_string(&path).map_err(|e| e.to_string())?)
}

/// CSV export of the Abruf-Protokoll (file dialog → path).
fn write_text_file(a: &Value) -> R {
    let path: String = arg(a, "path")?;
    let path = path.strip_prefix("file://").unwrap_or(&path).to_string();
    let text: String = arg(a, "text")?;
    std::fs::write(&path, text).map_err(|e| e.to_string())?;
    ok(())
}

pub fn call_json(method: &str, args: &str) -> String {
    let a: Value = if args.trim().is_empty() {
        Value::Null
    } else {
        match serde_json::from_str(args) {
            Ok(v) => v,
            Err(e) => {
                return json!({ "err": format!("bad arguments for {method}: {e}") }).to_string()
            }
        }
    };
    // A core panic must neither unwind into C++ (Core.call) nor end a worker
    // thread without its `finished` signal (Core.callAsync): it becomes an error.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| call(method, &a)))
        .unwrap_or_else(|p| {
            let what = p
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| p.downcast_ref::<String>().cloned())
                .unwrap_or_default();
            Err(crate::i18n::tr("Interner Fehler in %1: %2")
                .replace("%1", method)
                .replace("%2", &what))
        });
    match result {
        Ok(v) => json!({ "ok": v }).to_string(),
        Err(e) => json!({ "err": e }).to_string(),
    }
}

fn arg<T: DeserializeOwned>(a: &Value, name: &str) -> Result<T, String> {
    serde_json::from_value(a.get(name).cloned().unwrap_or(Value::Null))
        .map_err(|e| format!("argument `{name}`: {e}"))
}

fn ok<T: serde::Serialize>(v: T) -> R {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

fn vault() -> Result<Arc<Vault>, String> {
    VAULT
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| crate::i18n::tr("Tresor ist gesperrt"))
}

fn call(method: &str, a: &Value) -> R {
    match method {
        "core_version" => ok(girocrab_core::core_version()),
        // --- Settings › Allgemein › Sprache (LanguagePreference.swift) ---
        // HelpView.swift › HelpCatalog, read by build.rs: topics (de/en) and shortcut labels.
        "help_content" => {
            serde_json::from_str::<Value>(include_str!(concat!(env!("OUT_DIR"), "/help.json")))
                .map_err(|e| e.to_string())
        }
        "language_state" => ok(json!({
            "choice": crate::i18n::choice(),
            "system": crate::i18n::system_language(),
            "running": crate::i18n::running(),
            "question": crate::i18n::question(),
        })),
        "acknowledge_system_language" => {
            crate::i18n::acknowledge_system_language();
            ok(())
        }
        "set_language_choice" => ok(crate::i18n::set_choice(&arg::<String>(a, "choice")?)?),
        "request_relaunch" => {
            crate::i18n::request_relaunch();
            ok(())
        }
        "fints_builtin_product_id_available" => {
            ok(girocrab_core::fints_builtin_product_id_available())
        }
        "account_color_palette" => ok(girocrab_core::user_groups::account_color_palette()),
        // --- account groups / AccountCopyMenu ---
        "bic_for_iban" => ok(girocrab_core::connectors::fints_directory::bic_for_iban(
            arg(a, "iban")?,
        )),
        "parse_amount_to_cents" => {
            ok(girocrab_core::parse_amount_to_cents(arg(a, "text")?).map_err(|e| e.to_string())?)
        }
        "open_demo" => open_demo(),
        "connector_kind_key" => ok(girocrab_core::banking_gate::connector_kind_key(arg(
            a, "kind",
        )?)),
        "banking_policy_refresh" => ok(crate::banking_policy::refresh(
            arg::<Option<bool>>(a, "force")?.unwrap_or(false),
        )),
        "grab_window" => {
            let path =
                std::ffi::CString::new(arg::<String>(a, "path")?).map_err(|e| e.to_string())?;
            let title = arg::<Option<String>>(a, "title")?.unwrap_or_default();
            if title.is_empty() {
                // SAFETY: called through Core.call on the GUI thread; the path outlives the call.
                return ok(unsafe { girocrab_grab_window(path.as_ptr()) });
            }
            let title = std::ffi::CString::new(title).map_err(|e| e.to_string())?;
            // SAFETY: as above; both strings outlive the call.
            ok(unsafe { girocrab_grab_window_titled(path.as_ptr(), title.as_ptr()) })
        }
        // --- settings / recurring ---
        "copy_secret" => {
            let text =
                std::ffi::CString::new(arg::<String>(a, "text")?).map_err(|e| e.to_string())?;
            // SAFETY: Core.call runs on the GUI thread (QClipboard); the string outlives the call.
            unsafe { girocrab_copy_secret(text.as_ptr()) };
            ok(())
        }
        "read_text_file" => read_text_file(a),
        "write_text_file" => write_text_file(a),
        "check_enable_banking_application" => {
            let v = vault()?;
            let r = crate::sessions::RUNTIME.block_on(v.check_enable_banking_application(
                arg(a, "application_id")?,
                arg(a, "private_key_pem")?,
                arg(a, "redirect_url")?,
            ));
            ok(r.map_err(|e| e.to_string())?)
        }
        "vault_info" => {
            let p = vault_path();
            ok(
                json!({ "path": p.display().to_string(), "size": file_size(&p),
                       "keychain_bypassed": crate::vault_key::keychain_bypassed(),
                       "demo_seed": crate::vault_key::demo_seed_requested() }),
            )
        }
        "unlock_own" => unlock_own(a),
        "use_own" => {
            let own = OWN
                .lock()
                .unwrap()
                .clone()
                .ok_or_else(|| crate::i18n::tr("Der eigene Tresor ist nicht geöffnet."))?;
            *VAULT.lock().unwrap() = Some(own);
            ok(())
        }
        "has_own_vault" => ok(OWN.lock().unwrap().is_some()),
        "export_key" => ok(crate::vault_key::export_base64()?),
        "import_key" => import_key(a),
        "lock" => {
            // endBankDialogsForLock: no bank dialog keeps running or writing into the vault.
            crate::sessions::cancel_all();
            remove_quicklook_files();
            if let Some(v) = OWN.lock().unwrap().take() {
                let _ = v.checkpoint();
            }
            *VAULT.lock().unwrap() = None;
            ok(())
        }
        "is_unlocked" => ok(VAULT.lock().unwrap().is_some()),
        // catalog / directory (free functions of the core)
        "bank_catalog" => ok(girocrab_core::bank_catalog()),
        "fints_presets" => ok(girocrab_core::connectors::fints_presets::fints_presets()),
        "search_banks" => ok(girocrab_core::connectors::bank_directory::search_banks(
            arg(a, "query")?,
            arg::<Option<_>>(a, "live_psd2")?.unwrap_or_default(),
            arg::<Option<u32>>(a, "per_group_limit")?.unwrap_or(12),
        )),
        "lookup_fints_bank_by_blz" => ok(
            girocrab_core::connectors::fints_directory::lookup_fints_bank_by_blz(arg(a, "blz")?),
        ),
        "blz_from_bank_input" => {
            ok(girocrab_core::connectors::fints_directory::blz_from_bank_input(arg(a, "input")?))
        }
        "normalize_phone_number" => {
            ok(girocrab_core::connectors::trade_republic::normalize_phone_number(arg(a, "input")?))
        }
        "is_magic_demo_login" => ok(girocrab_core::demo::is_magic_demo_login(&arg::<String>(
            a, "login",
        )?)),
        // bank dialogs
        "begin_sync" => {
            let v = vault()?;
            let s = v
                .begin_sync(arg(a, "connection_id")?, arg(a, "secret")?, arg(a, "demo")?)
                .map_err(|e| core_error_json(&e))?;
            ok(crate::sessions::register(crate::sessions::Session::Sync(s)))
        }
        "fetch_account_statements" => {
            let v = vault()?;
            let s = v
                .fetch_account_statements(arg(a, "account_id")?, arg(a, "secret")?, arg(a, "demo")?)
                .map_err(|e| core_error_json(&e))?;
            ok(crate::sessions::register(crate::sessions::Session::Sync(s)))
        }
        "begin_transfer" => {
            let v = vault()?;
            let t = v
                .begin_transfer(arg(a, "request")?, arg(a, "secret")?, arg(a, "demo")?)
                .map_err(|e| e.to_string())?;
            ok(crate::sessions::register(
                crate::sessions::Session::Transfer(t),
            ))
        }
        // --- import / export ---
        "preview_moneymoney_file" => {
            let (data, file_name) = read_import_file(a)?;
            let p = vault()?
                .preview_moneymoney_import(data, file_name, arg(a, "target_account_id")?)
                .map_err(|e| core_error_json(&e))?;
            ok(p)
        }
        "import_moneymoney_file" => {
            let (data, file_name) = read_import_file(a)?;
            let r = vault()?
                .import_moneymoney_data(
                    data,
                    file_name,
                    arg(a, "target_account_id")?,
                    arg(a, "preserve_categories")?,
                    arg(a, "preserve_notes")?,
                )
                .map_err(|e| core_error_json(&e))?;
            ok(r)
        }
        "preview_moneymoney_database" => {
            let p = vault()?
                .preview_moneymoney_database(
                    arg(a, "path")?,
                    arg(a, "password")?,
                    arg(a, "statements_dir")?,
                )
                .map_err(|e| core_error_json(&e))?;
            ok(p)
        }
        "import_moneymoney_database" => import_moneymoney_database(a),
        "moneymoney_import_progress" => ok(MM_PROGRESS.lock().unwrap().clone()),
        "cancel_moneymoney_import" => {
            MM_CANCEL.store(true, std::sync::atomic::Ordering::SeqCst);
            ok(())
        }
        "export_bookings_csv_file" => {
            let csv = vault()?
                .export_bookings_csv(arg(a, "filter")?)
                .map_err(|e| e.to_string())?;
            std::fs::write(arg::<String>(a, "path")?, csv).map_err(|e| e.to_string())?;
            ok(())
        }
        "print_pdf" => print_pdf(a),
        "print_web_assets" => print_web_assets(),
        "psd2_catalog" => ok(girocrab_core::connectors::bank_directory::psd2_catalog()),
        // documents: files are read / written here, bytes never travel through JSON
        "attach_file_to_booking" => {
            let path: String = arg(a, "path")?;
            let bytes = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
            let name = file_name_of(&path);
            ok(vault()?
                .attach_document_to_booking(arg(a, "booking_id")?, name, bytes)
                .map_err(|e| e.to_string())?)
        }
        "auto_match_file" => {
            let path: String = arg(a, "path")?;
            let bytes = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
            // photos: OCR text as the hint (Vision on the Mac); before the vault is touched
            let hint = crate::ocr::extract(&bytes);
            ok(vault()?
                .auto_match_document(file_name_of(&path), bytes, hint)
                .map_err(|e| e.to_string())?)
        }
        "document_temp_file" => document_temp_file(arg(a, "doc_id")?, arg(a, "mime_type")?),
        "session_start" | "session_submit" | "session_poll" | "session_confirm_payee" => {
            session_step(method, a)
        }
        // AppModel.cancelTransferSession: for a transfer the bank's answer comes back as
        // `{"outcome": CancelOutcome}`. Anything but `Cancelled` keeps the session
        // registered, so "Status erneut prüfen" can call session_cancel again (the core
        // re-checks the bank before it resends anything).
        "session_cancel" => {
            let id: u64 = arg(a, "session")?;
            let outcome = match crate::sessions::get(id) {
                Ok(s) => crate::sessions::RUNTIME.block_on(async {
                    match s {
                        crate::sessions::Session::Sync(s) => {
                            s.cancel().await;
                            None
                        }
                        crate::sessions::Session::Transfer(t) => Some(t.cancel().await),
                    }
                }),
                Err(_) => None,
            };
            let settled = !matches!(
                outcome,
                Some(ref o) if *o != girocrab_core::connectors::CancelOutcome::Cancelled
            );
            if settled {
                crate::sessions::remove(id);
            }
            ok(json!({ "outcome": outcome }))
        }
        // --- transfer ---
        "validate_iban" => ok(girocrab_core::connectors::validate_iban(arg(a, "iban")?)),
        "girocode_matrix" => girocode_matrix(a),
        "read_invoice" => read_invoice(a),
        // --- portal logins --- (src/web_login.rs: browser cookies, Amex/Amazon/FNZ/quirion imports)
        m if crate::web_login::handles(m) => crate::web_login::call(m, a, vault),
        _ => {
            let v = vault()?;
            dispatch_vault(&v, method, a)
                .unwrap_or_else(|| Err(format!("unknown core method `{method}`")))
        }
    }
}

/// A MoneyMoney export file (`path`) as bytes plus its file name, which the
/// importer uses for the account name.
fn read_import_file(a: &Value) -> Result<(Vec<u8>, String), String> {
    let path: String = arg(a, "path")?;
    let data = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
    let name = std::path::Path::new(&path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    Ok((data, name))
}

/// Progress of the running MoneyMoney database import (`ImportProgressRelay`
/// in Swift): written by the importing worker thread, polled by the view.
static MM_PROGRESS: Mutex<
    Option<girocrab_core::importers::moneymoney_db::MoneyMoneyDbImportProgress>,
> = Mutex::new(None);
/// "Import abbrechen": the next progress callback tells the core to stop.
static MM_CANCEL: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

struct ImportProgressRelay;

impl girocrab_core::importers::moneymoney_db::MoneyMoneyImportObserver for ImportProgressRelay {
    fn progress(
        &self,
        progress: girocrab_core::importers::moneymoney_db::MoneyMoneyDbImportProgress,
    ) -> bool {
        *MM_PROGRESS.lock().unwrap() = Some(progress);
        !MM_CANCEL.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// `importMoneymoneyDatabaseWithProgress` – run through `Core.callAsync`.
fn import_moneymoney_database(a: &Value) -> R {
    let v = vault()?;
    MM_CANCEL.store(false, std::sync::atomic::Ordering::SeqCst);
    *MM_PROGRESS.lock().unwrap() = None;
    let r = v
        .import_moneymoney_database_with_progress(
            arg(a, "path")?,
            arg(a, "password")?,
            arg(a, "options")?,
            Arc::new(ImportProgressRelay),
        )
        .map_err(|e| core_error_json(&e))?;
    ok(r)
}

mod print_assets {
    include!(concat!(env!("OUT_DIR"), "/print_web_assets.rs"));
}

/// Stylesheet and paginator script of the Mac printout (PrintReport.swift, read by
/// build.rs) plus whether a rendered PDF can go to a printer (Qt's PDF image plugin).
fn print_web_assets() -> R {
    // SAFETY: plain query, no arguments.
    let pdf = unsafe { girocrab_print_pdf_supported() };
    Ok(serde_json::json!({
        "css": print_assets::PRINT_CSS,
        "paginator": print_assets::PRINT_PAGINATOR,
        "pdf_supported": pdf,
    }))
}

/// Prints a PDF that WebPrinter.qml rendered from the Mac markup: system print dialog,
/// "In Datei drucken" copies the PDF, a printer gets the pages at its resolution.
/// "printed" / "cancelled". The file is removed afterwards.
fn print_pdf(a: &Value) -> R {
    let path: String = arg(a, "path")?;
    let job = arg::<Option<String>>(a, "job_name")?.unwrap_or_default();
    let (p, j) = (
        std::ffi::CString::new(path.clone()).map_err(|e| e.to_string())?,
        std::ffi::CString::new(job).map_err(|e| e.to_string())?,
    );
    // SAFETY: called through Core.call on the GUI thread; the strings outlive the call.
    let r = unsafe { girocrab_print_pdf(p.as_ptr(), j.as_ptr()) };
    let _ = std::fs::remove_file(&path);
    match r {
        1 => ok("printed"),
        0 => ok("cancelled"),
        _ => Err(crate::i18n::tr(
            "Der Druckauftrag konnte nicht erstellt werden.",
        )),
    }
}

/// One step of a bank dialog; a finished or failed dialog leaves the registry.
fn session_step(method: &str, a: &Value) -> R {
    use crate::sessions::{Session, RUNTIME};
    let id: u64 = arg(a, "session")?;
    let s = crate::sessions::get(id)?;
    let code: Option<String> = arg(a, "code")?;
    let result = RUNTIME.block_on(async {
        match (&s, method) {
            (Session::Sync(s), "session_start") => {
                s.start().await.map(|x| serde_json::to_value(x).unwrap())
            }
            (Session::Sync(s), "session_submit") => s
                .submit_code(code.unwrap_or_default())
                .await
                .map(|x| serde_json::to_value(x).unwrap()),
            (Session::Sync(_), "session_confirm_payee") => {
                Err(girocrab_core::CoreError::SessionClosed)
            }
            (Session::Sync(s), _) => s.poll().await.map(|x| serde_json::to_value(x).unwrap()),
            (Session::Transfer(t), "session_start") => {
                t.start().await.map(|x| serde_json::to_value(x).unwrap())
            }
            (Session::Transfer(t), "session_submit") => t
                .submit_code(code.unwrap_or_default())
                .await
                .map(|x| serde_json::to_value(x).unwrap()),
            (Session::Transfer(t), "session_confirm_payee") => t
                .confirm_payee()
                .await
                .map(|x| serde_json::to_value(x).unwrap()),
            (Session::Transfer(t), _) => t.poll().await.map(|x| serde_json::to_value(x).unwrap()),
        }
    });
    match result {
        Ok(step) => {
            let last = ["Finished", "Done", "InstantDeclined", "OutcomeUnknown"];
            if last.iter().any(|k| step.get(k).is_some()) {
                crate::sessions::remove(id);
            }
            ok(crate::sessions::with_image_url(step))
        }
        Err(e) => {
            crate::sessions::remove(id);
            Err(core_error_json(&e))
        }
    }
}

/// Errors keep their CoreError variant (`{"kind": "Bank", "code": …}`) so the model
/// can react like the Swift app (MissingSetting → setup sheet, BrowserLoginRequired, …).
fn core_error_json(e: &girocrab_core::CoreError) -> String {
    let mut v = serde_json::to_value(format!("{e:?}")).unwrap_or_default();
    if let Value::String(dbg) = &v {
        let kind = dbg
            .split(|c: char| !c.is_alphanumeric())
            .next()
            .unwrap_or("")
            .to_string();
        v = json!({ "kind": kind, "message": e.to_string(), "debug": dbg });
    }
    format!("\u{1}{v}")
}

fn file_name_of(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// QuickLook copy (`AppModel.quickLookURL`): a private, owner-only file in
/// the folder of `prepared_quicklook_dir`. Only the current preview exists:
/// the previous copy goes when another document is shown (and on lock / quit).
fn document_temp_file(doc_id: i64, mime: String) -> R {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let bytes = vault()?
        .get_document_bytes(doc_id)
        .map_err(|e| e.to_string())?;
    let dir = prepared_quicklook_dir().ok_or_else(|| {
        crate::i18n::tr("Der Ordner für die Vorschau ist nicht sicher und wurde nicht verwendet.")
    })?;
    let ext = match mime.as_str() {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/heic" => "heic",
        _ => "pdf",
    };
    let name = format!("GiroCrab-Beleg-{doc_id}.{ext}");
    // one decrypted copy at a time (viewers that still show an old one keep
    // their open file handle)
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            let _ = std::fs::remove_file(e.path());
        }
    }
    let path = dir.join(name);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc_o_nofollow())
        .open(&path)
        .map_err(|e| e.to_string())?;
    f.write_all(&bytes).map_err(|e| e.to_string())?;
    ok(path.display().to_string())
}

const fn libc_o_nofollow() -> i32 {
    0o400000 // O_NOFOLLOW on Linux
}

extern "C" {
    fn getuid() -> u32;
}

fn current_uid() -> u32 {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { getuid() }
}

/// $XDG_RUNTIME_DIR/girocrab-quicklook; without a runtime dir a per-user
/// folder in the temp dir (/tmp/girocrab-quicklook-<uid>).
fn quicklook_dir() -> std::path::PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
    {
        Some(run) => run.join("girocrab-quicklook"),
        None => std::env::temp_dir().join(format!("girocrab-quicklook-{}", current_uid())),
    }
}

/// `AppModel.preparedQuickLookDirectory`: creates the folder owner-only and
/// refuses a symlink or a folder of another user in its place.
fn prepared_quicklook_dir() -> Option<std::path::PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    let dir = quicklook_dir();
    match std::fs::symlink_metadata(&dir) {
        Ok(m) => {
            if !m.file_type().is_dir() || m.uid() != current_uid() {
                return None;
            }
            if m.mode() & 0o077 != 0 {
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).ok()?;
            }
            Some(dir)
        }
        Err(_) => {
            std::fs::DirBuilder::new().mode(0o700).create(&dir).ok()?;
            Some(dir)
        }
    }
}

/// Deletes every decrypted QuickLook copy (lock, quit, next launch). A folder
/// that is not ours (symlink, other user) is left alone.
pub fn remove_quicklook_files() {
    use std::os::unix::fs::MetadataExt;
    let dir = quicklook_dir();
    if let Ok(m) = std::fs::symlink_metadata(&dir) {
        if m.file_type().is_dir() && m.uid() == current_uid() {
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}

/// `AppModel.makeDemoVault`: throw-away vault in the temp dir with fixed key.
fn open_demo() -> R {
    let path = std::env::temp_dir().join("GiroCrab-Demo.girocrab");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    let key: Vec<u8> = (0..32u32).map(|i| ((i * 7 + 3) & 0xFF) as u8).collect();
    let v = Vault::open(path.display().to_string(), key).map_err(|e| e.to_string())?;
    v.seed_demo_data().map_err(|e| e.to_string())?;
    *VAULT.lock().unwrap() = Some(v);
    ok(())
}

/// GiroCode.swift › image(for:): EPC QR code (error correction "M") as module
/// rows ("1" = dark) for a QML Canvas.
fn girocode_matrix(a: &Value) -> R {
    use qrcode::{Color, EcLevel, QrCode};
    let payload: String = arg(a, "payload")?;
    let code = QrCode::with_error_correction_level(payload.as_bytes(), EcLevel::M)
        .map_err(|e| e.to_string())?;
    let w = code.width();
    let rows: Vec<String> = code
        .to_colors()
        .chunks(w)
        .map(|r| {
            r.iter()
                .map(|c| if *c == Color::Dark { '1' } else { '0' })
                .collect()
        })
        .collect();
    ok(json!({ "width": w, "rows": rows }))
}

fn find_bytes(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    hay.get(from..)?
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + from)
}

/// Largest invoice file read at all, and the most one PDF stream may inflate to
/// (a ZUGFeRD XML is a few kB; this stops a zip bomb).
const MAX_INVOICE_FILE: u64 = 32 * 1024 * 1024;
const MAX_INFLATED_STREAM: usize = 8 * 1024 * 1024;

/// XML bytes as text: UTF-8, or ISO-8859-1 when the bytes are not valid UTF-8
/// (XMLParser in Swift honours the declared encoding).
fn xml_text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// PaymentParser.swift › embeddedInvoiceXML: scans PDF streams (inflating
/// Flate ones) for a CrossIndustryInvoice (ZUGFeRD / Factur-X) document.
fn embedded_invoice_xml(pdf: &[u8]) -> Option<String> {
    const MARKER: &[u8] = b"CrossIndustryInvoice";
    let mut cursor = 0;
    while let Some(s) = find_bytes(pdf, b"stream", cursor) {
        let body_start = s + b"stream".len();
        let e = find_bytes(pdf, b"endstream", body_start)?;
        cursor = e + b"endstream".len();
        let mut body = &pdf[body_start..e];
        if body.first() == Some(&0x0D) {
            body = &body[1..];
        }
        if body.first() == Some(&0x0A) {
            body = &body[1..];
        }
        if find_bytes(body, MARKER, 0).is_some() {
            return Some(xml_text(body));
        }
        if body.len() > 8 && body[0] == 0x78 {
            if let Ok(inflated) =
                miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(body, MAX_INFLATED_STREAM)
            {
                if find_bytes(&inflated, MARKER, 0).is_some() {
                    return Some(xml_text(&inflated));
                }
            }
        }
    }
    None
}

/// PaymentParser.parseFile (file part): a dropped invoice as ZUGFeRD XML and,
/// for a PDF, also its text layer (used when the XML is unusable); QML parses
/// the fields. Other files are not read as text (Swift only OCRs images).
fn read_invoice(a: &Value) -> R {
    let path: String = arg(a, "path")?;
    let size = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
    if size > MAX_INVOICE_FILE {
        return Err(crate::i18n::tr("Die Datei ist zu groß."));
    }
    let data = std::fs::read(&path).map_err(|e| e.to_string())?;
    let is_pdf = data.starts_with(b"%PDF");
    let xml = if is_pdf {
        embedded_invoice_xml(&data)
    } else if find_bytes(&data[..data.len().min(4096)], b"CrossIndustryInvoice", 0).is_some() {
        Some(xml_text(&data))
    } else {
        None
    };
    let text = if is_pdf {
        girocrab_core::documents::extract_pdf_text(&data)
    } else if xml.is_none() {
        // a photo of an invoice: OCR text (ReceiptText.extract), when tesseract is there
        crate::ocr::extract(&data).unwrap_or_default()
    } else {
        String::new()
    };
    ok(json!({ "xml": xml, "text": text }))
}

macro_rules! vault_methods {
    ($($name:ident ( $($p:ident),* ))*) => {
        fn dispatch_vault(v: &Vault, method: &str, _a: &Value) -> Option<R> {
            match method {
                $( stringify!($name) => Some((|| -> R {
                    ok(v.$name($(arg(_a, stringify!($p))?),*).map_err(|e| e.to_string())?)
                })()), )*
                _ => None,
            }
        }
    };
}

vault_methods! {
    // vault.rs / demo.rs
    is_empty() account_count() has_account_history() checkpoint()
    // accounts
    list_bank_connections() list_accounts() list_account_groups()
    connection_key(connection_id) add_bank_connection(connector, display_name, login_name)
    add_fints_connection(blz, url, display_name, login_name, tan_medium)
    add_enable_banking_connection(aspsp, country, display_name, login_name)
    delete_bank_connection(connection_id) delete_account(account_id)
    update_bank_connection(connection_id, display_name, login_name)
    set_connection_pin(connection_id, pin) connection_status(connection_id)
    clear_connection_session(connection_id) set_connection_session(connection_id, cookies)
    switch_comdirect_access(connection_id)
    fints_product_id_mode() set_fints_product_id_mode(mode) fints_product_id_source()
    list_holdings(account_id) balance_history(account_ids, days)
    rename_account(account_id, name)
    // --- depot / loans / dashboard ---
    set_account_initial_balance(account_id, cents) investment_dashboard(months)
    // --- loans / opening balance ---
    list_manual_loans() list_loan_links() create_manual_loan(setup)
    update_manual_loan(account_id, setup) preview_manual_loan(account_id, setup, limit)
    set_booking_loan(transaction_id, loan_account_id)
    set_account_opening_balance(account_id, cents, date)
    preview_account_opening_balance(account_id, date)
    // --- documents ---
    list_documents_for_booking(booking_id) list_all_documents(filter)
    link_document(doc_id, booking_id) delete_document(doc_id)
    export_document(doc_id, dest_path) export_all_documents(dest_dir)
    auto_statements_enabled(account_id) set_auto_statements(account_id, enabled)
    // user groups
    list_user_groups()
    // --- sidebar drag & drop ---
    move_account_to_group(account_id, group_uuid, index) set_user_group_parent(uuid, parent_uuid)
    reorder_user_groups(uuids) reorder_accounts_in_group(group_uuid, account_ids)
    // --- account groups ---
    create_user_group(name, sf_symbol) update_user_group(uuid, name, sf_symbol, include_in_total)
    delete_user_group(uuid) merge_user_groups(from_uuid, into_uuid) set_user_group_color(uuid, color_hex)
    set_account_archived(account_id, archived) set_account_color(account_id, color_hex)
    set_account_symbol(account_id, sf_symbol) reset_account_symbol(account_id)
    // categories
    list_categories(date_from, date_to)
    create_category(name, parent_id, sf_symbol, color_hex)
    // bookings
    count_transactions(filter) list_transactions(filter)
    set_transaction_category(transaction_id, category_id)
    set_transaction_checked(transaction_id, checked)
    set_checked_for_ids(ids, checked)
    update_transaction_note(transaction_id, note)
    update_transaction_text(transaction_id, counterparty, purpose)
    set_booking_salary_flag(booking_id, flag) salary_cycle(account_ids)
    mark_booking_recurring(booking_id, interval, custom_dates)
    ignore_recurring(series_key) reset_recurring(series_key)
    booking_date(booking_id)
    // insights / planning / recurring
    merchant_stats(merchant_key) selection_flow(account_ids, date_from, date_to)
    cashflow_by_period(granularity, count)
    list_category_budget_progress(year, month)
    list_recurring(account_ids) recurring_month(account_ids, year, month)
    // settings
    list_settings() get_setting(key) set_setting(key, value)
    // --- categorizer / rules ---
    list_rules() save_rule(rule) delete_rule(rule_id) preview_rule(rule, limit)
    apply_rules(only_uncategorized)
    update_category(id, name, parent_id, sf_symbol, color_hex) delete_category(id)
    set_category_budget(category_id, budget_cents)
    list_transaction_splits(transaction_id) set_transaction_splits(transaction_id, splits)
    // --- import / export ---
    export_bookings_csv(filter)
    // --- transfer ---
    suggest_recipients(query, limit)
    list_transfer_templates() save_transfer_template(template) delete_transfer_template(id)
    // --- settings / recurring ---
    list_ignored_recurring(account_ids)
    list_sync_log(filter) clear_sync_log()
    // --- main window / editing ---
    set_checked_for_filter(filter, checked) recurring_snapshot(account_ids, year, month)
    log_sync(connection_id, source, outcome, message, imported)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tests share the process-wide vault slots.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn call_ok(method: &str, args: Value) -> Value {
        let r: Value = serde_json::from_str(&call_json(method, &args.to_string())).unwrap();
        assert!(r.get("err").is_none(), "{method}: {r}");
        r["ok"].clone()
    }

    /// Own vault lifecycle with the keychain bypass: create, use, lock, reopen,
    /// demo in front of the unlocked own vault.
    #[test]
    fn own_vault_lifecycle() {
        let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("girocrab-test-{}", std::process::id()));
        std::env::set_var("XDG_DATA_HOME", &dir);
        std::env::set_var("GIROCRAB_NO_KEYCHAIN", "1");
        assert_eq!(call_ok("vault_info", json!({}))["size"], json!(-1));
        let r = call_ok("unlock_own", json!({ "allow_create": true }));
        assert_eq!(r["account_count"], json!(0));
        call_ok("use_own", json!({}));
        let cats = call_ok("list_categories", json!({}));
        assert!(cats.as_array().unwrap().len() > 3, "starter categories");
        call_ok("open_demo", json!({}));
        assert!(
            call_ok("account_count", json!({})).as_u64().unwrap() > 0,
            "demo in front"
        );
        assert_eq!(call_ok("has_own_vault", json!({})), json!(true));
        call_ok("lock", json!({}));
        assert_eq!(call_ok("is_unlocked", json!({})), json!(false));
        assert!(call_ok("vault_info", json!({}))["size"].as_i64().unwrap() > 0);
        // reopening an existing file never creates a key
        call_ok("unlock_own", json!({ "allow_create": true }));
        call_ok("use_own", json!({}));
        call_ok("lock", json!({}));
        // Settings › Sicherheit: restoring a key while locked checks it against the file.
        let wrong: Value = serde_json::from_str(&call_json(
            "import_key",
            &json!({ "text": "11".repeat(32) }).to_string(),
        ))
        .unwrap();
        assert!(wrong.get("err").is_some(), "wrong key must be refused");
        call_ok("import_key", json!({ "text": "42".repeat(32) }));
        // settings / recurring calls on the demo vault
        call_ok("open_demo", json!({}));
        assert!(call_ok("fints_product_id_mode", json!({})).is_string());
        assert!(call_ok("list_ignored_recurring", json!({ "account_ids": [] })).is_array());
        let filter =
            json!({ "connection_id": null, "only_errors": false, "search": null, "limit": 0 });
        let before = call_ok("list_sync_log", json!({ "filter": filter }))
            .as_array()
            .unwrap()
            .len();
        call_ok(
            "log_sync",
            json!({ "connection_id": null, "source": "Manual", "outcome": "Error", "message": "Test", "imported": 0 }),
        );
        let after = call_ok("list_sync_log", json!({ "filter": filter }));
        assert_eq!(after.as_array().unwrap().len(), before + 1);
        call_ok("clear_sync_log", json!({}));
        let pem = dir.join("key.pem");
        call_ok(
            "write_text_file",
            json!({ "path": pem.display().to_string(), "text": "-----BEGIN PRIVATE KEY-----" }),
        );
        assert_eq!(
            call_ok(
                "read_text_file",
                json!({ "path": format!("file://{}", pem.display()) })
            ),
            json!("-----BEGIN PRIVATE KEY-----")
        );
        call_ok("lock", json!({}));
        let _ = std::fs::remove_dir_all(dir);
    }

    /// The categorizer / rules / split arms with the JSON the QML sends.
    #[test]
    fn rules_categories_splits_roundtrip() {
        let path =
            std::env::temp_dir().join(format!("girocrab-rules-{}.girocrab", std::process::id()));
        let v = Vault::open(path.display().to_string(), vec![7; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let call = |m: &str, a: Value| {
            dispatch_vault(&v, m, &a)
                .unwrap()
                .unwrap_or_else(|e| panic!("{m}: {e}"))
        };
        let cats = call("list_categories", json!({}));
        let cat = cats
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["depth"] == json!(1))
            .unwrap()
            .clone();
        let rule = json!({ "id": 0, "name": "Test", "category_id": cat["id"], "field": "Any",
            "match_kind": "Keyword", "pattern": "REWE", "case_sensitive": false, "min_amount_cents": null,
            "max_amount_cents": 0, "account_id": null, "priority": 999, "enabled": true, "match_count": 0 });
        let b = call("preview_rule", json!({ "rule": rule, "limit": 200 }))[0].clone();
        let id = call("save_rule", json!({ "rule": rule }));
        call("apply_rules", json!({ "only_uncategorized": false }));
        call("delete_rule", json!({ "rule_id": id }));
        call(
            "set_category_budget",
            json!({ "category_id": cat["id"], "budget_cents": 12000 }),
        );
        call(
            "update_category",
            json!({ "id": cat["id"], "name": "Umbenannt", "parent_id": null,
            "sf_symbol": "tag", "color_hex": "#2563EB" }),
        );
        let amount = b["amount_cents"].as_i64().unwrap();
        call(
            "set_transaction_splits",
            json!({ "transaction_id": b["id"], "splits": [
            { "category_id": cat["id"], "amount_cents": amount - amount / 2, "note": "" },
            { "category_id": null, "amount_cents": amount / 2, "note": "x" }] }),
        );
        assert_eq!(
            call(
                "list_transaction_splits",
                json!({ "transaction_id": b["id"] })
            )
            .as_array()
            .unwrap()
            .len(),
            2
        );
        call("delete_category", json!({ "id": cat["id"] }));
        assert_eq!(
            call_json("parse_amount_to_cents", r#"{"text":"1.234,56"}"#),
            r#"{"ok":123456}"#
        );
        drop(v);
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
    }

    /// MoneyMoney export file → preview → import, CSV export of the result,
    /// and a database that cannot be read reports its error.
    #[test]
    fn moneymoney_file_import_and_csv_export() {
        let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("girocrab-mm-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("Girokonto.csv");
        std::fs::write(
            &file,
            "\"Datum\";\"Wertstellung\";\"Kategorie\";\"Name\";\"Verwendungszweck\";\"Konto\";\"Bank\";\"Betrag\";\"Währung\";\"Notiz\"\n\
             \"15.03.2012\";\"15.03.2012\";\"Haushalt\\Supermarkt\";\"REWE Markt\";\"Einkauf\";\"DE02120300000000202051\";\"BYLADEM1001\";\"-1.234,56\";\"EUR\";\"Wocheneinkauf\"\n\
             \"01.04.2012\";\"01.04.2012\";\"Steuern\";\"Finanzamt\";\"Erstattung\";\"\";\"\";\"2.000,00\";\"EUR\";\"\"\n",
        )
        .unwrap();
        let path = file.display().to_string();
        call_ok("open_demo", json!({}));
        let p = call_ok("preview_moneymoney_file", json!({ "path": path }));
        assert_eq!(p["total_rows"], json!(2));
        assert_eq!(p["new_bookings"], json!(2));
        assert_eq!(p["notes_count"], json!(1));
        let r = call_ok(
            "import_moneymoney_file",
            json!({ "path": path, "target_account_id": null, "preserve_categories": true, "preserve_notes": true }),
        );
        assert_eq!(r["imported"], json!(2));
        assert_eq!(r["account_created"], json!(true));
        let out = dir.join("GiroCrab-Buchungen.csv");
        let filter = json!({ "account_ids": [r["account_id"]], "category_id": null, "include_subcategories": true,
            "uncategorized_only": false, "search": null, "date_from": null, "date_to": null, "limit": 0, "offset": 0,
            "scope": "All", "merchant_key": null, "direction": "All", "checked": null, "whole_days": true });
        call_ok(
            "export_bookings_csv_file",
            json!({ "filter": filter, "path": out.display().to_string() }),
        );
        let csv = std::fs::read_to_string(&out).unwrap();
        assert!(csv.starts_with("\u{FEFF}Datum;Konto;"), "{csv}");
        assert!(csv.contains("Finanzamt") && csv.contains("REWE"), "{csv}");
        // not a MoneyMoney database: an error, not a panic
        let r: Value = serde_json::from_str(&call_json(
            "preview_moneymoney_database",
            &json!({ "path": path, "password": "x", "statements_dir": null }).to_string(),
        ))
        .unwrap();
        assert!(r["err"].is_string(), "{r}");
        assert_eq!(
            call_ok("moneymoney_import_progress", json!({})),
            Value::Null
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    /// The loan editor and Startsaldo sheets with the JSON the QML sends.
    #[test]
    fn loans_and_opening_balance_roundtrip() {
        let path =
            std::env::temp_dir().join(format!("girocrab-loans-{}.girocrab", std::process::id()));
        let v = Vault::open(path.display().to_string(), vec![7; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let call = |m: &str, a: Value| {
            dispatch_vault(&v, m, &a)
                .unwrap()
                .unwrap_or_else(|e| panic!("{m}: {e}"))
        };
        let setup = json!({ "name": "Testkredit", "original_cents": null, "anchor_date": "2026-01-31",
                            "anchor_balance_cents": 500000, "interest_rate_ppm": 49900, "match_expr": "" });
        let preview = call(
            "preview_manual_loan",
            json!({ "account_id": null, "setup": setup, "limit": 5 }),
        );
        assert_eq!(preview["status"]["remaining_cents"], json!(500000));
        let id = call("create_manual_loan", json!({ "setup": setup }));
        let loans = call("list_manual_loans", json!({}));
        assert!(loans
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l["account_id"] == id));
        call(
            "update_manual_loan",
            json!({ "account_id": id, "setup": setup }),
        );
        assert!(call("list_loan_links", json!({})).is_array());

        let accounts = call("list_accounts", json!({}));
        let derived = accounts
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["balance_derived"] == json!(true))
            .unwrap()["id"]
            .clone();
        let p = call(
            "preview_account_opening_balance",
            json!({ "account_id": derived, "date": "" }),
        );
        assert!(p["counted"].as_u64().is_some());
        call(
            "set_account_opening_balance",
            json!({ "account_id": derived, "cents": 1000, "date": "2026-01-01" }),
        );
        call(
            "set_account_opening_balance",
            json!({ "account_id": derived, "cents": null, "date": "" }),
        );
        drop(v);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn transfer_helpers() {
        assert_eq!(
            call_ok(
                "validate_iban",
                json!({ "iban": "DE89 3704 0044 0532 0130 00" })
            ),
            json!(true)
        );
        assert_eq!(
            call_ok("parse_amount_to_cents", json!({ "text": "1.234,56" })),
            json!(123456)
        );
        let m = call_ok(
            "girocode_matrix",
            json!({ "payload": "BCD\n002\n1\nSCT\n\nTest\nDE89370400440532013000\nEUR1.00\n\n\nx" }),
        );
        let w = m["width"].as_u64().unwrap() as usize;
        assert!(w >= 21);
        assert_eq!(m["rows"].as_array().unwrap().len(), w);
        // ZUGFeRD XML in a Flate stream of a PDF
        let xml =
            b"<rsm:CrossIndustryInvoice><ram:IBANID>DE89</ram:IBANID></rsm:CrossIndustryInvoice>";
        let z = miniz_oxide::deflate::compress_to_vec_zlib(xml, 6);
        let mut pdf = b"%PDF-1.7\n1 0 obj\nstream\n".to_vec();
        pdf.extend_from_slice(&z);
        pdf.extend_from_slice(b"\nendstream\n");
        assert!(embedded_invoice_xml(&pdf).unwrap().contains("IBANID"));
    }

    /// Main window calls: recurring snapshot, "Alle als gelesen markieren", BIC lookup.
    #[test]
    fn main_window_calls() {
        let path =
            std::env::temp_dir().join(format!("girocrab-main-{}.girocrab", std::process::id()));
        let v = Vault::open(path.display().to_string(), vec![9; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let call = |m: &str, a: Value| {
            dispatch_vault(&v, m, &a)
                .unwrap()
                .unwrap_or_else(|e| panic!("{m}: {e}"))
        };
        let snap = call(
            "recurring_snapshot",
            json!({ "account_ids": [], "year": 2026, "month": 11 }),
        );
        assert!(snap["series"].is_array() && snap["ignored"].is_array());
        assert!(snap["month"]["items"].is_array());
        let filter = json!({ "account_ids": [], "category_id": null, "include_subcategories": true,
            "uncategorized_only": false, "search": null, "date_from": null, "date_to": null,
            "limit": 0, "offset": 0, "scope": "All", "merchant_key": null, "direction": "All",
            "checked": false, "whole_days": false });
        let ids = call(
            "set_checked_for_filter",
            json!({ "filter": filter, "checked": true }),
        );
        assert!(!ids.as_array().unwrap().is_empty());
        let again = call(
            "set_checked_for_filter",
            json!({ "filter": filter, "checked": true }),
        );
        assert!(again.as_array().unwrap().is_empty());
        assert_eq!(
            call_ok("bic_for_iban", json!({ "iban": "DE89370400440532013000" })),
            json!("COBADEFF")
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn parse_key_accepts_base64_and_hex() {
        assert_eq!(
            crate::vault_key::parse_key(&"ab".repeat(32)).unwrap().len(),
            32
        );
        assert!(crate::vault_key::parse_key("AAAA").is_err());
    }
}

/// Dev helper: `GIROCRAB_FIXTURE_DIR=<dir> cargo test -- --ignored make_dev_vault`
/// writes a seeded `tresor-dev.girocrab` (dev key) for UI tests of the own vault.
#[cfg(test)]
#[test]
#[ignore]
fn make_dev_vault() {
    let dir = std::path::PathBuf::from(
        std::env::var("GIROCRAB_FIXTURE_DIR").expect("GIROCRAB_FIXTURE_DIR"),
    );
    std::fs::create_dir_all(&dir).unwrap();
    let v = Vault::open(
        dir.join("tresor-dev.girocrab").display().to_string(),
        vec![0x42; 32],
    )
    .unwrap();
    v.seed_demo_data().unwrap();
    v.checkpoint().unwrap();
}

/// `GIROCRAB_FIXTURE_DIR=… cargo test -q make_big_dev_vault -- --ignored`
/// writes a large `tresor-dev.girocrab` (dev key) with invented data in the size of
/// a real MoneyMoney archive: 8 accounts, ~7000 bookings, 240 categories. For
/// performance checks of the UI with many accounts, bookings and categories.
#[cfg(test)]
#[test]
#[ignore]
fn make_big_dev_vault() {
    let dir = std::path::PathBuf::from(
        std::env::var("GIROCRAB_FIXTURE_DIR").expect("GIROCRAB_FIXTURE_DIR"),
    );
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("tresor-dev.girocrab");
    let _ = std::fs::remove_file(&path);
    let v = Vault::open(path.display().to_string(), vec![0x42; 32]).unwrap();
    let mains = [
        "Haushalt",
        "Wohnen",
        "Mobilität",
        "Freizeit",
        "Gesundheit",
        "Versicherungen",
        "Steuern",
        "Kinder",
        "Reisen",
        "Einkommen",
        "Sparen",
        "Technik",
    ];
    let names = [
        "REWE Markt",
        "EDEKA",
        "Stadtwerke",
        "Deutsche Bahn",
        "Apotheke",
        "Allianz",
        "Finanzamt",
        "Kita Sonnenschein",
        "Lufthansa",
        "Arbeitgeber GmbH",
        "ETF Sparplan",
        "MediaMarkt",
    ];
    let mut seed: u64 = 7;
    let mut rnd = |m: u64| {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) % m
    };
    for acc in 0..8 {
        let mut csv = String::from(
            "\"Datum\";\"Wertstellung\";\"Kategorie\";\"Name\";\"Verwendungszweck\";\"Konto\";\"Bank\";\"Betrag\";\"Währung\";\"Notiz\"\n",
        );
        for i in 0..875u64 {
            // 875 bookings over 17 years (2009–2026), like a long-used MoneyMoney archive
            let day = 1 + (i * 3 + acc as u64) % 28;
            let month = 1 + (i / 4) % 12;
            let year = 2009 + i / 52;
            let m = rnd(mains.len() as u64) as usize;
            let sub = rnd(20);
            let cents = 100 + rnd(25_000) as i64;
            let amount = if m == 9 { cents * 10 } else { -cents };
            csv.push_str(&format!(
                "\"{day:02}.{month:02}.{year}\";\"{day:02}.{month:02}.{year}\";\"{}\\Unterkategorie {sub:02}\";\"{} {i}\";\"Buchung {i}\";\"DE02120300000000{acc:06}\";\"BYLADEM1001\";\"{},{:02}\";\"EUR\";\"\"\n",
                mains[m], names[m], amount / 100, (amount % 100).abs()
            ));
        }
        let file = dir.join(format!("Konto-{acc}.csv"));
        std::fs::write(&file, csv).unwrap();
        v.import_moneymoney_data(
            std::fs::read(&file).unwrap(),
            format!("Konto-{acc}.csv"),
            None,
            true,
            true,
        )
        .unwrap();
        let _ = std::fs::remove_file(&file);
    }
    v.checkpoint().unwrap();
}
