//! FNV-1a 64. Unlike `DefaultHasher` its output is the same on every Rust
//! version and platform, so stored ids (content ids, import keys, statement
//! PDF ids, counter-booking proposals) and the default account colours every
//! device must agree on are built from it. Its output must never change.

const OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const PRIME: u64 = 0x0100_0000_01b3;

/// FNV-1a over several inputs, fed in order.
#[derive(Clone, Copy)]
pub(crate) struct Fnv1a64(u64);

impl Default for Fnv1a64 {
    fn default() -> Self {
        Self(OFFSET_BASIS)
    }
}

impl Fnv1a64 {
    #[must_use]
    pub(crate) fn write(self, bytes: impl AsRef<[u8]>) -> Self {
        Self(
            bytes
                .as_ref()
                .iter()
                .fold(self.0, |h, &b| (h ^ u64::from(b)).wrapping_mul(PRIME)),
        )
    }

    /// `bytes` and a unit separator (0x1f) after them, so `("ab", "c")` and
    /// `("a", "bc")` hash differently.
    #[must_use]
    pub(crate) fn field(self, bytes: impl AsRef<[u8]>) -> Self {
        self.write(bytes).write([0x1f])
    }

    pub(crate) fn finish(self) -> u64 {
        self.0
    }
}

pub(crate) fn fnv1a64(bytes: impl AsRef<[u8]>) -> u64 {
    Fnv1a64::default().write(bytes).finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_reference_values() {
        assert_eq!(fnv1a64(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64("a"), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a64(b"%PDF-1.7"), 0x8259_78d2_e0c1_82af);
        let fields = Fnv1a64::default().field("ab").field("c").finish();
        assert_eq!(fields, fnv1a64("ab\u{1f}c\u{1f}"));
        assert_ne!(fields, Fnv1a64::default().field("a").field("bc").finish());
    }
}
