"""Settings refuse weak secrets; production refuses to start without real code senders."""

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
