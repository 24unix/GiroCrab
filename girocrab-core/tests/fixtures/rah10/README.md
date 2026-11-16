# Synthetic RAH-10 interoperability fixtures

`reference.json` contains deliberately invented test identities and a disposable
2048-bit RSA key. It has never been used with a bank. Do not use it for banking.

The frozen vectors are produced by `generate.py`, independently of GiroCrab:
Python `hashlib`/`hmac` derive the RDHX key and MAC; `cryptography`'s OpenSSL
backend supplies 3DES-CBC, AES-CBC and RSA-PSS; Python integer `pow` supplies the
raw RSA transport operation. The normal Rust test run reads only the JSON and
needs neither Python nor an OpenSSL Rust wrapper. To regenerate in an isolated
Python environment, install `cryptography` and run `python generate.py`. This
creates a fresh disposable key and fresh PSS salts, so the JSON changes.

Covered cross-implementation checks:

- RDHX profile 10: PBKDF2-HMAC-SHA256, 3DES-CBC with PKCS#7, HMAC-SHA256.
- A correctly MACed, encrypted RDHX container with a deliberately incorrect CRT
  exponent is rejected after authentication. A second authenticated fixture with
  a composite RSA factor is also rejected (RSA congruences alone do not prove
  that the factors are prime).
- RAH-10 signature: SHA256(message) is the input to RSASSA-PSS with SHA256,
  MGF1-SHA256 and 32 salt bytes. A single-hash verification must fail.
- AES-256-CBC with zero IV, and message padding `80 00 ...`.
- RSAEP/RSADP key transport with a modulus-width, zero-left-padded AES key,
  including a leading zero in the 32-byte key.
- A complete independently assembled RAH-10 response passes the normal parser,
  decryption and signature validation.

Protocol/layout reference, pinned at commit
`7482dcdb85b1e6e879501f87e23c3264adc393c3`:

- [RAH10 passport, especially encryptKey/decrypt](https://github.com/hbci4j/hbci4java/blob/7482dcdb85b1e6e879501f87e23c3264adc393c3/src/main/java/org/kapott/hbci/passport/HBCIPassportRAH10.java#L590)
- [RDHX container reader](https://github.com/hbci4j/hbci4java/tree/7482dcdb85b1e6e879501f87e23c3264adc393c3/src/main/java/org/kapott/hbci/passport/rdhXfile)
- [RFC 8017, RSA primitives §5.1 and RSASSA-PSS §8.1](https://www.rfc-editor.org/rfc/rfc8017.html)

Key transport uses the raw RSA primitives prescribed by the referenced RAH-10
implementation, not RSAES-PKCS1-v1_5, OAEP or ISO 9796-2 signature padding. Private
operations in GiroCrab use blinding and a CRT fault check; out-of-range RSA
representatives are rejected.

These are independent implementation vectors, not bank-provided or certified
conformance vectors. They do not establish successful Commerzbank login or
account retrieval. That live test remains pending a FinTS product registration.
