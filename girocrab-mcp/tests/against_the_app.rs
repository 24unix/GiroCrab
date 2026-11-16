//! End to end: the adapter against the real socket server of the core, the way
//! the app runs it. Also pins the adapter to the core's wire format (API
//! version, error codes, parameter names), since it does not link the core.

mod common;

use common::{adapter_at, call, text, ShortDir};
use girocrab_core::local_api::server::LocalApiServer;
use girocrab_core::local_api::{ShareScope, API_VERSION};
use girocrab_core::Vault;
use serde_json::{json, Value};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

/// A demo vault sharing its first account, served on a socket in `dir`.
struct App {
    vault: Arc<Vault>,
    server: Arc<LocalApiServer>,
    token: String,
    socket: PathBuf,
    shared_account: i64,
}

fn serve(dir: &ShortDir) -> App {
    let vault = Vault::open(dir.0.join("v.db").to_string_lossy().into(), vec![7u8; 32]).unwrap();
    vault.seed_demo_data().unwrap();
    let shared_account = vault.list_accounts().unwrap()[0].id;
    vault
        .set_local_api_scope(ShareScope {
            enabled: true,
            account_ids: vec![shared_account],
            ..Default::default()
        })
        .unwrap();
    let token = vault.create_local_api_token().unwrap();
    // One level deeper: the server creates its folder itself, with mode 0700.
    let socket = dir.0.join("api").join("s.sock");
    let server = LocalApiServer::start(vault.clone(), socket.to_string_lossy().into()).unwrap();
    App {
        vault,
        server,
        token,
        socket,
        shared_account,
    }
}

#[test]
fn tools_read_what_the_user_shares_and_stop_with_the_app() {
    let dir = ShortDir::new();
    let app = serve(&dir);
    let mut mcp = adapter_at(&app.socket, Ok(app.token.clone()));

    let info = call(&mut mcp, "get_info", json!({}));
    assert_eq!(info["isError"], false);
    assert_eq!(info["structuredContent"]["account_count"], 1);
    let accounts = call(&mut mcp, "list_accounts", json!({}));
    assert_eq!(
        accounts["structuredContent"]["items"][0]["id"],
        app.shared_account
    );
    let page = call(&mut mcp, "list_transactions", json!({ "limit": 3 }));
    let bookings = page["structuredContent"]["transactions"]
        .as_array()
        .unwrap();
    assert_eq!(bookings.len(), 3);
    assert!(
        bookings
            .iter()
            .all(|b| b["account_id"] == app.shared_account),
        "only the shared account"
    );
    let summary = call(
        &mut mcp,
        "get_summary",
        json!({ "date_from": "2025-01-01", "date_to": "2026-12-31" }),
    );
    assert_eq!(summary["isError"], false);
    let wrong = call(&mut mcp, "list_transactions", json!({ "nonsense": 1 }));
    assert_eq!(wrong["isError"], true, "the app checks the arguments");

    app.server.stop();
    let gone = call(&mut mcp, "get_info", json!({}));
    assert_eq!(gone["isError"], true);
    assert!(text(&gone).contains("not reachable"));
}

#[test]
fn the_adapter_speaks_the_cores_protocol() {
    assert_eq!(girocrab_mcp::API_VERSION, API_VERSION);
    let dir = ShortDir::new();
    let app = serve(&dir);
    let mut mcp = adapter_at(&app.socket, Ok(app.token.clone()));

    // Every argument the tools advertise is one the app accepts (it rejects
    // unknown ones), so the schemas cannot drift from the core unnoticed.
    let tools = mcp
        .handle(json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }))
        .unwrap()["result"]["tools"]
        .clone();
    let sample = |name: &str, schema: &Value| -> Value {
        match name {
            "date_from" => json!("2026-01-01"),
            "date_to" => json!("2026-06-30"),
            "direction" => json!("all"),
            "search" => Value::Null, // needs every field shared; checked below
            "cursor" => Value::Null,
            _ => match schema["type"].as_str() {
                Some("integer") => json!(1),
                Some("boolean") => json!(false),
                Some("array") => json!([app.shared_account]),
                other => panic!("no sample for {name}: {other:?}"),
            },
        }
    };
    for tool in tools.as_array().unwrap() {
        let name = tool["name"].as_str().unwrap();
        let mut args = serde_json::Map::new();
        for (field, schema) in tool["inputSchema"]["properties"].as_object().unwrap() {
            let value = sample(field, schema);
            if !value.is_null() {
                args.insert(field.clone(), value);
            }
        }
        let r = call(&mut mcp, name, Value::Object(args));
        assert_eq!(r["isError"], false, "{name}: {}", text(&r));
    }
    let r = call(&mut mcp, "list_transactions", json!({ "search": "x" }));
    assert!(
        text(&r).starts_with("not_shared"),
        "search is known: {}",
        text(&r)
    );

    // The refusals the adapter words for the user carry the core's codes.
    let mut wrong_key = adapter_at(&app.socket, Ok("gcapi_wrong".into()));
    assert!(text(&call(&mut wrong_key, "get_info", json!({}))).contains("did not accept"));
    let scope = app.vault.local_api_scope().unwrap();
    let off = ShareScope {
        enabled: false,
        ..scope.clone()
    };
    app.vault.set_local_api_scope(off).unwrap();
    assert!(text(&call(&mut mcp, "get_info", json!({}))).contains("turned off"));
    app.vault.set_local_api_scope(scope).unwrap();
    let server = app.server.clone();
    drop(app); // the app lets go of the vault: the server answers `locked`
    assert!(text(&call(&mut mcp, "get_info", json!({}))).contains("is locked"));
    server.stop();
}

