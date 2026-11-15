# ISO 20022 schemas (test fixtures)

Unmodified message schemas from the ISO 20022 message catalogue
(<https://www.iso20022.org/iso-20022-message-definitions>), used by
the tests in `src/export.rs` (and the app's `BookingExportTests`) to validate the
CAMT.053 export with `xmllint --schema`:

- `camt.053.001.02.xsd` – BankToCustomerStatementV02
- `camt.053.001.08.xsd` – BankToCustomerStatementV08
