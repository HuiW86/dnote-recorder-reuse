"""Settings refuse weak secrets; production refuses to start without real code senders, a real
object store, speech recognition engine or language model, or without monthly allowances set."""

import pytest
from pydantic import ValidationError

from revive_api.config import Settings
from revive_api.runtime import Runtime


def test_secrets_must_be_strong(settings):
    good = settings.model_dump() | {
        k: getattr(settings, k).get_secret_value() for k in ("jwt_secret", "code_secret", "sn_pepper", "bond_key")
    }
    with pytest.raises(ValidationError, match="at least 32 characters"):
        Settings(**(good | {"jwt_secret": "short"}))
    with pytest.raises(ValidationError, match="32 bytes"):
        Settings(**(good | {"bond_key": "c2hvcnQ="}))
    with pytest.raises(ValidationError, match="base64"):
        Settings(**(good | {"bond_key": "!!!"}))


def test_production_needs_real_senders(settings):
    prod = settings.model_copy(update={"environment": "prod"})
    with pytest.raises(RuntimeError, match="real SMS and email senders"):
        Runtime.build(prod)


def test_production_needs_a_real_object_store(settings):
    from conftest import MemorySender

    prod = settings.model_copy(update={"environment": "prod"})
    with pytest.raises(RuntimeError, match="real object store"):
        Runtime.build(prod, sms=MemorySender(), email=MemorySender())


def test_production_needs_a_real_speech_engine(settings):
    from conftest import MemorySender

    prod = settings.model_copy(update={"environment": "prod"})
    with pytest.raises(RuntimeError, match="real speech recognition engine"):
        Runtime.build(prod, sms=MemorySender(), email=MemorySender(), store=object())


def test_production_needs_a_real_language_model(settings):
    from conftest import MemorySender

    prod = settings.model_copy(update={"environment": "prod"})
    with pytest.raises(RuntimeError, match="real language model"):
        Runtime.build(prod, sms=MemorySender(), email=MemorySender(), store=object(), transcriber=object())


def test_production_needs_allowances_set(settings):
    from conftest import MemorySender

    prod = settings.model_copy(update={"environment": "prod"})
    real = {
        "sms": MemorySender(),
        "email": MemorySender(),
        "store": object(),
        "transcriber": object(),
        "chat": object(),
    }
    with pytest.raises(RuntimeError, match="REVIVE_ASR_MONTHLY_SECONDS"):
        Runtime.build(prod, **real)
    with pytest.raises(RuntimeError, match="REVIVE_LLM_MONTHLY_TOKENS"):
        Runtime.build(prod.model_copy(update={"asr_monthly_seconds": 3600}), **real)
