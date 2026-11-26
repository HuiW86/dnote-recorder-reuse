import os

import pytest

from revive_api.storage import LocalStore


async def test_aborting_an_upload_retries_after_a_part_cannot_be_removed(tmp_path, monkeypatch):
    store = LocalStore(tmp_path, "http://test", b"test")
    key = "audio/recording"
    upload_id = await store.start_upload(key, "audio/ogg")
    await store.put_part(key, upload_id, 1, b"part")
    unlink = os.unlink

    def simulate_failure(path, *args, **kwargs):
        if os.path.basename(path) == "00001":
            raise PermissionError("part is locked")
        return unlink(path, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(os, "unlink", simulate_failure)
        # The deletion queue needs the failure to keep the row for a later attempt.
        with pytest.raises(PermissionError):
            await store.abort_upload(key, upload_id)
    assert (tmp_path / "uploads" / upload_id / "00001").is_file()

    await store.abort_upload(key, upload_id)
    assert not (tmp_path / "uploads" / upload_id).exists()
    await store.abort_upload(key, upload_id)
