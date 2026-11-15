//! Local socket for the read-only interface (#136): a Unix domain socket, no
//! network port. One JSON request per line, one JSON response per line.
//!
//! - The socket lives in a directory only the user can enter (0700), the socket
//!   itself is 0600, and a client running as another user is closed at once.
//! - Every request carries the access token (`"token": "gcapi_…"`); only its
//!   hash is stored in the vault, and the scope is read on every request.
//! - The server holds the vault weakly: once the app drops it (locked, swapped),
//!   requests answer `locked`. The app also stops the server when it locks.
//! - Bounded: at most `MAX_CLIENTS` connections, `MAX_LINE` bytes per request,
//!   idle connections close after `IDLE`.

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread::JoinHandle;
use std::time::Duration;

use super::{response, ApiError, ApiErrorCode};
use crate::error::CoreError;
use crate::vault::Vault;

const MAX_CLIENTS: usize = 4;
const MAX_LINE: usize = 64 * 1024;
const IDLE: Duration = Duration::from_secs(300);
/// How often blocked accepts and reads look at the stop flag.
const TICK: Duration = Duration::from_millis(100);

/// The running socket; `stop()` (or dropping it) closes it and removes the file.
#[derive(uniffi::Object)]
pub struct LocalApiServer {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export]
impl LocalApiServer {
    /// Listens on `socket_path` (its directory is created with mode 0700). A
    /// stale socket there is replaced, any other file is an error.
    #[uniffi::constructor]
    pub fn start(vault: Arc<Vault>, socket_path: String) -> Result<Arc<Self>, CoreError> {
        let path = PathBuf::from(&socket_path);
        let listener = bind(&path)?;
        let stop = Arc::new(AtomicBool::new(false));
        let vault = Arc::downgrade(&vault);
        let thread = {
            let stop = stop.clone();
            std::thread::Builder::new()
                .name("girocrab-local-api".into())
                .spawn(move || accept_loop(listener, vault, stop))
                .map_err(io_error)?
        };
        Ok(Arc::new(Self {
            path,
            stop,
            thread: Mutex::new(Some(thread)),
        }))
    }

    /// Closes the socket and removes its file; open connections end within `TICK`.
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.lock().ok().and_then(|mut t| t.take()) {
            let _ = t.join();
        }
        remove_socket(&self.path);
    }

    pub fn socket_path(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }
}

impl Drop for LocalApiServer {
    fn drop(&mut self) {
        self.stop();
    }
}

fn io_error(e: std::io::Error) -> CoreError {
    CoreError::Database {
        message: format!("local socket: {e}"),
    }
}

fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}

/// Creates the private directory and binds the socket (mode 0600).
fn bind(path: &Path) -> Result<UnixListener, CoreError> {
    let dir = path
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .ok_or_else(|| invalid("socket path needs a directory"))?;
    std::fs::create_dir_all(dir).map_err(io_error)?;
    let meta = std::fs::symlink_metadata(dir).map_err(io_error)?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !meta.is_dir() || meta.uid() != uid {
        return Err(invalid("socket directory is not a directory of this user"));
    }
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).map_err(io_error)?;
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_socket() => std::fs::remove_file(path).map_err(io_error)?,
        Ok(_) => return Err(invalid("socket path exists and is not a socket")),
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(io_error(e)),
    }
    let listener = UnixListener::bind(path).map_err(io_error)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(io_error)?;
    listener.set_nonblocking(true).map_err(io_error)?;
    Ok(listener)
}

fn remove_socket(path: &Path) {
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_socket()) {
        let _ = std::fs::remove_file(path);
    }
}

