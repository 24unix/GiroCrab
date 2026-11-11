//! Builds the native SwiftUI app as part of `cargo build`:
//!   1. ./build-xcframework.sh --macos-only   (Rust core + UniFFI Swift package)
//!   2. swift build -c release --product GiroCrabMac
//!   3. wraps the executable into target/GiroCrab.app (ad-hoc signed), with the
//!      UI translations compiled from the String Catalogs (xcstringstool)
//!
//! The launcher binary (src/main.rs) then starts that app.
//!
//! Set GIROCRAB_SKIP_SWIFT=1 to skip (e.g. on Linux CI for core-only work).

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn clean_env(cmd: &mut Command) {
    // Don't leak the outer cargo's build-script environment into the nested
    // cargo/swift builds (it would confuse their target/profile detection).
    let keep = [
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "SHELL",
        "DEVELOPER_DIR",
        "RUSTUP_HOME",
        "CARGO_HOME",
        "RUSTUP_TOOLCHAIN",
        "SDKROOT_OVERRIDE",
    ];
    let saved: Vec<(String, String)> = keep
        .iter()
        .filter_map(|k| env::var(k).ok().map(|v| (k.to_string(), v)))
        .collect();
    cmd.env_clear();
    for (k, v) in saved {
        cmd.env(k, v);
    }
    let home = env::var("HOME").unwrap_or_default();
    let path = env::var("PATH").unwrap_or_default();
    cmd.env(
        "PATH",
        format!("{home}/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:{path}"),
    );
    if let Ok(cargo) = env::var("CARGO") {
        cmd.env("CARGO", cargo);
    }
}

fn run(cmd: &mut Command, what: &str) {
    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("{what}: could not start: {e}"));
    if !status.success() {
        panic!("{what} failed with {status}");
    }
}

fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    for p in [
        "build-xcframework.sh",
        "girocrab-core/src",
        "girocrab-core/Cargo.toml",
        "GiroCrabApp/Sources",
        "GiroCrabApp/Package.swift",
        "GiroCrabApp/Xcode/App/Assets.xcassets",
        "GiroCrabApp/Xcode/App/Localizable.xcstrings",
        "GiroCrabApp/Xcode/App/InfoPlist.xcstrings",
        "uniffi-bindgen",
    ] {
        println!("cargo:rerun-if-changed={}", root.join(p).display());
    }
    println!("cargo:rerun-if-env-changed=GIROCRAB_SKIP_SWIFT");

    let app_dir = root.join("target").join("GiroCrab.app");
    let app_bin = app_dir.join("Contents/MacOS/GiroCrab");
    println!("cargo:rustc-env=GIROCRAB_APP_BIN={}", app_bin.display());

    if env::var("GIROCRAB_SKIP_SWIFT").is_ok()
        || env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos")
    {
        println!("cargo:warning=skipping the SwiftUI app build (GIROCRAB_SKIP_SWIFT or non-macOS target)");
        return;
    }

    // 1. Rust core -> XCFramework + Swift bindings (separate target dir: no lock contention)
    let mut xcf = Command::new("bash");
    xcf.arg(root.join("build-xcframework.sh"))
        .arg("--macos-only")
        .current_dir(&root);
    clean_env(&mut xcf);
    xcf.env("GIROCRAB_TARGET_DIR", root.join("target").join("apple"));
    run(&mut xcf, "build-xcframework.sh --macos-only");

    // 2. SwiftUI app
    let pkg = root.join("GiroCrabApp");
    let mut swift = Command::new("xcrun");
    swift
        .args([
            "swift",
            "build",
            "-c",
            "release",
            "--product",
            "GiroCrabMac",
            "--package-path",
        ])
        .arg(&pkg)
        .current_dir(&pkg);
    clean_env(&mut swift);
    run(&mut swift, "swift build (GiroCrabMac)");
    let built = pkg.join(".build/release/GiroCrabMac");
    assert!(
        built.exists(),
        "swift build did not produce {}",
        built.display()
    );

    // 3. .app bundle (gives the window a proper app identity, Dock icon, menu name)
    make_bundle(&app_dir, &built);
}

