use thiserror::Error;

/// Every error that can cross the FFI boundary.
#[derive(Debug, Error, uniffi::Error)]
pub enum CoreError {
    #[error("Datenbankfehler: {message}")]
    Database { message: String },
    #[error(
        "Der Tresor konnte nicht entsperrt werden (falscher Schlüssel oder beschädigte Datei)"
    )]
    WrongKey,
    #[error("Nicht gefunden: {what}")]
    NotFound { what: String },
    #[error("Ungültige Eingabe: {message}")]
    InvalidInput { message: String },
    #[error("Einstellung fehlt: {key}. Bitte in den Einstellungen eintragen.")]
    MissingSetting { key: String },
    #[error("Netzwerkfehler: {message}")]
    Network { message: String },
    #[error("Die Bank hat die Anfrage abgelehnt: {code} {message}")]
    Bank { code: String, message: String },
    #[error("Anmeldung fehlgeschlagen: {message}")]
    Authentication { message: String },
    #[error("Protokollfehler: {message}")]
    Protocol { message: String },
    /// Trade Republic: AWS WAF blocks direct logins – the app must open the
    /// in-app browser login (WKWebView) and hand over the session cookies.
    #[error("Browser-Anmeldung nötig: {message}")]
    BrowserLoginRequired { message: String },
    #[error("Dieser Abruf ist nicht mehr aktiv")]
    SessionClosed,
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        if let rusqlite::Error::SqliteFailure(err, _) = &e {
            if err.code == rusqlite::ErrorCode::NotADatabase {
                return CoreError::WrongKey;
            }
        }
        CoreError::Database {
            message: e.to_string(),
        }
    }
}

impl From<reqwest::Error> for CoreError {
    fn from(e: reqwest::Error) -> Self {
        CoreError::Network {
            message: e.to_string(),
        }
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Protocol {
            message: format!("JSON: {e}"),
        }
    }
}

impl From<regex::Error> for CoreError {
    fn from(e: regex::Error) -> Self {
        CoreError::InvalidInput {
            message: format!("Regular expression: {e}"),
        }
    }
}

pub type CoreResult<T> = Result<T, CoreError>;
