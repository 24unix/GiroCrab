//! Bank catalog (`BankDescriptor` per `ConnectorKind`) and connector construction.

use crate::i18n::tr;
use crate::models::ConnectorKind;

use super::*;

/// The supported institutions with their public protocol facts.
#[uniffi::export]
pub fn bank_catalog() -> Vec<BankDescriptor> {
    ConnectorKind::all().into_iter().map(descriptor).collect()
}

pub fn descriptor(kind: ConnectorKind) -> BankDescriptor {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    match kind {
        ConnectorKind::VolksbankKasselGoettingen => BankDescriptor {
            kind,
            name: "Volksbank Kassel Göttingen".into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: "52090000".into(),
            sf_symbol: "building.columns.fill".into(),
            login_label: tr("VR-NetKey oder Alias").into(),
            secret_label: tr("Online-Banking-PIN").into(),
            required_settings: s(&["fints.product_id", "fints.url.52090000"]),
            note: tr("Freigabe in der SecureGo-plus-App (Decoupled, TAN-Prozess 4, HKTAN v7). Server: fints1.atruvia.de").into(),
        },
        ConnectorKind::Direkt1822 => BankDescriptor {
            kind,
            name: "1822direkt".into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: "50050201".into(),
            sf_symbol: "building.columns".into(),
            login_label: tr("Anmeldename / Kontonummer").into(),
            secret_label: tr("Online-Banking-PIN").into(),
            required_settings: s(&["fints.product_id", "fints.url.50050201"]),
            note: tr("pushTAN-App (Decoupled) oder chipTAN. Server: banking-hs5.s-fints-pt-hs.de").into(),
        },
        ConnectorKind::FinTsGeneric => BankDescriptor {
            kind,
            name: tr("FinTS-Bank").into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: String::new(),
            sf_symbol: "building.columns".into(),
            login_label: tr("Anmeldename / VR-NetKey / Kontonummer").into(),
            secret_label: tr("Online-Banking-PIN").into(),
            required_settings: s(&["fints.product_id"]),
            note: tr("Beliebige FinTS-3.0-Bank (PIN/TAN). BLZ und FinTS-URL stehen im Bankzugang.").into(),
        },
        ConnectorKind::Comdirect => BankDescriptor {
            kind,
            name: "comdirect".into(),
            protocol: tr("comdirect REST-API (OAuth2 + Session-TAN)").into(),
            bank_code: "20041111".into(),
            sf_symbol: "building.2".into(),
            login_label: tr("Zugangsnummer").into(),
            secret_label: "PIN".into(),
            required_settings: s(&["comdirect.client_id", "comdirect.client_secret"]),
            note: tr("Session-TAN per photoTAN-Push, photoTAN-Grafik oder mobileTAN.").into(),
        },
        ConnectorKind::PayPal => BankDescriptor {
            kind,
            name: "PayPal".into(),
            protocol: tr("PayPal Transaction Search REST-API").into(),
            bank_code: String::new(),
            sf_symbol: "p.circle".into(),
            login_label: tr("E-Mail (nur Anzeige)").into(),
            secret_label: tr("(nicht nötig – nutzt Ihre REST-App)").into(),
            required_settings: s(&["paypal.client_id", "paypal.client_secret"]),
            note: tr("OAuth2 Client Credentials; Historie in 31-Tage-Fenstern.").into(),
        },
        ConnectorKind::TradeRepublic => BankDescriptor {
            kind,
            name: "Trade Republic".into(),
            protocol: tr("WebSocket-API + 2FA").into(),
            bank_code: String::new(),
            sf_symbol: "chart.line.uptrend.xyaxis.circle".into(),
            login_label: tr("Telefonnummer (+49…)").into(),
            secret_label: tr("4-stellige App-PIN").into(),
            required_settings: vec![],
            note: tr("Web-Login mit 4-stelligem Code aus der App/SMS. Inoffizielle Schnittstelle – kann sich jederzeit ändern.").into(),
        },
        ConnectorKind::AmericanExpress => BankDescriptor {
            kind,
            name: "American Express".into(),
            protocol: tr("Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug").into(),
            bank_code: String::new(),
            sf_symbol: "creditcard.fill".into(),
            login_label: tr("Kartenbezeichnung").into(),
            secret_label: tr("(Anmeldung im Browser-Fenster)").into(),
            required_settings: vec![],
            note: tr("Anmeldung im eingebetteten Browser (Benutzername, Passwort, 2FA wie gewohnt) – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“.").into(),
        },
        ConnectorKind::AmazonVisa => BankDescriptor {
            kind,
            name: "Amazon Visa".into(),
            protocol: tr("Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug").into(),
            bank_code: String::new(),
            sf_symbol: "creditcard".into(),
            login_label: tr("Kartenbezeichnung").into(),
            secret_label: tr("(Anmeldung im Browser-Fenster)").into(),
            required_settings: vec![],
            note: tr("Herausgeber: Open Bank S.A. (Zinia). Anmeldung im eingebetteten Browser – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“.").into(),
        },
        ConnectorKind::Fnz => BankDescriptor {
            kind,
            name: "FNZ Bank".into(),
            protocol: tr("Direkt-Login (Web-Session)").into(),
            bank_code: "70013000".into(),
            sf_symbol: "building.columns".into(),
            login_label: tr("Zugangsbezeichnung").into(),
            secret_label: tr("(Anmeldung im Browser-Fenster)").into(),
            required_settings: vec![],
            note: tr("FNZ Bank / ebase / finvesto: Kontosalden, Depotwerte und PDF-Postkorb einschließlich Archiv. Anmeldung im Browserfenster mit FNZsecure-Freigabe. Die PIN wird nicht gespeichert.").into(),
        },
        ConnectorKind::AmazonOrders => BankDescriptor {
            kind,
            name: "Amazon Bestellungen".into(),
            protocol: tr("Direkt-Login (Web-Session)").into(),
            bank_code: String::new(),
            sf_symbol: "shippingbox.fill".into(),
            login_label: tr("Kontobezeichnung").into(),
            secret_label: tr("(Anmeldung im Browser-Fenster)").into(),
            required_settings: vec![],
            note: tr("Liest Ihre Bestellungen aus dem Amazon-Kundenkonto (amazon.de). Anmeldung im eingebetteten Browser inkl. Captcha/2FA – keine Zugangsdaten werden gespeichert.").into(),
        },
        ConnectorKind::EnableBanking => BankDescriptor {
            kind,
            name: tr("Bank per PSD2 (Enable Banking)").into(),
            protocol: tr("PSD2 über Enable Banking (eigene Anwendung)").into(),
            bank_code: String::new(),
            sf_symbol: "building.columns.circle.fill".into(),
            login_label: tr("Bezeichnung (z. B. Kontoname)").into(),
            secret_label: tr("(Zustimmung im Browser)").into(),
            required_settings: s(&[
                "enablebanking.application_id",
                "enablebanking.private_key_pem",
                "enablebanking.redirect_url",
            ]),
            note: tr("Banken wie N26, Revolut oder C24 per PSD2. Benötigt eine kostenlose eigene Anwendung auf enablebanking.com (Application-ID, privater Schlüssel, Redirect-URL). Die Zustimmung erteilen Sie im Browser Ihrer Bank.").into(),
        },
        ConnectorKind::ScalableCapital => BankDescriptor {
            kind,
            name: "Scalable Capital".into(),
            protocol: tr("OAuth-Geräteanmeldung + GraphQL-API der offiziellen CLI").into(),
            bank_code: String::new(),
            sf_symbol: "chart.bar.xaxis".into(),
            login_label: tr("E-Mail (nur Anzeige)").into(),
            secret_label: tr("(nicht nötig – Anmeldung im Browser)").into(),
            required_settings: vec![],
            note: tr("Vorher auf scalable.capital unter Profil → Sicherheit → „Agentic Investing“ den CLI-Zugriff einschalten. Die Anmeldung läuft im Browser und muss alle 7 Tage erneuert werden. Nur Lesezugriff.").into(),
        },
        ConnectorKind::Bunq => BankDescriptor {
            kind,
            name: "bunq".into(),
            protocol: tr("bunq Public API (eigener API-Schlüssel)").into(),
            bank_code: String::new(),
            sf_symbol: "building.columns.circle".into(),
            login_label: tr("E-Mail (nur Anzeige)").into(),
            secret_label: tr("API-Schlüssel").into(),
            required_settings: vec![],
            note: tr("API-Schlüssel in der bunq-App unter Profil → Einstellungen → Entwickler → API-Schlüssel erstellen und „Alle IP-Adressen erlauben“ aktivieren. Keine PSD2-Registrierung nötig.").into(),
        },
    }
}