fn make_bundle(app_dir: &Path, exe: &Path) {
    let macos = app_dir.join("Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    std::fs::copy(exe, macos.join("GiroCrab")).expect("copy app binary");
    make_icns(app_dir);
    let plist = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GiroCrab</string>
    <key>CFBundleDisplayName</key><string>GiroCrab</string>
    <key>CFBundleIdentifier</key><string>de.girocrab.app</string>
    <key>CFBundleExecutable</key><string>GiroCrab</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSFaceIDUsageDescription</key><string>GiroCrab nutzt Face ID / Touch ID, um Ihren verschlüsselten Tresor zu entsperren.</string>
</dict>
</plist>
"#;
    let plist = plist.replace("__VERSION__", env!("CARGO_PKG_VERSION"));
    std::fs::write(app_dir.join("Contents/Info.plist"), plist).unwrap();
    compile_localizations(app_dir);
    // Ad-hoc signature so Keychain + LocalAuthentication accept the bundle.
    let _ = Command::new("codesign")
        .args(["--force", "--sign", "-"])
        .arg(app_dir)
        .status();
    // Refresh Finder/Dock icon caches for the (re)built bundle.
    let _ = Command::new("touch").arg(app_dir).status();
    let _ = Command::new("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        .arg("-f")
        .arg(app_dir)
        .status();
}

/// String Catalogs -> Contents/Resources/<lang>.lproj/{Localizable,InfoPlist}.strings(dict).
/// The SwiftUI code (GiroCrabUI) looks strings up in Bundle.main, i.e. this bundle.
fn compile_localizations(app_dir: &Path) {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let res = app_dir.join("Contents/Resources");
    let _ = std::fs::create_dir_all(&res);
    // Drop translations of a previous build (a removed language must not linger).
    if let Ok(entries) = std::fs::read_dir(&res) {
        for e in entries.flatten() {
            if e.path().extension().is_some_and(|x| x == "lproj") {
                let _ = std::fs::remove_dir_all(e.path());
            }
        }
    }
    // InfoPlist: only English; German stays the Info.plist value written above.
    for (catalog, langs) in [
        ("Localizable.xcstrings", &[][..]),
        ("InfoPlist.xcstrings", &["en"][..]),
    ] {
        let src = root.join("GiroCrabApp/Xcode/App").join(catalog);
        let mut cmd = Command::new("xcrun");
        cmd.args(["xcstringstool", "compile"])
            .arg(&src)
            .arg("--output-directory")
            .arg(&res);
        for l in langs {
            cmd.args(["--language", l]);
        }
        clean_env(&mut cmd);
        run(&mut cmd, &format!("xcstringstool compile {catalog}"));
    }
}

/// AppIcon.appiconset (generated from icon.jpeg with sips) -> Contents/Resources/AppIcon.icns
fn make_icns(app_dir: &Path) {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let set = root.join("GiroCrabApp/Xcode/App/Assets.xcassets/AppIcon.appiconset");
    if !set.exists() {
        return;
    }
    let iconset = root.join("target").join("AppIcon.iconset");
    let _ = std::fs::create_dir_all(&iconset);
    for base in [16u32, 32, 128, 256, 512] {
        let _ = std::fs::copy(
            set.join(format!("icon-{base}.png")),
            iconset.join(format!("icon_{base}x{base}.png")),
        );
        let _ = std::fs::copy(
            set.join(format!("icon-{}.png", base * 2)),
            iconset.join(format!("icon_{base}x{base}@2x.png")),
        );
    }
    let res = app_dir.join("Contents/Resources");
    let _ = std::fs::create_dir_all(&res);
    let ok = Command::new("iconutil")
        .arg("-c")
        .arg("icns")
        .arg(&iconset)
        .arg("-o")
        .arg(res.join("AppIcon.icns"))
        .status();
    if !matches!(ok, Ok(s) if s.success()) {
        println!("cargo:warning=iconutil failed – app bundle has no icon");
    }
}
