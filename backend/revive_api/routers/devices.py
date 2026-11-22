"""/v1/devices: back up paired cards so a new phone can take them over (features.md A4b).

The path id is the client's SHA-256 of the card's serial number (64 hex digits). The server
stores only an HMAC of it for lookups, and the hash and the bond code encrypted (ADR-012)."""

import base64
import binascii
from datetime import datetime

from fastapi import APIRouter, Path, Response
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select

from ..accounts import CurrentUser
from ..errors import AppError
from ..models import Device
from ..runtime import DB, Run
from ..security import DeviceSecret

router = APIRouter(prefix="/devices", tags=["devices"])

SnHash = Path(pattern=r"^[0-9a-fA-F]{64}$", description="SHA-256 of the card's serial number, hex")


class DeviceIn(BaseModel):
    # Base64 of the bond code the app generated when pairing (16 bytes on v1.50, prd.md §3).
    bond_id: str = Field(min_length=4, max_length=128)
    name: str = Field(default="", max_length=64)
    firmware: str = Field(default="", max_length=32)

    @field_validator("bond_id")
    @classmethod
    def base64_bytes(cls, value: str) -> str:
        try:
            raw = base64.b64decode(value, validate=True)
        except (binascii.Error, ValueError) as error:
            raise ValueError("bond_id must be base64") from error
        if not 1 <= len(raw) <= 64:
            raise ValueError("bond_id must be 1 to 64 bytes")
        return value


class DeviceOut(BaseModel):
    sn_hash: str
    bond_id: str
    name: str
    firmware: str
    updated_at: datetime


def _out(run, device: Device) -> DeviceOut:
    secret = run.vault.open(device.user_id, device.sn_key, device.secret)
    return DeviceOut(
        sn_hash=secret.sn_hash,
        bond_id=base64.b64encode(secret.bond_id).decode(),
        name=device.name,
        firmware=device.firmware,
        updated_at=device.updated_at,
    )


@router.get("")
async def list_devices(user: CurrentUser, db: DB, run: Run) -> list[DeviceOut]:
    devices = await db.scalars(select(Device).where(Device.user_id == user.id).order_by(Device.updated_at.desc()))
    return [_out(run, device) for device in devices]


@router.put("/{sn_hash}")
async def put_device(body: DeviceIn, user: CurrentUser, db: DB, run: Run, sn_hash: str = SnHash) -> DeviceOut:
    sn_hash = sn_hash.lower()
    now = run.clock.now()
    key = run.vault.lookup_key(sn_hash)
    sealed = run.vault.seal(user.id, key, DeviceSecret(sn_hash=sn_hash, bond_id=base64.b64decode(body.bond_id)))
    device = await db.scalar(select(Device).where(Device.user_id == user.id, Device.sn_key == key).with_for_update())
    if device is None:
        device = Device(
            user_id=user.id,
            sn_key=key,
            secret=sealed,
            name=body.name,
            firmware=body.firmware,
            created_at=now,
            updated_at=now,
        )
        db.add(device)
    else:
        device.secret, device.name, device.firmware, device.updated_at = sealed, body.name, body.firmware, now
    await db.flush()
    return _out(run, device)


@router.delete("/{sn_hash}", status_code=204)
async def delete_device(user: CurrentUser, db: DB, run: Run, sn_hash: str = SnHash) -> Response:
    device = await db.scalar(
        select(Device).where(Device.user_id == user.id, Device.sn_key == run.vault.lookup_key(sn_hash.lower()))
    )
    if device is None:
        raise AppError(404, "device_not_found", "账号里没有这张录音卡")
    await db.delete(device)
    return Response(status_code=204)
