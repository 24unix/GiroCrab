"""Generate SYNTHETIC public test vectors, never use these keys for banking.

Independent implementation: Python hashlib/hmac + cryptography's OpenSSL backend.
Run manually in a venv with cryptography installed. Frozen output is committed;
Rust tests consume it without Python, OpenSSL wrappers, or a network connection.
See README.md for the protocol reference and limits of this test.
"""
import hashlib
import hmac
import json
import struct
from types import SimpleNamespace
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization, padding
from cryptography.hazmat.primitives.asymmetric import rsa, padding as rsa_padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES


def tlv(tag, data):
    return struct.pack('<HH', tag, len(data)) + data


def integer(n):
    data = n.to_bytes((n.bit_length() + 7) // 8, 'little')
    return struct.pack('<H', len(data)) + data


def cbc_encrypt(algorithm, data, block_bits, padded):
    if padded:
        padder = padding.PKCS7(block_bits).padder()
        data = padder.update(data) + padder.finalize()
    enc = Cipher(algorithm, modes.CBC(bytes(block_bits // 8))).encryptor()
    return enc.update(data) + enc.finalize()


def keyfile(k, corrupt_crt=False):
    password = b'invented-reference-password'
    salt = bytes(range(20))
    iterations = 1000
    derived = hashlib.pbkdf2_hmac('sha256', password, salt, iterations, 32)
    # RDHX recombination factors Ap = q * (q^-1 mod p), Aq = p * (p^-1 mod q).
    private = b''.join(integer(n) for n in [k.public_numbers.n, k.p, k.q,
        k.dmp1 ^ int(corrupt_crt), k.dmq1, k.q * pow(k.q, -1, k.p), k.p * pow(k.p, -1, k.q)])
    encrypted = cbc_encrypt(TripleDES(derived[:24]), private, 64, True)[::-1]
    bank = bytearray(b' ' * 237)
    bank[:3] = b'280'
    bank[3:11] = b'12345678'
    bank[93:97] = b'demo'
    bank[153] = ord('1')
    bank[183] = 2
    host = b'hbci.commerzbank.de'
    bank[184:184 + len(host)] = host
    bank[234:237] = bytes([1, 0, 4])
    account = tlv(0x444b, bank)
    for kind in (0, 1):
        data = bytes([2, kind, 1, 0, 1, 0]) + integer(k.public_numbers.e) + integer(k.public_numbers.n)
        data += struct.pack('<H', len(encrypted)) + encrypted
        account += tlv(0x4553, data)
    data = tlv(0x4e56, struct.pack('<HH', 10, 1) + salt + struct.pack('<I', iterations))
    data += tlv(0x564b, account) + tlv(0x4452, b'20261115000000')
    return (data + tlv(0x4d44, hmac.digest(derived, data, 'sha256'))).hex()


if __name__ == '__main__':
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    k = key.private_numbers()
    message = b"HNSHK:2:4+RAH:10'HIRMG:3:2+0010::OK'"
    signature = key.sign(hashlib.sha256(message).digest(),
        rsa_padding.PSS(mgf=rsa_padding.MGF1(hashes.SHA256()), salt_length=32), hashes.SHA256())
    session = bytes(range(32))  # Includes a leading zero; must survive fixed-width RSA decoding.
    ciphertext = pow(int.from_bytes(session, 'big'), k.public_numbers.e, k.public_numbers.n).to_bytes(256, 'big')
    padded = message + b'\x80'
    padded += bytes((-len(padded)) % 16)
    signed = (b"HNSHK:2:4+RAH:10+2+2+1+1+1::1+2+1:20261115:120000+1:6:1+6:10:19+280:12345678:bank:S:1:1'"
        b"HIRMG:3:2+0010::OK'")
    sig = key.sign(hashlib.sha256(signed).digest(),
        rsa_padding.PSS(mgf=rsa_padding.MGF1(hashes.SHA256()), salt_length=32), hashes.SHA256())
    plain = signed + b"HNSHA:4:2+2+@256@" + sig + b"'" + b"\x80"
    plain += bytes((-len(plain)) % 16)
    encrypted = cbc_encrypt(algorithms.AES(session), plain, 128, False)
    body = (b"HNVSK:998:3+RAH:10+4+1+1::1+1:20261115:120000+2:2:14:@256@" + ciphertext
        + b":6:1+280:12345678:bank:V:1:1+0'HNVSD:999:1+@" + str(len(encrypted)).encode()
        + b"@" + encrypted + b"'HNHBS:5:1+1'")
    header = b"HNHBK:1:3+000000000000+300+dialog+1'"
    wire = header.replace(b'000000000000', f'{len(header) + len(body):012}'.encode()) + body
    composite_p = k.p * 3
    composite = SimpleNamespace(p=composite_p, q=k.q,
        dmp1=pow(k.public_numbers.e, -1, composite_p - 1), dmq1=k.dmq1,
        public_numbers=SimpleNamespace(n=k.public_numbers.n * 3, e=k.public_numbers.e))
    data = dict(wire=wire.hex(), source='Python hashlib/hmac + cryptography/OpenSSL; synthetic, not a bank response',
        public_der=key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo).hex(),
        p=format(k.p, 'x'), q=format(k.q, 'x'), e=format(k.public_numbers.e, 'x'),
        message=message.hex(), signature=signature.hex(), session_key=session.hex(),
        wrapped_key=ciphertext.hex(), padded_message=padded.hex(),
        aes_ciphertext=cbc_encrypt(algorithms.AES(session), padded, 128, False).hex(),
        keyfile=keyfile(k), invalid_crt_keyfile=keyfile(k, True), composite_factor_keyfile=keyfile(composite))
    Path(__file__).with_name('reference.json').write_text(json.dumps(data, indent=2) + '\n')
