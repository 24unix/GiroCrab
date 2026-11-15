//! The one QObject QML talks to: `Core` (singleton in module `GiroCrab`).
//!
//! It mirrors the role of the generated UniFFI Swift bindings: every core
//! method is reachable by name with JSON arguments, the result comes back as
//! JSON (`{"ok": …}` or `{"err": "…"}`). `call` runs synchronously (fast
//! queries, like the Swift app's main-thread calls); `callAsync` runs on a
//! worker thread and answers through `finished(ticket, json)` – the
//! counterpart of `AppModel.offMain` in the Swift app.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qml_singleton]
        type Core = super::CoreRust;

        #[qinvokable]
        fn call(self: &Core, method: &QString, args: &QString) -> QString;

        #[qinvokable]
        #[cxx_name = "callAsync"]
        fn call_async(self: Pin<&mut Core>, method: &QString, args: &QString) -> i32;

        #[qsignal]
        fn finished(self: Pin<&mut Core>, ticket: i32, result: QString);
    }

    impl cxx_qt::Threading for Core {}
}

use core::pin::Pin;
use cxx_qt::{CxxQtType, Threading};
use cxx_qt_lib::QString;

#[derive(Default)]
pub struct CoreRust {
    next_ticket: i32,
}

impl qobject::Core {
    fn call(&self, method: &QString, args: &QString) -> QString {
        QString::from(&crate::dispatch::call_json(
            &method.to_string(),
            &args.to_string(),
        ))
    }

    fn call_async(mut self: Pin<&mut Self>, method: &QString, args: &QString) -> i32 {
        let ticket = {
            let mut rust = self.as_mut().rust_mut();
            rust.next_ticket = rust.next_ticket.wrapping_add(1).max(1);
            rust.next_ticket
        };
        let (method, args) = (method.to_string(), args.to_string());
        let thread = self.qt_thread();
        std::thread::spawn(move || {
            let result = crate::dispatch::call_json(&method, &args);
            let _ = thread.queue(move |core| core.finished(ticket, QString::from(&result)));
        });
        ticket
    }
}
