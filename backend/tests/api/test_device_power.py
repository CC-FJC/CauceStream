"""API tests for POST /api/devices/{device_uid}/power.

The power controller registry is replaced with fakes: no adb, no real
WebSocket. The default (production) wiring is covered by
tests/power/test_registry.py.
"""

import asyncio
import json

from app.api.deps import get_power_controller_registry
from app.core.config import get_settings
from app.core.ws import connection_manager
from app.main import app
from app.models.device import Device
from app.power.base import DevicePowerController, PowerControllerRegistry, PowerResult
from app.power.websocket import WebSocketPowerController
from tests.conftest import ADMIN_EMAIL, ADMIN_PASSWORD, bearer, login

UID = "CAUCE-POWER-1"
IP = "10.15.1.153"
MAC = "7C:01:3E:7A:7D:52"


class FakeController(DevicePowerController):
    method = "fake-adb"

    def __init__(self, result: PowerResult):
        self._result = result

    async def turn_on(self, device: Device) -> PowerResult:
        return self._result

    async def turn_off(self, device: Device) -> PowerResult:
        return self._result


class SleepyController(DevicePowerController):
    method = "sleepy"

    async def turn_on(self, device: Device) -> PowerResult:
        await asyncio.sleep(5)
        return PowerResult("on", self.method, True, True, "nunca llega")

    async def turn_off(self, device: Device) -> PowerResult:
        await asyncio.sleep(5)
        return PowerResult("off", self.method, True, True, "nunca llega")


class FakeWS:
    def __init__(self):
        self.sent: list[str] = []

    async def send_text(self, data: str) -> None:
        self.sent.append(data)

    async def close(self, code: int = 1000, reason: str | None = None) -> None:
        pass


async def register_device(client, token, *, device_type="google_tv", uid=UID):
    response = await client.post(
        "/api/devices",
        json={
            "device_uid": uid,
            "name": f"Pantalla {uid}",
            "type": device_type,
            "ip_address": IP,
            "mac_address": MAC,
            "port": 8001,
        },
        headers=bearer(token),
    )
    assert response.status_code == 201, response.text


def use_registry(registry: PowerControllerRegistry) -> None:
    app.dependency_overrides[get_power_controller_registry] = lambda: registry


async def power(client, token, action, uid=UID):
    return await client.post(
        f"/api/devices/{uid}/power",
        json={"action": action},
        headers=bearer(token),
    )


async def test_power_unknown_device_404(client, admin):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    registry = PowerControllerRegistry()
    registry.set_fallback(lambda: FakeController(PowerResult("off", "fake", True, True)))
    use_registry(registry)
    response = await power(client, token, "off", uid="CAUCE-GHOST")
    assert response.status_code == 404


async def test_power_off_executed_by_type_controller(client, admin):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    registry = PowerControllerRegistry()
    registry.register(
        "google_tv",
        lambda: FakeController(
            PowerResult("off", "adb", True, True, "keyevent SLEEP (223) enviado")
        ),
    )
    use_registry(registry)

    response = await power(client, token, "off")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["device_uid"] == UID
    assert body["action"] == "off"
    assert body["method"] == "adb"
    assert body["executed"] is True
    assert body["success"] is True
    assert "SLEEP" in body["detail"]
    assert body["command_id"] is None  # solo para fallback WebSocket


async def test_power_on_already_on_is_success_not_executed(client, admin):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    registry = PowerControllerRegistry()
    registry.set_fallback(
        lambda: FakeController(
            PowerResult("on", "adb", False, True, "ya estaba encendido")
        )
    )
    use_registry(registry)

    response = await power(client, token, "on")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["executed"] is False


async def test_power_failure_is_200_with_success_false(client, admin):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    registry = PowerControllerRegistry()
    registry.set_fallback(
        lambda: FakeController(
            PowerResult("off", "adb", False, False, "responde a ping pero no acepta ADB")
        )
    )
    use_registry(registry)

    response = await power(client, token, "off")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is False
    assert "no acepta ADB" in body["detail"]


async def test_power_websocket_fallback_409_without_channel(
    client, admin, monkeypatch
):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token, device_type="screen")  # sin controller nativo
    registry = PowerControllerRegistry()
    registry.set_fallback(WebSocketPowerController)
    use_registry(registry)

    # Sin canal: la espera acotada de reconexión también vence ya.
    monkeypatch.setattr(get_settings(), "CAUCE_POWER_CHANNEL_WAIT_S", 0.05)

    response = await power(client, token, "off")
    assert response.status_code == 409
    assert "WebSocket" in response.json()["detail"]


