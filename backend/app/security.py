"""Dependency-free password and signed-access-token primitives.

Production secrets are supplied through the environment. Values are never
logged or included in API errors.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _unb64(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=2**14, r=8, p=1)
    return f"scrypt$16384$8$1${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, n, r, p, salt, expected = encoded.split("$")
        if algorithm != "scrypt":
            return False
        actual = hashlib.scrypt(password.encode("utf-8"), salt=_unb64(salt), n=int(n), r=int(r), p=int(p))
        return hmac.compare_digest(actual, _unb64(expected))
    except (ValueError, TypeError):
        return False


RECOVERY_VERIFIER_PREFIX = "recovery-v1$"


def hash_recovery_secret(secret: str) -> str:
    """Store the client-derived recovery secret with a distinct KDF namespace.

    Recovery secrets are high-entropy values derived from a BIP-39 mnemonic on
    the device.  They are never the mnemonic itself and must not share the
    password credential's storage format by accident.
    """
    return RECOVERY_VERIFIER_PREFIX + hash_password(secret)


def verify_recovery_secret(secret: str, encoded: str) -> bool:
    if not encoded.startswith(RECOVERY_VERIFIER_PREFIX):
        return False
    return verify_password(secret, encoded.removeprefix(RECOVERY_VERIFIER_PREFIX))


def refresh_token() -> str:
    return secrets.token_urlsafe(48)


def recovery_token() -> str:
    """Opaque, one-use control-plane token; never accepted as a bearer token."""
    return secrets.token_urlsafe(48)


def token_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def encode_access_token(member_id: UUID, device_id: UUID, secret: str, ttl_seconds: int) -> str:
    now = datetime.now(UTC)
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"sub": str(member_id), "device": str(device_id), "iat": int(now.timestamp()), "exp": int((now + timedelta(seconds=ttl_seconds)).timestamp()), "iss": "familyapp"}
    signed = f"{_b64(json.dumps(header, separators=(',', ':'), sort_keys=True).encode())}.{_b64(json.dumps(payload, separators=(',', ':'), sort_keys=True).encode())}"
    signature = _b64(hmac.new(secret.encode("utf-8"), signed.encode("ascii"), hashlib.sha256).digest())
    return f"{signed}.{signature}"


def decode_access_token(value: str, secret: str) -> dict[str, Any] | None:
    try:
        header, payload, supplied = value.split(".")
        expected = _b64(hmac.new(secret.encode("utf-8"), f"{header}.{payload}".encode("ascii"), hashlib.sha256).digest())
        if not hmac.compare_digest(expected, supplied):
            return None
        decoded = json.loads(_unb64(payload))
        if decoded.get("iss") != "familyapp" or int(decoded["exp"]) <= int(datetime.now(UTC).timestamp()):
            return None
        UUID(str(decoded["sub"])); UUID(str(decoded["device"]))
        return decoded
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
