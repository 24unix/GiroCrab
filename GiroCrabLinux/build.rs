use cxx_qt_build::{CxxQtBuilder, QmlFile, QmlModule};

fn main() {
    // BankingPolicy: the bundled policy is trusted for 90 days after the build.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    println!("cargo::rustc-env=GIROCRAB_BUILD_UNIX={now}");
    println!("cargo::rerun-if-changed=../policy/banking-policy.json");
    // QML files live in qml/ but are registered at the root of module
    // `GiroCrab` (qrc:/qt/qml/GiroCrab/Main.qml): the build runs inside qml/,
    // so the implicit directory import of every file *is* the module and the
    // singletons (AppModel, Theme, Fmt, SF) resolve to one instance each.
    let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    std::env::set_current_dir(manifest.join("qml")).expect("qml/ directory");
    let mut files: Vec<_> = std::fs::read_dir(".")
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.file_name()))
        .filter(|n| n.to_string_lossy().ends_with(".qml"))
        .collect();
    files.sort();
    let qml: Vec<QmlFile> = files
        .iter()
        .map(|n| {
            let text = std::fs::read_to_string(n).unwrap_or_default();
            QmlFile::from(n).singleton(text.contains("pragma Singleton"))
        })
        .collect();
    println!("cargo::rerun-if-changed={}", manifest.join("qml").display());
    println!("cargo::rerun-if-changed={}", manifest.join("cpp").display());
    println!(
        "cargo::rerun-if-changed={}",
        manifest.join("qml-optional").display()
    );
    print_web_assets(&manifest);
    CxxQtBuilder::new_qml_module(QmlModule::new("GiroCrab").qml_files(qml))
        .qt_module("Quick")
        .qt_module("QuickControls2")
        .qt_module("Widgets")
        .qt_module("PrintSupport")
        // web logins: QNetworkCookie of the QtWebEngine cookie store (cpp/webcookies.cpp)
        .qt_module("Network")
        .qrc(manifest.join("assets.qrc"))
        .cpp_file(manifest.join("cpp/prepare.cpp"))
        .cpp_file(manifest.join("cpp/printing.cpp"))
        .cpp_file(manifest.join("cpp/webcookies.h"))
        .cpp_file(manifest.join("cpp/webcookies.cpp"))
        .file(manifest.join("src/bridge.rs"))
        .build();
    // Our C++ (printing.cpp, prepare.cpp, …) sits in the static library cxx-qt links after its
    // Qt libraries. With `--as-needed` (Debian arm64) the linker has already dropped a Qt
    // library nothing needed up to that point, e.g. QPrinter / QWidget::winId go missing.
    // Naming the Qt libraries once more after that library keeps them resolvable.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        for lib in [
            "PrintSupport",
            "Widgets",
            "QuickControls2",
            "Quick",
            "Qml",
            "Network",
            "Gui",
            "Core",
        ] {
            println!("cargo::rustc-link-lib=dylib=Qt6{lib}");
        }
    }
}

/// The print stylesheet and paginator script of the Mac app (PrintReport.swift `css` and
/// `paginator`), so the Linux printout (QtWebEngine) never drifts from it. Written to
/// OUT_DIR/print_web_assets.rs; fails the build if the Swift file no longer has that shape.
fn print_web_assets(manifest: &std::path::Path) {
    let swift = manifest.join("../GiroCrabApp/Sources/GiroCrabUI/PrintReport.swift");
    println!("cargo::rerun-if-changed={}", swift.display());
    let text = std::fs::read_to_string(&swift)
        .unwrap_or_else(|e| panic!("{}: {e} (print stylesheet of the Mac app)", swift.display()));
    let block = |start: &str, indent: usize| -> String {
        let from = text
            .find(start)
            .unwrap_or_else(|| panic!("PrintReport.swift: `{start}` not found"));
        let open = text[from..].find("\"\"\"\n").expect("opening \"\"\"") + from + 4;
        let close = text[open..].find("\"\"\"").expect("closing \"\"\"") + open;
        text[open..close]
            .trim_end()
            .lines()
            .map(|l| {
                l.get(indent..)
                    .filter(|_| l.starts_with(&" ".repeat(indent)))
                    .unwrap_or(l.trim_start())
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    let css = block("private static let css = ", 4);
    let script = block("private static func paginator(", 8);
    // The first two lines are `(function(){` and the `var W=…` line with Swift
    // interpolations; QML writes them itself (A4, footer, "Seite {p} von {n}").
    let mut lines = script.lines();
    assert_eq!(
        lines.next(),
        Some("(function(){"),
        "PrintReport.swift: paginator start changed"
    );
    let vars = lines.next().unwrap_or_default();
    assert!(
        vars.starts_with("var W=") && vars.contains("FOOTER=") && vars.contains("PAGEOF="),
        "PrintReport.swift: paginator variables changed: {vars}"
    );
    let body: Vec<&str> = lines.collect();
    assert!(
        !css.contains("\\(") && !body.iter().any(|l| l.contains("\\(")),
        "PrintReport.swift: new Swift interpolation in css/paginator, extend build.rs"
    );
    let out =
        std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("print_web_assets.rs");
    std::fs::write(
        out,
        format!(
            "pub const PRINT_CSS: &str = {css:?};\npub const PRINT_PAGINATOR: &str = {:?};\n",
            body.join("\n")
        ),
    )
    .expect("write print_web_assets.rs");
}
