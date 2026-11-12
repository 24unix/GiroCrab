# Sicherheitssperre für Bankverbindungen

Hier liegt die veröffentlichte, signierte `banking-policy.json` samt `.sig`.
Die App lädt sie von dieser festen Adresse
(`https://raw.githubusercontent.com/GiroCrab/GiroCrab/main/policy/banking-policy.json`).

Nicht von Hand bearbeiten: `scripts/banking-policy.sh keygen` legt die erste
Datei an, `set` und `clear` signieren, committen und pushen neue Stände.
Solange `BankingPolicy.publicKeys` nur den Platzhalter enthält, gibt es hier
keine Datei und die Funktion ist aus. Siehe `docs/banking-policy.md`.
