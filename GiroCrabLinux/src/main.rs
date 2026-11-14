//! GiroCrab for Linux – Qt6/QML front end on the GiroCrab Rust core.
//!
//! The QML views mirror the SwiftUI views of `GiroCrabApp/Sources/GiroCrabUI`
//! file by file (RootView.swift → Main.qml, SidebarView.swift → SidebarView.qml, …).

mod banking_policy;
mod bridge;
mod dispatch;
mod ocr;
mod sessions;
mod vault_key;
mod web_login;

use std::ffi::CString;
use std::os::raw::{c_char, c_int};
use std::os::unix::ffi::OsStrExt;

use cxx_qt_lib::{QQmlApplicationEngine, QQuickStyle, QString, QUrl};

extern "C" {
    fn girocrab_prepare_qt();
    fn girocrab_create_app(argc: c_int, argv: *mut *mut c_char, version: *const c_char);
    fn girocrab_exec_app() -> c_int;
    fn girocrab_destroy_app();
}

fn main() {
    // SAFETY: plain Qt setters, called once before the application object exists.
    unsafe { girocrab_prepare_qt() };
    // Decrypted QuickLook copies a crash or force quit may have left behind.
    dispatch::remove_quicklook_files();
    // QApplication (created in C++, cpp/prepare.cpp): the print dialog needs
    // Qt Widgets. argv stays alive for the whole process, as Qt requires.
    let argv: &mut Vec<*mut c_char> = Box::leak(Box::new(
        // args_os: a non-UTF-8 argument (e.g. a file name) must not panic
        std::env::args_os()
            .filter_map(|a| CString::new(a.as_bytes()).ok())
            .map(CString::into_raw)
            .chain(std::iter::once(std::ptr::null_mut()))
            .collect(),
    ));
    let argc = (argv.len() - 1) as c_int;
    let version = CString::new(env!("CARGO_PKG_VERSION")).unwrap_or_default();
    // SAFETY: argv is leaked (valid for the program's lifetime) and null-terminated.
    unsafe { girocrab_create_app(argc, argv.as_mut_ptr(), version.as_ptr()) };
    // Fusion follows the KDE/Plasma palette. Set after the QApplication exists:
    // the KDE platform theme it loads would otherwise pick org.kde.desktop, whose
    // native ToolButton background draws the label a second time.
    if std::env::var_os("QT_QUICK_CONTROLS_STYLE").is_none() {
        QQuickStyle::set_style(&QString::from("Fusion"));
    }
    let mut engine = QQmlApplicationEngine::new();
    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from("qrc:/qt/qml/GiroCrab/Main.qml"));
    }
    // SAFETY: the application object exists (created above).
    let code = unsafe { girocrab_exec_app() };
    // Normal quit: the decrypted QuickLook copies go too (start-up cleans up after a crash).
    dispatch::remove_quicklook_files();
    drop(engine);
    // SAFETY: the engine is dropped; nothing uses the application any more.
    unsafe { girocrab_destroy_app() };
    std::process::exit(code);
}
