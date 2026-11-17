//! File helpers for data that leaves the vault (backups, exported statements).

use std::io::Write;
use std::path::Path;

/// Creates `path` empty and owner-only (0600 on Unix; the default elsewhere), or
/// truncates it keeping its mode. A backup or exported statement must not be
/// readable by other users just because the process umask is 022.
pub(crate) fn create_private(path: &Path) -> std::io::Result<std::fs::File> {
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(path)
}

/// `std::fs::write` with [`create_private`] permissions.
pub(crate) fn write_private(
    path: impl AsRef<Path>,
    bytes: impl AsRef<[u8]>,
) -> std::io::Result<()> {
    create_private(path.as_ref())?.write_all(bytes.as_ref())
}

#[cfg(all(test, unix))]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn written_files_are_owner_only() {
        let p = std::env::temp_dir().join(format!("girocrab-fsutil-{}", uuid::Uuid::new_v4()));
        super::write_private(&p, b"x").unwrap();
        let mode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        let _ = std::fs::remove_file(&p);
        assert_eq!(mode, 0o600);
    }
}