fn accept_loop(listener: UnixListener, vault: Weak<Vault>, stop: Arc<AtomicBool>) {
    let clients = Arc::new(AtomicUsize::new(0));
    let mut workers: Vec<JoinHandle<()>> = Vec::new();
    while !stop.load(Ordering::SeqCst) {
        workers.retain(|w| !w.is_finished());
        match listener.accept() {
            Ok((mut stream, _)) => {
                // BSD hands the listener's O_NONBLOCK on to the accepted socket.
                if stream.set_nonblocking(false).is_err() || !same_user(&stream) {
                    continue;
                }
                if clients.load(Ordering::SeqCst) >= MAX_CLIENTS {
                    let busy = ApiError::new(ApiErrorCode::Internal, "too many connections");
                    let _ = writeln!(stream, "{}", response(Err(busy)));
                    continue;
                }
                clients.fetch_add(1, Ordering::SeqCst);
                let (vault, stop, counter) = (vault.clone(), stop.clone(), clients.clone());
                let worker = std::thread::Builder::new()
                    .name("girocrab-local-api-client".into())
                    .spawn(move || {
                        serve(stream, &vault, &stop);
                        counter.fetch_sub(1, Ordering::SeqCst);
                    });
                match worker {
                    Ok(w) => workers.push(w),
                    Err(_) => {
                        clients.fetch_sub(1, Ordering::SeqCst);
                    }
                }
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => std::thread::sleep(TICK),
            Err(_) => std::thread::sleep(TICK),
        }
    }
    for w in workers {
        let _ = w.join();
    }
}

/// The peer runs as this user (the socket's mode already keeps others out).
fn same_user(stream: &UnixStream) -> bool {
    use std::os::unix::io::AsRawFd;
    let fd = stream.as_raw_fd();
    // SAFETY: getuid has no preconditions.
    let me = unsafe { libc::getuid() };
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    {
        let (mut uid, mut gid): (libc::uid_t, libc::gid_t) = (0, 0);
        // SAFETY: fd is a connected Unix socket owned by `stream`; uid/gid are valid out pointers.
        let ok = unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } == 0;
        ok && uid == me
    }
    #[cfg(target_os = "linux")]
    {
        let mut cred = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: fd is a connected Unix socket; `cred`/`len` describe a valid buffer.
        let ok = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut cred as *mut libc::ucred as *mut libc::c_void,
                &mut len,
            )
        } == 0;
        ok && cred.uid == me
    }
    #[cfg(not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "freebsd",
        target_os = "linux"
    )))]
    {
        let _ = (fd, me);
        false
    }
}