pub fn make_connector(kind: ConnectorKind, demo: bool) -> Box<dyn BankConnector> {
    make_connector_for(kind, kind.as_str(), demo)
}

/// Like `make_connector`, but with the stored connector key so generic FinTS
/// connections get their BLZ (`fints:<blz>`).
pub fn make_connector_for(kind: ConnectorKind, key: &str, demo: bool) -> Box<dyn BankConnector> {
    if demo {
        return Box::new(demo::DemoConnector::new(kind));
    }
    match kind {
        ConnectorKind::FinTsGeneric => Box::new(fints::FinTsConnector::new(
            ConnectorKind::fints_blz(key).unwrap_or(""),
        )),
        ConnectorKind::VolksbankKasselGoettingen => {
            Box::new(fints::FinTsConnector::new("52090000"))
        }
        ConnectorKind::Direkt1822 => Box::new(fints::FinTsConnector::new("50050201")),
        ConnectorKind::Comdirect => Box::new(comdirect::ComdirectConnector::new()),
        ConnectorKind::PayPal => Box::new(paypal::PayPalConnector::new()),
        ConnectorKind::TradeRepublic => Box::new(trade_republic::TradeRepublicConnector::new()),
        ConnectorKind::AmericanExpress => Box::new(enable_banking::EnableBankingConnector::new(
            "enablebanking.aspsp.amex",
            "American Express",
            "enablebanking.country.amex",
        )),
        ConnectorKind::AmazonVisa => Box::new(enable_banking::EnableBankingConnector::new(
            "enablebanking.aspsp.amazonvisa",
            "Open Bank",
            "enablebanking.country.amazonvisa",
        )),
        ConnectorKind::AmazonOrders => Box::new(amazon_orders::WebOnlyConnector),
        ConnectorKind::Fnz => Box::new(fnz::WebOnlyConnector),
        ConnectorKind::Bunq => Box::new(bunq::BunqConnector::new()),
        ConnectorKind::ScalableCapital => Box::new(scalable::ScalableConnector::new()),
        ConnectorKind::EnableBanking => {
            let (country, aspsp) = ConnectorKind::enable_banking_target(key).unwrap_or(("DE", ""));
            Box::new(enable_banking::EnableBankingConnector::for_aspsp(
                aspsp, country,
            ))
        }
    }
}
