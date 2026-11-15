//! `ReceiptText.extract` (DocumentsUI.swift) for photos: the Mac app reads
//! receipts with Vision OCR (de-DE, en-US); here the optional `tesseract` CLI
//! does it (`tesseract stdin stdout -l deu+eng`). The image goes in through
//! stdin, so the decrypted bytes never touch the disk.
//!
//! tesseract is optional at runtime: without the binary or the German
//! language data there is simply no text hint (logged once), as before.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// Larger images are not read (a phone photo is a few MB).
const MAX_INPUT: usize = 25 * 1024 * 1024;
/// A receipt is far shorter; the rest is cut off.
const MAX_TEXT: usize = 64 * 1024;
const TIMEOUT: Duration = Duration::from_secs(20);

/// Image types tesseract (leptonica) reads; Vision also takes HEIC, which
/// leptonica cannot decode, so HEIC photos get no text here.
pub fn is_ocr_image(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0xD8, 0xFF]) // JPEG
        || bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        || bytes.starts_with(b"GIF87a")
        || bytes.starts_with(b"GIF89a")
        || bytes.starts_with(b"II*\0") // TIFF
        || bytes.starts_with(b"MM\0*")
        || bytes.starts_with(b"BM")
        || (bytes.len() > 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP")
}

/// `-l` argument: German first like Vision's `["de-DE", "en-US"]`; `None`
/// when tesseract or its German data is missing (checked once).
fn languages() -> Option<&'static str> {
    static LANGS: OnceLock<Option<&'static str>> = OnceLock::new();
    *LANGS.get_or_init(|| {
        let out = Command::new("tesseract")
            .arg("--list-langs")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output();
        let langs = match out {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
            _ => {
                eprintln!("ocr: tesseract not found – photos are matched without text");
                return None;
            }
        };
        let has = |l: &str| langs.lines().any(|x| x.trim() == l);
        if !has("deu") {
            eprintln!("ocr: tesseract has no German data (tesseract-ocr-deu) – photos are matched without text");
            return None;
        }
        Some(if has("eng") { "deu+eng" } else { "deu" })
    })
}

/// Text of a photo, one recognized line per line; `None` for anything that is
/// no image, without tesseract, on errors or after the timeout.
pub fn extract(bytes: &[u8]) -> Option<String> {
    if bytes.len() > MAX_INPUT || !is_ocr_image(bytes) {
        return None;
    }
    let langs = languages()?;
    run(bytes, langs)
}

fn run(bytes: &[u8], langs: &str) -> Option<String> {
    let mut child = Command::new("tesseract")
        .args(["stdin", "stdout", "-l", langs])
        // one thread: OCR runs next to the UI, it should not take every core
        .env("OMP_THREAD_LIMIT", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take()?;
    let input = bytes.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&input); // dropped afterwards: EOF for tesseract
    });
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = stdout
            .by_ref()
            .take(MAX_TEXT as u64 * 4)
            .read_to_end(&mut out);
        // drain the rest so tesseract never blocks on a full pipe
        let _ = std::io::copy(&mut stdout, &mut std::io::sink());
        out
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if started.elapsed() < TIMEOUT => {
                std::thread::sleep(Duration::from_millis(50))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                eprintln!(
                    "ocr: tesseract took longer than {} s – skipped",
                    TIMEOUT.as_secs()
                );
                break None;
            }
        }
    };
    let _ = writer.join();
    let out = reader.join().ok()?;
    if !status?.success() {
        return None;
    }
    let text = clean(&String::from_utf8_lossy(&out));
    (!text.is_empty()).then_some(text)
}

/// Like Vision's result: the recognized lines, trimmed, without empty ones
/// (tesseract adds blank lines and a form feed per page), at most `MAX_TEXT`.
fn clean(raw: &str) -> String {
    let mut text = raw
        .lines()
        .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\u{c}'))
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if text.len() > MAX_TEXT {
        let mut cut = MAX_TEXT;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        text.truncate(cut);
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_image_types() {
        assert!(is_ocr_image(b"\x89PNG\r\n\x1a\n...."));
        assert!(is_ocr_image(&[0xFF, 0xD8, 0xFF, 0xE0]));
        assert!(is_ocr_image(b"RIFF\0\0\0\0WEBPVP8 "));
        assert!(!is_ocr_image(b"%PDF-1.7"));
        assert!(!is_ocr_image(b"<xml"));
    }

    #[test]
    fn cleans_tesseract_output() {
        assert_eq!(
            clean("  BioMarkt  \n\n\nSumme 12,34\n\u{c}\n"),
            "BioMarkt\nSumme 12,34"
        );
    }

    /// A rendered receipt (tests/receipt.png) read with the installed
    /// tesseract; skipped where tesseract or its German data is missing.
    #[test]
    fn reads_receipt_photo() {
        if languages().is_none() {
            eprintln!("tesseract (deu) missing – test skipped");
            return;
        }
        let png = include_bytes!("../tests/receipt.png");
        let text = extract(png).expect("text");
        assert!(text.contains("BioMarkt"), "{text}");
        assert!(text.contains("47,85"), "{text}");
    }
}