/// Answers the requests of one connection until EOF, an error, a request over
/// `MAX_LINE`, `IDLE` without data or `stop`.
fn serve(stream: UnixStream, vault: &Weak<Vault>, stop: &AtomicBool) {
    if stream.set_read_timeout(Some(TICK)).is_err() {
        return;
    }
    let Ok(mut out) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(stream);
    let mut line: Vec<u8> = Vec::new();
    let mut idle = Duration::ZERO;
    while !stop.load(Ordering::SeqCst) {
        let (used, complete) = match reader.fill_buf() {
            Ok([]) => return,
            Ok(chunk) => match chunk.iter().position(|b| *b == b'\n') {
                Some(i) => {
                    line.extend_from_slice(&chunk[..i]);
                    (i + 1, true)
                }
                None => {
                    line.extend_from_slice(chunk);
                    (chunk.len(), false)
                }
            },
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                idle += TICK;
                if idle >= IDLE {
                    return;
                }
                continue;
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        reader.consume(used);
        idle = Duration::ZERO;
        if line.len() > MAX_LINE {
            let big = ApiError::new(ApiErrorCode::InvalidParams, "request too large");
            let _ = writeln!(out, "{}", response(Err(big)));
            return;
        }
        if !complete {
            continue;
        }
        let answer = answer(vault, &line);
        line.clear();
        if writeln!(out, "{answer}").is_err() {
            return;
        }
    }
}

fn answer(vault: &Weak<Vault>, line: &[u8]) -> String {
    // The vault is held only for this one request.
    let Some(vault) = vault.upgrade() else {
        return response(Err(ApiError::new(
            ApiErrorCode::Locked,
            "GiroCrab is locked",
        )));
    };
    match std::str::from_utf8(line) {
        Ok(text) => vault.local_api_socket_request(text.trim_end_matches('\r')),
        Err(_) => response(Err(ApiError::invalid("request is not UTF-8"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_api::ShareScope;
    use serde_json::{json, Value};
    use std::io::{BufRead, BufReader, Write};

    /// A short directory: `sun_path` holds only 104 bytes on macOS, the usual
    /// temp directory is too deep for it.
    struct ShortDir(PathBuf);

    impl ShortDir {
        fn new() -> Self {
            let id = uuid::Uuid::new_v4().simple().to_string();
            Self(PathBuf::from(format!("/tmp/gc-{}", &id[..12])))
        }
        fn socket(&self) -> PathBuf {
            self.0.join("api").join("s.sock")
        }
    }

    impl Drop for ShortDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn vault() -> (crate::test_support::TempDir, Arc<Vault>, String) {
        let dir = crate::test_support::TempDir::new("local-api-socket");
        let v = Vault::open(
            dir.join("v.db").to_string_lossy().to_string(),
            vec![6u8; 32],
        )
        .unwrap();
        v.seed_demo_data().unwrap();
        let ids = v.list_accounts().unwrap().iter().map(|a| a.id).collect();
        v.set_local_api_scope(ShareScope {
            enabled: true,
            account_ids: ids,
            ..Default::default()
        })
        .unwrap();
        let token = v.create_local_api_token().unwrap();
        (dir, v, token)
    }

    struct Client {
        reader: BufReader<UnixStream>,
        writer: UnixStream,
    }

    impl Client {
        fn connect(path: &Path) -> Self {
            let s = UnixStream::connect(path).unwrap();
            s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            Self {
                writer: s.try_clone().unwrap(),
                reader: BufReader::new(s),
            }
        }
        fn send_raw(&mut self, line: &str) -> Value {
            writeln!(self.writer, "{line}").unwrap();
            let mut resp = String::new();
            self.reader.read_line(&mut resp).unwrap();
            serde_json::from_str(&resp).unwrap()
        }
        fn call(&mut self, token: &str, method: &str) -> Value {
            self.send_raw(&json!({ "v": 1, "token": token, "method": method }).to_string())
        }
    }

    #[test]
    fn answers_with_the_token_and_refuses_without() {
        let d = ShortDir::new();
        let (_v, vault, token) = vault();
        let server =
            LocalApiServer::start(vault.clone(), d.socket().to_string_lossy().into()).unwrap();
        let mut c = Client::connect(&d.socket());
        let info = c.call(&token, "info");
        assert_eq!(info["result"]["api_version"], 1, "{info}");
        // several requests on one connection
        assert!(c.call(&token, "accounts")["result"].is_array());
        assert_eq!(
            c.call("gcapi_wrong", "info")["error"]["code"],
            "unauthorized"
        );
        assert_eq!(
            c.send_raw(r#"{"method":"info"}"#)["error"]["code"],
            "unauthorized"
        );
        // revoked: the old token stops working at once
        vault.revoke_local_api_token().unwrap();
        assert_eq!(c.call(&token, "info")["error"]["code"], "unauthorized");
        let token = vault.create_local_api_token().unwrap();
        assert!(c.call(&token, "info")["result"].is_object());
        // saving the scope keeps the token
        let scope = vault.local_api_scope().unwrap();
        vault
            .set_local_api_scope(ShareScope {
                token_sha256: String::new(),
                ..scope
            })
            .unwrap();
        assert!(c.call(&token, "info")["result"].is_object());
        server.stop();
    }

    #[test]
    fn socket_is_private_and_removed_on_stop() {
        let d = ShortDir::new();
        let (_v, vault, _) = vault();
        let path = d.socket();
        let server = LocalApiServer::start(vault, path.to_string_lossy().into()).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(path.parent().unwrap()), 0o700);
        server.stop();
        assert!(!path.exists());
        assert!(UnixStream::connect(&path).is_err());
    }

    #[test]
    fn never_replaces_another_file() {
        let d = ShortDir::new();
        let (_v, vault, _) = vault();
        let path = d.socket();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"keep me").unwrap();
        assert!(LocalApiServer::start(vault, path.to_string_lossy().into()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"keep me");
    }

    #[test]
    fn a_dropped_vault_reads_as_locked() {
        let d = ShortDir::new();
        let (_v, vault, token) = vault();
        let server =
            LocalApiServer::start(vault.clone(), d.socket().to_string_lossy().into()).unwrap();
        let mut c = Client::connect(&d.socket());
        assert!(c.call(&token, "info")["result"].is_object());
        drop(vault);
        assert_eq!(c.call(&token, "info")["error"]["code"], "locked");
        server.stop();
    }

    #[test]
    fn oversized_and_malformed_requests_are_answered_and_bounded() {
        let d = ShortDir::new();
        let (_v, vault, token) = vault();
        // The server holds the vault weakly: the test keeps it open.
        let server =
            LocalApiServer::start(vault.clone(), d.socket().to_string_lossy().into()).unwrap();
        let mut c = Client::connect(&d.socket());
        assert_eq!(c.send_raw("not json")["error"]["code"], "invalid_params");
        assert!(c.call(&token, "info")["result"].is_object());
        let big = format!(
            r#"{{"method":"info","pad":"{}"}}"#,
            "x".repeat(MAX_LINE + 10)
        );
        assert_eq!(c.send_raw(&big)["error"]["code"], "invalid_params");
        let mut rest = String::new();
        assert_eq!(c.reader.read_line(&mut rest).unwrap_or(0), 0, "closed");
        server.stop();
    }
}
