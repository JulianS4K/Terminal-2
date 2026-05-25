"""EvoClient.decrypt_barcode — TEvo Fernet barcode decryption (read-side).

Validates the documented recipe: the barcode is Fernet-encrypted and the key
is base64url(first 32 chars of the API secret). We encrypt with that exact
recipe, then assert the client decrypts back to the plaintext.
"""

import base64

import pytest

from evo_client import EvoClient

# >= 32 chars so the key derivation is valid (Fernet needs a 32-byte key).
SECRET = "32_CHARS_LONG_EXAMPLE_API_SECRET"  # exactly 32
assert len(SECRET) >= 32


def _encrypt(plaintext: str, secret: str = SECRET) -> str:
    """Encrypt the way TEvo documents it, so the round-trip is faithful."""
    from cryptography.fernet import Fernet

    key = base64.urlsafe_b64encode(secret.encode("utf-8")[:32])
    return Fernet(key).encrypt(plaintext.encode("utf-8")).decode("utf-8")


def _client(secret: str = SECRET) -> EvoClient:
    # token is only used for signing live calls; decrypt_barcode doesn't need it.
    return EvoClient(token="unused-token", secret=secret)


def test_decrypt_barcode_roundtrip():
    barcode = "723917860"
    token = _encrypt(barcode)
    assert _client().decrypt_barcode(token) == barcode


def test_decrypt_barcode_longer_secret_uses_first_32_chars():
    # A secret longer than 32 chars must key off the first 32 only.
    long_secret = SECRET + "EXTRA_TRAILING_BYTES_IGNORED"
    key = base64.urlsafe_b64encode(long_secret.encode("utf-8")[:32])
    from cryptography.fernet import Fernet

    token = Fernet(key).encrypt(b"primary_99").decode("utf-8")
    assert _client(long_secret).decrypt_barcode(token) == "primary_99"


def test_decrypt_barcode_forged_token_raises():
    with pytest.raises(ValueError):
        _client().decrypt_barcode("gAAAAABnot_a_real_token_obviously_invalid==")


def test_decrypt_barcode_wrong_secret_raises():
    token = _encrypt("723917860", secret=SECRET)
    other = "DIFFERENT_32_CHAR_SECRET_VALUE!!"  # 32 chars, different key
    assert len(other) >= 32
    with pytest.raises(ValueError):
        _client(other).decrypt_barcode(token)


def test_decrypt_barcode_short_secret_raises():
    with pytest.raises(ValueError):
        _client("too-short").decrypt_barcode("anything")
