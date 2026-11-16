//! Merchant logos for the booking list and inspector. The domain mapping, the provider chain
//! (selected favicon provider, default-globe rejection), the encrypted vault cache and the
//! "online logos: off" privacy switch all live in `girocrab-core` (`get_merchant_logo_png`,
//! `fetch_merchant_logo`) and are shared with the macOS app; this module only runs them off the
//! UI thread and decodes the bytes. Nothing is fetched while the provider is "off".

use std::sync::Arc;

use girocrab_core::Vault;
use slint::{Rgba8Pixel, SharedPixelBuffer};

/// Longest edge kept in memory; the list draws 34 px, the inspector 38 px (2x for HiDPI).
const MAX_EDGE: u32 = 96;
/// Logos requested per load; the rest follows with the next reload.
pub const MAX_PER_LOAD: usize = 150;
/// Network results are shown in batches so the list is not redrawn once per logo.
const BATCH: usize = 8;

pub type Decoded = (String, SharedPixelBuffer<Rgba8Pixel>);

/// Cache key of a candidate list ("enbw.de|enbw.com").
pub fn key(candidates: &[String]) -> String {
    candidates.join("|")
}

/// PNG / ICO / JPEG bytes -> a small RGBA bitmap that may cross threads.
pub fn decode(bytes: &[u8]) -> Option<SharedPixelBuffer<Rgba8Pixel>> {
    let img = image::load_from_memory(bytes).ok()?;
    let img = if img.width().max(img.height()) > MAX_EDGE {
        img.thumbnail(MAX_EDGE, MAX_EDGE)
    } else {
        img
    };
    let rgba = img.to_rgba8();
    Some(SharedPixelBuffer::clone_from_slice(
        rgba.as_raw(),
        rgba.width(),
        rgba.height(),
    ))
}

/// Loads the logos of `wanted` (candidate lists): first everything already in the vault cache
/// (one batch), then the missing ones from the network. `deliver` is called on the worker
/// thread with finished batches; the caller hops to the UI thread.
pub fn load(
    vault: Arc<Vault>,
    wanted: Vec<Vec<String>>,
    deliver: impl Fn(Vec<Decoded>) + Send + 'static,
) {
    std::thread::spawn(move || {
        let mut missing: Vec<Vec<String>> = Vec::new();
        let mut cached: Vec<Decoded> = Vec::new();
        for cands in wanted {
            let hit = cands.iter().find_map(|d| {
                vault
                    .get_merchant_logo_png(d.clone())
                    .ok()
                    .flatten()
                    .and_then(|b| decode(&b))
            });
            match hit {
                Some(img) => cached.push((key(&cands), img)),
                None => missing.push(cands),
            }
        }
        if !cached.is_empty() {
            deliver(cached);
        }
        if missing.is_empty() {
            return;
        }
        // "Aus" (the default) answers None at once without a request.
        if !vault.online_logos_enabled().unwrap_or(false) {
            return;
        }
        let Ok(rt) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        else {
            return;
        };
        let mut batch: Vec<Decoded> = Vec::new();
        for cands in missing {
            let found = rt
                .block_on(vault.fetch_merchant_logo(cands.clone()))
                .ok()
                .flatten()
                .and_then(|l| decode(&l.bytes));
            if let Some(img) = found {
                batch.push((key(&cands), img));
                if batch.len() >= BATCH {
                    deliver(std::mem::take(&mut batch));
                }
            }
        }
        if !batch.is_empty() {
            deliver(batch);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(w: u32, h: u32) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(w, h, image::Rgba([10, 20, 30, 255]));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn keys_join_candidates() {
        assert_eq!(
            key(&["enbw.de".into(), "enbw.com".into()]),
            "enbw.de|enbw.com"
        );
    }

    #[test]
    fn decodes_and_shrinks_large_logos() {
        let small = decode(&png(32, 32)).unwrap();
        assert_eq!((small.width(), small.height()), (32, 32));
        let big = decode(&png(256, 128)).unwrap();
        assert_eq!(big.width(), MAX_EDGE);
        assert!(decode(b"not an image").is_none());
    }
}