async def test_power_waits_for_channel_reconnect_then_delivers(
    client, admin, monkeypatch
):
    """El canal caído suele ser una ventana pasajera: el endpoint espera
    la reconexión propia del cliente en vez de tropezar con un 409."""
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token, device_type="screen")
    registry = PowerControllerRegistry()
    registry.set_fallback(WebSocketPowerController)
    use_registry(registry)

    # Espera holgada para la fake; el cliente "reconecta" a los 0.3 s.
    monkeypatch.setattr(get_settings(), "CAUCE_POWER_CHANNEL_WAIT_S", 2.0)
    ws = FakeWS()

    async def reconnect_soon():
        await asyncio.sleep(0.3)
        await connection_manager.connect(UID, ws)

    reconnect_task = asyncio.create_task(reconnect_soon())
    try:
        response = await power(client, token, "on")
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["method"] == "websocket"
        assert body["delivered"] is True
        assert '"power.command"' in ws.sent[-1]
        assert '"action": "on"' in ws.sent[-1]
    finally:
        await reconnect_task
        connection_manager.disconnect(UID, ws)


async def test_power_websocket_fallback_delivers_when_channel_open(client, admin):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token, device_type="screen")
    registry = PowerControllerRegistry()
    registry.set_fallback(WebSocketPowerController)
    use_registry(registry)

    ws = FakeWS()
    await connection_manager.connect(UID, ws)
    try:
        response = await power(client, token, "off")
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["method"] == "websocket"
        assert body["delivered"] is True
        # command_id: el mismo id que viajó en el mensaje enviado (el
        # contador es por-dispositivo y su valor absoluto depende de
        # los tests ya ejecutados en este proceso).
        sent = json.loads(ws.sent[-1])
        assert body["command_id"] == sent["command_id"]
        assert '"power.command"' in ws.sent[-1]
    finally:
        connection_manager.disconnect(UID, ws)


async def test_patch_type_switches_power_to_adb_controller(client, admin):
    """Síntoma real: un dispositivo registrado con type viejo ("TV") cae
    al fallback WebSocket (standby_denied sin Device Owner). Tras el PATCH
    a "google_tv", el endpoint usa el controller ADB."""
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    # Registro con type legacy (como quedaba con el dropdown anterior).
    await register_device(client, token, device_type="TV")

    registry = PowerControllerRegistry()
    registry.register(
        "google_tv",
        lambda: FakeController(PowerResult("off", "adb", True, True, "keyevent SLEEP (223)")),
    )
    registry.set_fallback(WebSocketPowerController)
    use_registry(registry)

    # Antes del PATCH: fallback WS, sin canal -> 409.
    response = await power(client, token, "off")
    assert response.status_code == 409

    # PATCH del type (y de paso la MAC).
    patch = await client.patch(
        f"/api/devices/{UID}",
        json={"type": "google_tv", "mac_address": "7c:01:3e:7a:7d:52"},
        headers=bearer(token),
    )
    assert patch.status_code == 200, patch.text
    body = patch.json()
    assert body["type"] == "google_tv"
    assert body["mac_address"] == "7C:01:3E:7A:7D:52"  # normalizada a mayúsculas

    # Después del PATCH: el mismo endpoint usa ADB.
    response = await power(client, token, "off")
    assert response.status_code == 200, response.text
    assert response.json()["method"] == "adb"


async def test_patch_requires_at_least_one_field_and_known_device(client, admin):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)

    empty = await client.patch(
        f"/api/devices/{UID}", json={}, headers=bearer(token)
    )
    assert empty.status_code == 422

    ghost = await client.patch(
        "/api/devices/CAUCE-GHOST",
        json={"type": "google_tv"},
        headers=bearer(token),
    )
    assert ghost.status_code == 404


async def test_power_command_timeout_is_504(client, admin, monkeypatch):
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    registry = PowerControllerRegistry()
    registry.set_fallback(lambda: SleepyController())
    use_registry(registry)
    monkeypatch.setattr(get_settings(), "CAUCE_POWER_TOTAL_TIMEOUT_S", 0.05)

    response = await power(client, token, "on")
    assert response.status_code == 504
    assert "timed out" in response.json()["detail"]


# --- Preferencia WS por capacidad (payload.power_caps del heartbeat) ---

