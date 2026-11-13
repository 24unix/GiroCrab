# Architecture notes

## Schema & migrations

The vault is a SQLCipher database. Its schema is versioned with
[`rusqlite_migration`](https://crates.io/crates/rusqlite_migration) in
`girocrab-core/src/schema.rs`; `PRAGMA user_version` counts the steps a vault has run.

| Version | Step |
|---------|------|
| 1 | `BASELINE`: the complete schema of a new vault |
| 2–8 | empty – vaults from before #206 carry these numbers, reached through probes |
| 9 | `repair_to_v8`: the old probe-based setup, run once, so every vault ends up identical |
| 10 | opening balances (#212) |
| 11 | `sync_log`: the Abrufprotokoll (#238), local to the device |
| 12+ | future changes |

**Changing the schema**

1. Append a step to `STEPS` (SQL, or a hook for Rust logic such as backfills). Never edit or
   reorder an existing step: vaults in the wild have already run it.
2. Run `cargo run -q -p girocrab-core --example make_fixture_vault`. It writes
   `girocrab-core/tests/fixtures/vault-v{N}.girocrab`; commit it. Never regenerate or edit an
   older fixture – each stands for vaults written by that version.
3. `cargo test -q -p girocrab-core --test schema_fixtures` writes `fixtures/schema-v{N}.sql`
   (normalised `sqlite_master`) on first run. Review and commit it, too. Every fixture vault must
   open and end up with exactly the schema of a fresh vault.

**How a vault opens** (`Vault::migrate`)

1. Key check (`SELECT … FROM sqlite_master`); a wrong key is `CoreError::WrongKey`, which makes
   `Vault::open` try the next `cipher_compatibility` mode.
2. Downgrade guard: `user_version` above this build's `SCHEMA_VERSION` →
   `CoreError::SchemaTooNew`, before anything is written. The file stays untouched. The same
   applies to the peer file in an iCloud snapshot merge. Builds from before #206 have no guard.
3. `foreign_keys` / `journal_mode = WAL` (both no-ops inside a transaction).
4. All pending steps run in **one** transaction, which also sets `user_version`. If a step
   fails, nothing changes.

The snapshot export (`write_snapshot`) stamps `user_version = SCHEMA_VERSION` on the copy.

**Rules of thumb**

- Counts filter `deleted_ms IS NULL`: indexes used by count queries must cover that column.
- Index changes are a migration step, not a probe that runs on every open.
- Data repairs that must run on every open (e.g. `fill_missing_uuids`) are called from
  `Vault::open` directly, not from the schema steps.
