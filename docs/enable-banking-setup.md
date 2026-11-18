# PSD2 (Enable Banking) kostenlos für eigene Konten einrichten

Für Banken ohne FinTS-Zugang (z. B. **N26**, **C24**, **Revolut**, **American Express**, **Amazon Visa** oder **Trade Republic** per PSD2) nutzt GiroCrab die Schnittstelle von [Enable Banking](https://enablebanking.com) (regulierter europäischer Kontoinformationsdienstleister / AISP).

Im sogenannten **Restricted Mode** ist Enable Banking für den Abruf **eigener Konten dauerhaft kostenlos** – deine Daten fließen dabei ohne fremdes GiroCrab-Backend direkt zwischen deinem Gerät und der Schnittstelle.

👉 **[Interaktive Schritt-für-Schritt-Anleitung öffnen (`girocrab.de`)](https://girocrab.de/girocrab_psd2_anleitung.html)**

---

## Schritt-für-Schritt-Anleitung (ca. 3 Minuten)

### 1. Kostenlos anmelden & Anwendung registrieren
Öffne [enablebanking.com/cp/applications](https://enablebanking.com/cp/applications) (Anmeldung per E-Mail-Link, kein Passwort nötig) und fülle das Formular **Add a new application** wie folgt aus:

| Feld im Formular | Was du einträgst | Hintergrund |
| :--- | :--- | :--- |
| **1. Environment** | **`Production`** | Wichtig: *Sandbox* enthält nur Spielgeld-Testbanken. Echte Banken funktionieren nur in *Production*. |
| **2. Private RSA key** | **`Generate in the browser (using SubtleCrypto) and export private key`** | Erzeugt deinen privaten Schlüssel lokal im Browser und lädt beim Speichern automatisch die Datei `<uuid>.pem` herunter. |
| **Application name** | z. B. `GiroCrab Personal` | Frei wählbar. |
| **Allowed redirect URLs** | `https://localhost/girocrab/callback` | **Exakt diese URL eintragen.** GiroCrab fängt die Weiterleitung im eingebauten Browserfenster automatisch ab (es läuft kein lokaler Server). |
| **Application description** | z. B. `Private Kontoverwaltung mit GiroCrab` | Kurzer Hinweis genügt. |
| **Email for data protection** | Deine eigene E-Mail-Adresse | Pflichtfeld im Formular. |
| **Privacy URL / Terms URL** | `https://girocrab.de` | Für die private Nutzung eigener Konten nicht relevant; eine gültige `https://`-Adresse genügt. |

Klicke auf **Register**. Dein Browser lädt jetzt automatisch deine Schlüsseldatei **`<application-id>.pem`** in deinen `Downloads`-Ordner herunter.

---

### 2. Eigene Konten freischalten („Activate by linking accounts“)
Nach dem Anlegen steht deine Anwendung zunächst auf **`Inactive`**.

1. Klicke bei deiner Anwendung auf den grünen Button **Activate by linking accounts** *(nicht auf „Request activation“ – das ist nur für kostenpflichtige Firmenverträge)*.
2. Wähle deine Bank aus:
   * **Country:** z. B. `Germany`
   * **ASPSP (Bank):** z. B. `Trade Republic`, `N26`, `C24 Bank` oder `American Express`
   * **Usage type:** `personal` (bzw. `business` bei Geschäftskonten wie Finom)
3. Klicke auf **Link** und anschließend auf **Authentifizierung fortsetzen**.
4. Bestätige die Freigabe einmalig in deiner Banking-App (z. B. QR-Code mit der Trade-Republic-App scannen → *„Enable Banking möchte auf deine Bank zugreifen“* → **Akzeptieren**).
5. Sobald das erste eigene Konto verknüpft ist, springt deine Anwendung im Control Panel von `Inactive` auf **`Active`**. Falls du weitere PSD2-Banken nutzen möchtest, wiederhole den Klick auf **Link** einfach für jede weitere Bank.

---

### 3. Schlüsseldatei (`.pem`) in GiroCrab auswählen
1. Öffne in GiroCrab die Bankverbindung (oder Einstellungen → Enable Banking) und klicke auf **„Schlüsseldatei (.pem) wählen …“**.
2. Wähle die heruntergeladene `<application-id>.pem` aus deinem `Downloads`-Ordner aus – GiroCrab übernimmt den privaten Schlüssel und die Application-ID automatisch aus dem Dateinamen.
3. Klicke auf **„Anwendung prüfen“**: GiroCrab bestätigt mit grünem Haken, dass *Production*, *Active*-Status und *Redirect-URL* passen.

---

## Häufige Fragen

* **Wie oft muss ich die 2FA bestätigen?**
  Einmalig beim Verknüpfen und danach gesetzlich bedingt (PSD2-Richtlinie) nur noch alle **90 bis 180 Tage** zur Erneuerung der Einwilligung. Alle täglichen Kontoabrufe dazwischen laufen ohne erneute 2FA durch.
* **Welche Konten liefert PSD2?**
  Nach PSD2 sind Banken verpflichtet, Zahlungskonten (Girokonten, Kreditkarten) bereitzustellen. Ob Tagesgeld- oder Sparkonten mitgeliefert werden, entscheidet die jeweilige Bank; Wertpapier-Depotbestände sind über PSD2/XS2A grundsätzlich nicht enthalten (nutze für Depots in GiroCrab FinTS oder die direkten Broker-Connectoren).
