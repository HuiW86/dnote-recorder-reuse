"""Passwords, tokens, verification codes and the encryption of device secrets (ADR-012)."""

import hashlib
import hmac
import json
import os
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .config import Settings

_hasher = PasswordHasher()
# Verified against when the account does not exist, so a wrong email costs the same time.
_dummy_hash = _hasher.hash("not-a-real-password")


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(stored: str | None, password: str) -> bool:
    try:
        return _hasher.verify(stored or _dummy_hash, password) and stored is not None
    except (VerificationError, InvalidHashError):
        return False


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


class Tokens:
    """Access tokens are JWTs checked against the injected clock, not the wall clock, so tests can
    move time. Refresh tokens are random strings; only their SHA-256 is stored."""

    def __init__(self, settings: Settings):
        self._secret = settings.jwt_secret.get_secret_value()
        self.access_ttl = timedelta(seconds=settings.access_ttl_seconds)
        self.refresh_ttl = timedelta(days=settings.refresh_ttl_days)

    def access(self, user_id: uuid.UUID, now: datetime) -> str:
        claims = {
            "sub": str(user_id),
            "typ": "access",
            "iat": int(now.timestamp()),
            "exp": int((now + self.access_ttl).timestamp()),
        }
        return jwt.encode(claims, self._secret, algorithm="HS256")

    def read_access(self, token: str, now: datetime) -> uuid.UUID:
        """Raises ExpiredToken or InvalidToken."""
        claims = self._claims(token)
        if int(claims["exp"]) <= int(now.timestamp()):
            raise ExpiredToken
        return self._subject(claims)

    def owner(self, token: str) -> uuid.UUID | None:
        """Whose token this is, expired or not; None when it is not one of ours. For scoping
        idempotency keys, which must survive the 15-minute access token being renewed."""
        try:
            return self._subject(self._claims(token))
        except InvalidToken:
            return None

    def _claims(self, token: str) -> dict:
        # Time checks use the injected clock (read_access), never PyJWT's wall clock.
        try:
            claims = jwt.decode(
                token,
                self._secret,
                algorithms=["HS256"],
                options={
                    "verify_exp": False,
                    "verify_iat": False,
                    "verify_nbf": False,
                    "require": ["sub", "exp", "typ"],
                },
            )
        except jwt.PyJWTError as error:
            raise InvalidToken from error
        if claims.get("typ") != "access":
            raise InvalidToken
        return claims

    @staticmethod
    def _subject(claims: dict) -> uuid.UUID:
        try:
            return uuid.UUID(claims["sub"])
        except ValueError as error:
            raise InvalidToken from error

    @staticmethod
    def new_refresh() -> tuple[str, str]:
        raw = secrets.token_urlsafe(32)
        return raw, sha256_hex(raw)


class InvalidToken(Exception):
    pass


class ExpiredToken(Exception):
    pass


class Codes:
    def __init__(self, settings: Settings):
        self._secret = settings.code_secret.get_secret_value().encode()

    @staticmethod
    def new() -> str:
        return f"{secrets.randbelow(1_000_000):06d}"

    def digest(self, purpose: str, target: str, code: str) -> str:
        return hmac.new(self._secret, f"{purpose}:{target}:{code}".encode(), hashlib.sha256).hexdigest()

    def matches(self, stored: str, purpose: str, target: str, code: str) -> bool:
        return hmac.compare_digest(stored, self.digest(purpose, target, code))


@dataclass(frozen=True)
class DeviceSecret:
    sn_hash: str
    bond_id: bytes


class Box:
    """AES-256-GCM with a random nonce in front; `context` is bound in as associated data, so a
    blob copied to another row does not open."""

    def __init__(self, settings: Settings):
        self._aead = AESGCM(settings.bond_key_bytes)

    def seal(self, context: str, plain: bytes) -> bytes:
        nonce = os.urandom(12)
        return nonce + self._aead.encrypt(nonce, plain, context.encode())

    def open(self, context: str, sealed: bytes) -> bytes:
        return self._aead.decrypt(sealed[:12], sealed[12:], context.encode())


class DeviceVault:
    """The server keeps an HMAC of the client's SHA-256(sn) for lookups, and the hash itself plus
    the bond code only encrypted (bound to the user and the lookup key)."""

    def __init__(self, settings: Settings):
        self._pepper = settings.sn_pepper.get_secret_value().encode()
        self._box = Box(settings)

    def lookup_key(self, sn_hash: str) -> str:
        return hmac.new(self._pepper, sn_hash.lower().encode(), hashlib.sha256).hexdigest()

    def seal(self, user_id: uuid.UUID, sn_key: str, secret: DeviceSecret) -> bytes:
        plain = json.dumps({"sn_hash": secret.sn_hash, "bond_id": secret.bond_id.hex()}).encode()
        return self._box.seal(f"device:{user_id}:{sn_key}", plain)

    def open(self, user_id: uuid.UUID, sn_key: str, sealed: bytes) -> DeviceSecret:
        plain = json.loads(self._box.open(f"device:{user_id}:{sn_key}", sealed))
        return DeviceSecret(sn_hash=plain["sn_hash"], bond_id=bytes.fromhex(plain["bond_id"]))