WS_CAPS = {
    "can_wake": True,
    "can_standby": True,
    "device_owner": False,
    "admin_active": True,
}  # TV/box con Device Admin activo: su app puede apagar/encender.


class CountingController(DevicePowerController):
    """Fake del controlador nativo (ADB) que cuenta sus ejecuciones."""

    method = "adb"

    def __init__(self, result: PowerResult):
        self._result = result
        self.calls = 0

    async def turn_on(self, device: Device) -> PowerResult:
        self.calls += 1
        return self._result

    async def turn_off(self, device: Device) -> PowerResult:
        self.calls += 1
        return self._result


class BrokenWS(FakeWS):
    """Canal que revienta al enviar: WS no entrega."""

    async def send_text(self, data: str) -> None:
        raise RuntimeError("canal roto")


async def heartbeat_with_caps(client, uid, caps) -> None:
    response = await client.post(
        f"/api/devices/{uid}/heartbeat",
        json={
            "ip_address": IP,
            "device_state": "active",
            "payload": {"power_caps": caps},
        },
    )
    assert response.status_code == 200, response.text


def tv_registry(result: PowerResult) -> tuple[PowerControllerRegistry, CountingController]:
    registry = PowerControllerRegistry()
    controller = CountingController(result)
    registry.register("google_tv", lambda: controller)
    return registry, controller


async def test_power_tv_with_ws_caps_prefers_websocket_over_adb(client, admin):
    """TV con Device Admin: power.off por su canal WS vivo, sin tocar
    ADB (el controlador nativo del tipo queda como rescate, no corre)."""
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    await heartbeat_with_caps(client, UID, WS_CAPS)
    registry, adb = tv_registry(
        PowerResult("off", "adb", True, True, "keyevent SLEEP (223) enviado")
    )
    use_registry(registry)

    ws = FakeWS()
    await connection_manager.connect(UID, ws)
    try:
        response = await power(client, token, "off")
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["method"] == "websocket"
        assert body["delivered"] is True
        sent = json.loads(ws.sent[-1])
        assert body["command_id"] == sent["command_id"]
        assert '"power.command"' in ws.sent[-1]
        assert '"action": "off"' in ws.sent[-1]
        assert adb.calls == 0  # no fue necesario
    finally:
        connection_manager.disconnect(UID, ws)


async def test_power_tv_with_ws_caps_uses_adb_when_channel_closed(client, admin):
    """Caps reportadas pero canal cerrado: ADB directo (sin 409, sin
    espera): el prefijo WS solo tiene sentido con canal vivo."""
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    await heartbeat_with_caps(client, UID, WS_CAPS)
    registry, adb = tv_registry(
        PowerResult("off", "adb", True, True, "keyevent SLEEP (223) enviado")
    )
    use_registry(registry)

    response = await power(client, token, "off")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["method"] == "adb"
    assert adb.calls == 1


async def test_power_tv_ws_delivery_failure_rescues_adb(client, admin):
    """El WS prefiere pero no entrega (canal roto a mitad): el controlador
    nativo corre como rescate en la misma petición y el resultado lo
    documenta."""
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    await heartbeat_with_caps(client, UID, WS_CAPS)
    registry, adb = tv_registry(
        PowerResult("off", "adb", True, True, "keyevent SLEEP (223) enviado")
    )
    use_registry(registry)

    ws = BrokenWS()
    await connection_manager.connect(UID, ws)
    try:
        response = await power(client, token, "off")
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["method"] == "adb"
        assert body["success"] is True
        assert body["command_id"] is None
        assert body["delivered"] is False
        assert "rescate adb" in body["detail"]
        assert adb.calls == 1
    finally:
        connection_manager.disconnect(UID, ws)


async def test_power_tv_capability_not_declared_uses_adb(client, admin):
    """Caps sin can_standby (sin Device Admin): ni con el canal abierto
    se prefiere WS para apagar; ADB es el camino del tipo."""
    token = await login(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    await register_device(client, token)
    await heartbeat_with_caps(
        client, UID, {**WS_CAPS, "can_standby": False, "admin_active": False}
    )
    registry, adb = tv_registry(
        PowerResult("off", "adb", True, True, "keyevent SLEEP (223) enviado")
    )
    use_registry(registry)

    ws = FakeWS()
    await connection_manager.connect(UID, ws)
    try:
        response = await power(client, token, "off")
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["method"] == "adb"
        assert body["command_id"] is None
        assert adb.calls == 1
        assert ws.sent == []  # el WS ni se intentó
    finally:
        connection_manager.disconnect(UID, ws)

