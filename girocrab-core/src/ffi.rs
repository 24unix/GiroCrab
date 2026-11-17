//! Free functions exported to Swift. Each wrapper forwards to the `pub`
//! function of the same name, which carries the docs and which the Rust front
//! ends (Linux, Windows) call directly. `scripts/lint-ffi-exports.sh` keeps
//! `#[uniffi::export] fn` out of other modules.

use crate::asset_classification::{AssetClassification, ClassificationValues};
use crate::assets::AssetWeightPreset;
use crate::batch_csv::BatchCsvImport;
use crate::connectors::bank_directory::{BankSearchResult, Psd2Bank};
use crate::connectors::fints::bank_keys::Rah10KeyfileInfo;
use crate::connectors::fints_directory::FinTsBankInfo;
use crate::connectors::fints_presets::FinTsPreset;
use crate::export::{ExportCsvBalanceLine, ExportCsvColumns, ExportCsvRow};
use crate::mandates::MandateCsvImport;
use crate::models::{ConnectorKind, Holding};
use crate::{BankDescriptor, CoreError};

#[uniffi::export]
fn core_version() -> String {
    crate::core_version()
}

#[uniffi::export]
fn fints_builtin_product_id_available() -> bool {
    crate::fints_builtin_product_id_available()
}

#[uniffi::export]
fn generate_master_key() -> Vec<u8> {
    crate::generate_master_key()
}

#[uniffi::export]
fn set_language(code: String) {
    crate::i18n::set_language(code)
}

#[uniffi::export]
fn set_banking_block(all: bool, connector_ids: Vec<String>, message: String) {
    crate::banking_gate::set_banking_block(all, connector_ids, message)
}

#[uniffi::export]
fn clear_banking_block() {
    crate::banking_gate::clear_banking_block()
}

#[uniffi::export]
fn connector_kind_key(kind: ConnectorKind) -> String {
    crate::banking_gate::connector_kind_key(kind)
}

#[uniffi::export]
fn is_banking_blocked(key: String) -> bool {
    crate::banking_gate::is_banking_blocked(key)
}

#[uniffi::export]
fn bank_catalog() -> Vec<BankDescriptor> {
    crate::bank_catalog()
}

#[uniffi::export]
fn fints_presets() -> Vec<FinTsPreset> {
    crate::connectors::fints_presets::fints_presets()
}

#[uniffi::export]
fn psd2_catalog() -> Vec<Psd2Bank> {
    crate::connectors::bank_directory::psd2_catalog()
}

#[uniffi::export]
fn search_banks(
    query: String,
    live_psd2: Vec<Psd2Bank>,
    per_group_limit: u32,
) -> Vec<BankSearchResult> {
    crate::connectors::bank_directory::search_banks(query, live_psd2, per_group_limit)
}

#[uniffi::export]
fn match_psd2_bank_by_name(bank_name: String, candidates: Vec<Psd2Bank>) -> Option<Psd2Bank> {
    crate::connectors::bank_directory::match_psd2_bank_by_name(bank_name, candidates)
}

#[uniffi::export]
fn lookup_fints_bank_by_blz(blz: String) -> Option<FinTsBankInfo> {
    crate::connectors::fints_directory::lookup_fints_bank_by_blz(blz)
}

#[uniffi::export]
fn blz_from_bank_input(input: String) -> Option<String> {
    crate::connectors::fints_directory::blz_from_bank_input(input)
}

#[uniffi::export]
fn bic_for_iban(iban: String) -> Option<String> {
    crate::connectors::fints_directory::bic_for_iban(iban)
}

#[uniffi::export]
fn validate_iban(iban: String) -> bool {
    crate::connectors::validate_iban(iban)
}

#[uniffi::export]
fn normalize_phone_number(input: String) -> String {
    crate::connectors::trade_republic::normalize_phone_number(input)
}

#[uniffi::export]
fn inspect_rah10_keyfile(bytes: Vec<u8>, password: String) -> Result<Rah10KeyfileInfo, CoreError> {
    crate::connectors::fints::bank_keys::inspect_rah10_keyfile(bytes, password)
}

#[uniffi::export]
fn portal_schema_dump(json_bodies: Vec<String>, dom_rows_json: String) -> String {
    crate::importers::portal_import::portal_schema_dump(json_bodies, dom_rows_json)
}

#[uniffi::export]
fn parse_amount_to_cents(text: String) -> Result<i64, CoreError> {
    crate::parse_amount_to_cents(text)
}

#[uniffi::export]
fn parse_batch_csv(text: String) -> BatchCsvImport {
    crate::batch_csv::parse_batch_csv(text)
}

#[uniffi::export]
fn parse_mandate_csv(text: String) -> MandateCsvImport {
    crate::mandates::parse_mandate_csv(text)
}

#[uniffi::export]
fn export_csv(
    rows: Vec<ExportCsvRow>,
    columns: ExportCsvColumns,
    balance_lines: Vec<ExportCsvBalanceLine>,
) -> String {
    crate::export::export_csv(rows, columns, balance_lines)
}

#[uniffi::export]
fn sanitize_report_text(text: String, known_terms: Vec<String>) -> String {
    crate::report_sanitizer::sanitize_report_text(text, known_terms)
}

#[uniffi::export]
fn account_color_palette() -> Vec<String> {
    crate::user_groups::account_color_palette()
}

#[uniffi::export]
fn asset_weight_presets() -> Vec<AssetWeightPreset> {
    crate::assets::asset_weight_presets()
}

#[uniffi::export]
fn classify_asset(
    holding: Holding,
    imported: ClassificationValues,
    user: ClassificationValues,
    confirmed_direct_crypto: bool,
) -> AssetClassification {
    crate::asset_classification::classify_asset(holding, imported, user, confirmed_direct_crypto)
}
