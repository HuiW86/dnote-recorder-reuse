"""Settings from environment variables (prefix REVIVE_). Secrets are never defaulted."""

import base64
from typing import Literal

from pydantic import SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="REVIVE_")

    environment: Literal["dev", "test", "prod"] = "dev"
    # postgresql+psycopg://user:password@host:port/db (one driver for the app and Alembic, ADR-012)
    database_url: str

    # Signs access tokens (HS256). Leaking it lets anyone forge 15-minute tokens.
    jwt_secret: SecretStr
    # Keys the HMAC of verification codes.
    code_secret: SecretStr
    # Keys the HMAC of the client's SHA-256(sn): serial numbers can be enumerated, so a bare hash
    # in a leaked database would give away the sn and with it the card's audio key (ADR-006).
    sn_pepper: SecretStr
    # AES-256-GCM key for bond codes, base64 of 32 bytes. To be replaced by KMS envelope encryption.
    bond_key: SecretStr

    access_ttl_seconds: int = 15 * 60
    refresh_ttl_days: int = 30
    code_ttl_seconds: int = 10 * 60
    code_max_attempts: int = 5
    code_resend_seconds: int = 60
    code_daily_limit: int = 10
    idempotency_ttl_hours: int = 24

    @field_validator("jwt_secret", "code_secret", "sn_pepper")
    @classmethod
    def long_enough(cls, value: SecretStr) -> SecretStr:
        if len(value.get_secret_value()) < 32:
            raise ValueError("must be at least 32 characters")
        return value

    @field_validator("bond_key")
    @classmethod
    def thirty_two_bytes(cls, value: SecretStr) -> SecretStr:
        try:
            raw = base64.b64decode(value.get_secret_value(), validate=True)
        except ValueError as error:
            raise ValueError("must be base64") from error
        if len(raw) != 32:
            raise ValueError("must decode to 32 bytes")
        return value

    @property
    def bond_key_bytes(self) -> bytes:
        return base64.b64decode(self.bond_key.get_secret_value())