#[test]
fn the_apps_connection_limit_is_waited_out() {
    let dir = ShortDir::new();
    let app = serve(&dir);
    // Other programs hold every connection the app allows (MAX_CLIENTS = 4 in
    // the core's server.rs).
    let hold = || -> Vec<UnixStream> {
        let held = (0..4)
            .map(|_| UnixStream::connect(&app.socket).unwrap())
            .collect();
        std::thread::sleep(Duration::from_millis(200));
        held
    };
    let held = hold();
    let release = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(400));
        drop(held);
    });
    let mut mcp = adapter_at(&app.socket, Ok(app.token.clone()));
    let info = mcp.request("info", json!({})).unwrap();
    assert_eq!(
        info["account_count"], 1,
        "answered once a connection was free"
    );
    release.join().unwrap();

    // Held for good: the user is told GiroCrab is busy.
    let _held = hold();
    let err = mcp.request("info", json!({})).unwrap_err();
    assert!(err.message.contains("busy"), "{}", err.message);
    app.server.stop();
}

/// `girocrab-mcp --check`, as the app's settings pane runs it.
fn check(socket: &std::path::Path, token: Option<&str>) -> (i32, String) {
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_girocrab-mcp"));
    cmd.arg("--check")
        .env("GIROCRAB_API_SOCKET", socket)
        .env_remove("GIROCRAB_API_TOKEN");
    if let Some(t) = token {
        cmd.env("GIROCRAB_API_TOKEN", t);
    }
    let out = cmd.output().unwrap();
    (
        out.status.code().unwrap(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
}

#[test]
fn check_json_names_the_problem() {
    let dir = ShortDir::new();
    let app = serve(&dir);
    let json_check = |token: &str| -> Value {
        let out = std::process::Command::new(env!("CARGO_BIN_EXE_girocrab-mcp"))
            .args(["--check", "--json"])
            .env("GIROCRAB_API_SOCKET", &app.socket)
            .env("GIROCRAB_API_TOKEN", token)
            .output()
            .unwrap();
        serde_json::from_slice(&out.stdout).unwrap()
    };
    // The names the app's settings pane reads (LocalApiCheck in the app).
    assert_eq!(json_check(&app.token)["problem"], "ok");
    assert_eq!(json_check("gcapi_wrong")["problem"], "key_rejected");
    app.server.stop();
    let gone = json_check(&app.token);
    assert_eq!(gone["problem"], "unreachable");
    assert!(gone["message"].as_str().unwrap().contains("not reachable"));
}

#[test]
fn check_tells_each_case_apart() {
    let dir = ShortDir::new();
    let app = serve(&dir);
    let (code, out) = check(&app.socket, Some(&app.token));
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("shared accounts: 1"), "{out}");
    assert_eq!(check(&app.socket, Some("gcapi_wrong")).0, 5);
    let (code, out) = check(&app.socket, None);
    assert_eq!(code, 4);
    assert!(out.starts_with("GiroCrab is reachable."), "{out}");
    let scope = app.vault.local_api_scope().unwrap();
    app.vault
        .set_local_api_scope(ShareScope {
            enabled: false,
            ..scope
        })
        .unwrap();
    assert_eq!(check(&app.socket, Some(&app.token)).0, 6);
    app.server.stop();
    assert_eq!(check(&app.socket, Some(&app.token)).0, 3);
}
