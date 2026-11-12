//! Test-only helpers.
//!
//! [`TempDir`] gives every test its own fresh directory under
//! `$TMPDIR/girocrab-tests/` and removes it (vault file, `-wal`, `-shm`) on
//! drop – also when the test panics. Tests therefore never share or reuse a
//! vault file and no longer leak SQLCipher databases into the temp directory
//! (thousands of leftovers had filled the disk, so parallel `cargo test` runs
//! failed in `Vault::open` with I/O / `PRAGMA key` errors).

use std::path::{Path, PathBuf};

pub(crate) struct TempDir(PathBuf);

impl TempDir {
    pub(crate) fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir()
            .join("girocrab-tests")
            .join(format!("{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("create test temp dir");
        Self(dir)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.0
    }

    /// Path of `name` inside this directory.
    pub(crate) fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

thread_local! {
    static THREAD_DIR: TempDir = TempDir::new("thread");
}

/// Unique path `name-<uuid>` in a directory owned by the current test thread.
/// For helpers that hand out bare paths: libtest runs every test on its own
/// thread, so the directory is removed when the test finishes.
pub(crate) fn thread_temp_path(name: &str) -> PathBuf {
    THREAD_DIR.with(|d| d.join(&format!("{name}-{}", uuid::Uuid::new_v4())))
}

#[cfg(test)]
mod tests {
    use super::TempDir;

    #[test]
    fn temp_dirs_are_unique_and_removed_on_drop() {
        let a = TempDir::new("probe");
        let b = TempDir::new("probe");
        assert_ne!(a.path(), b.path());
        std::fs::write(a.join("v.db-wal"), b"x").unwrap();
        let p = a.path().to_path_buf();
        drop(a);
        assert!(!p.exists());
    }
}
