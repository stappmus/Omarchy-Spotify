#!/usr/bin/python3
"""Discover and activate genuine Spotify Connect receivers on the local LAN.

Activation uses spotifyd's owner-only reusable credential, a short-lived
streaming access token, or a receiver-scoped authorization code according to
the receiver's advertised token type. Credentials and derived keys never leave
this process; stdout contains device metadata or a status result only.
"""

from __future__ import annotations

import base64
import ctypes
import hashlib
import hmac
import http.client
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from pathlib import Path
from typing import Any


MAX_RESPONSE_BYTES = 65_536
DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,160}$")
DH_GENERATOR = 2
DH_PRIME = int.from_bytes(bytes([
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2,
    0x21, 0x68, 0xC2, 0x34, 0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1,
    0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74, 0x02, 0x0B, 0xBE, 0xA6,
    0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
    0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D,
    0xF2, 0x5F, 0x14, 0x37, 0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45,
    0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6, 0xF4, 0x4C, 0x42, 0xE9,
    0xA6, 0x3A, 0x36, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
]), "big")
FIXED_IV = bytes([253, 81, 222, 19, 70, 203, 45, 89, 141, 68, 210, 240, 93, 20, 76, 30])
SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
SPOTIFY_DEVICE_AUTH_URL = "https://spclient.wg.spotify.com/device-auth/v1/refresh"
SPOTIFY_DESKTOP_CLIENT_ID = "65b708073fc0480ea92a077233ca87bd"
SONOS_CLIENT_ID = "9b377073ea334637b1406f329ce005de"
SONOS_AVTRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1"
SONOS_RENDERING_CONTROL = "urn:schemas-upnp-org:service:RenderingControl:1"
SONOS_PLAY_MODES = {
    "NORMAL", "REPEAT_ALL", "REPEAT_ONE", "SHUFFLE", "SHUFFLE_NOREPEAT"
}


class ConnectError(Exception):
    pass


def emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")


def receiver_cache_path() -> Path:
    runtime = str(os.environ.get("XDG_RUNTIME_DIR") or "")
    if not runtime.startswith("/"):
        raise ConnectError("invalid runtime directory")
    return Path(runtime) / "omarchy-spotify" / "connect-receivers.json"


def write_receiver_cache(devices: list[dict[str, Any]]) -> None:
    path = receiver_cache_path()
    path.parent.mkdir(mode=0o700, exist_ok=True)
    payload = {
        "schemaVersion": 1,
        "savedAt": int(time.time()),
        "devices": [
            {
                "id": item["id"],
                "address": item["address"],
                "port": item["port"],
                "cpath": item["cpath"],
                "brand": item.get("brand") or "",
                "serviceVersion": item.get("serviceVersion") or "1.0",
            }
            for item in devices
            if item.get("id") and item.get("address") and item.get("port")
        ],
    }
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def read_cached_receiver(device_id: str) -> dict[str, Any] | None:
    try:
        payload = json.loads(receiver_cache_path().read_text(encoding="utf-8"))
        if int(payload.get("schemaVersion") or 0) != 1:
            return None
        saved_at = int(payload.get("savedAt") or 0)
        if saved_at <= 0 or time.time() - saved_at > 300:
            return None
        for item in payload.get("devices") or []:
            if str((item or {}).get("id") or "") != device_id:
                continue
            port = int(item.get("port"))
            if port < 1 or port > 65535:
                return None
            return {
                "id": device_id,
                "address": safe_address(str(item.get("address") or "")),
                "port": port,
                "cpath": endpoint_path(str(item.get("cpath") or "/")),
                "brand": str(item.get("brand") or ""),
                "serviceVersion": str(item.get("serviceVersion") or "1.0"),
            }
    except (OSError, TypeError, ValueError, json.JSONDecodeError, ConnectError):
        return None
    return None


def avahi_unescape(value: str) -> str:
    return re.sub(r"\\([0-9]{3})", lambda match: chr(int(match.group(1))), value)


def safe_address(value: str) -> str:
    address = ipaddress.ip_address(value)
    if address.is_unspecified or address.is_multicast or address.is_loopback:
        raise ConnectError("unsafe receiver address")
    if not (address.is_private or address.is_link_local):
        raise ConnectError("receiver is not on the local network")
    return str(address)


def endpoint_path(cpath: str) -> str:
    value = str(cpath or "/").strip()
    if not value.startswith("/") or ".." in value or len(value) > 256:
        raise ConnectError("invalid receiver path")
    return value


def request_json(
    address: str,
    port: int,
    path: str,
    method: str = "GET",
    fields: dict[str, str] | None = None,
) -> dict[str, Any]:
    address = safe_address(address)
    path = endpoint_path(path)
    body: bytes | None = None
    headers = {"Connection": "close", "Accept": "application/json"}
    if fields is not None:
        body = urllib.parse.urlencode(fields).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Content-Length"] = str(len(body))

    connection = http.client.HTTPConnection(address, port, timeout=5)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ConnectError("receiver response is too large")
        try:
            result = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ConnectError("receiver returned an invalid response") from error
        if not isinstance(result, dict):
            raise ConnectError("receiver returned an invalid response")
        return result
    except (OSError, TimeoutError, http.client.HTTPException) as error:
        raise ConnectError("receiver did not respond") from error
    finally:
        connection.close()


def request_sonos_soap(
    receiver: dict[str, Any],
    service: str,
    control_path: str,
    action: str,
    arguments: dict[str, str],
) -> ElementTree.Element:
    """Issue one fixed, locally scoped Sonos UPnP control request."""
    address = safe_address(str(receiver.get("address") or ""))
    try:
        port = int(receiver.get("port", 0))
    except (TypeError, ValueError) as error:
        raise ConnectError("invalid receiver port") from error
    if port < 1 or port > 65535:
        raise ConnectError("invalid receiver port")

    soap_namespace = "http://schemas.xmlsoap.org/soap/envelope/"
    envelope = ElementTree.Element(
        f"{{{soap_namespace}}}Envelope",
        {f"{{{soap_namespace}}}encodingStyle": "http://schemas.xmlsoap.org/soap/encoding/"},
    )
    body = ElementTree.SubElement(envelope, f"{{{soap_namespace}}}Body")
    action_node = ElementTree.SubElement(body, f"{{{service}}}{action}")
    for key, value in arguments.items():
        ElementTree.SubElement(action_node, key).text = value
    payload = ElementTree.tostring(envelope, encoding="utf-8", xml_declaration=True)

    connection = http.client.HTTPConnection(address, port, timeout=5)
    try:
        connection.request(
            "POST",
            endpoint_path(control_path),
            body=payload,
            headers={
                "Connection": "close",
                "Content-Type": 'text/xml; charset="utf-8"',
                "Content-Length": str(len(payload)),
                "SOAPACTION": f'"{service}#{action}"',
            },
        )
        response = connection.getresponse()
        raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ConnectError("receiver response is too large")
        if response.status < 200 or response.status >= 300:
            raise ConnectError("receiver rejected playback control")
        try:
            root = ElementTree.fromstring(raw)
        except ElementTree.ParseError as error:
            raise ConnectError("receiver returned an invalid response") from error
        if any(node.tag.rsplit("}", 1)[-1] == "Fault" for node in root.iter()):
            raise ConnectError("receiver rejected playback control")
        return root
    except ConnectError:
        raise
    except (OSError, TimeoutError, http.client.HTTPException) as error:
        raise ConnectError("receiver did not respond to playback control") from error
    finally:
        connection.close()


def sonos_volume(receiver: dict[str, Any]) -> int:
    """Read a Sonos player's current master volume from RenderingControl."""
    root = request_sonos_soap(
        receiver,
        SONOS_RENDERING_CONTROL,
        "/MediaRenderer/RenderingControl/Control",
        "GetVolume",
        {"InstanceID": "0", "Channel": "Master"},
    )
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] != "CurrentVolume":
            continue
        value = str(node.text or "").strip()
        if value.isdigit() and int(value) <= 100:
            return int(value)
        break
    raise ConnectError("receiver returned an invalid volume")


def parse_txt(raw: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for key, value in re.findall(r'"?([A-Za-z][A-Za-z0-9_-]*)=([^" ]*)"?', raw):
        values[key.lower()] = avahi_unescape(value)
    return values


def receiver_name(info: dict[str, Any], service_name: str) -> str:
    aliases = info.get("aliases")
    if isinstance(aliases, list):
        for alias in aliases:
            if isinstance(alias, dict) and str(alias.get("name") or "").strip():
                return str(alias["name"]).strip()[:160]
    for value in (info.get("remoteName"), service_name):
        if str(value or "").strip():
            return str(value).strip()[:160]
    return "Spotify Connect device"


AVAHI_BROWSE_TIMEOUT_SECONDS = 8


def browse_spotify_connect() -> str:
    """Return Avahi's parsable `_spotify-connect._tcp` dump.

    `--terminate --resolve` waits until every discovered service is resolved or
    Avahi gives up, which on a busy LAN can exceed a few seconds. Keep stdout
    from a timed-out browse so already-resolved speakers are not discarded.
    """
    command = [
        "avahi-browse", "--resolve", "--parsable", "--terminate",
        "_spotify-connect._tcp",
    ]
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=AVAHI_BROWSE_TIMEOUT_SECONDS,
            check=False,
            env={**os.environ, "LC_ALL": "C.UTF-8"},
        )
        return result.stdout or ""
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        if stdout.strip():
            return stdout
        raise ConnectError("Spotify Connect discovery is unavailable") from error
    except OSError as error:
        raise ConnectError("Spotify Connect discovery is unavailable") from error


def discover_receivers(include_volume: bool = False) -> list[dict[str, Any]]:
    stdout = browse_spotify_connect()

    discovered: dict[str, dict[str, Any]] = {}
    for line in stdout.splitlines():
        if not line.startswith("=;"):
            continue
        parts = line.split(";", 9)
        if len(parts) != 10:
            continue
        service_name = avahi_unescape(parts[3])
        try:
            address = safe_address(parts[7])
            # Avahi often labels an IPv4 A record as IPv6 when AAAA resolve
            # fails. Keep the speaker if the resolved address is IPv4.
            if ipaddress.ip_address(address).version != 4:
                continue
            port = int(parts[8])
            if port < 1 or port > 65535:
                continue
            txt = parse_txt(parts[9])
            cpath = endpoint_path(txt.get("cpath", "/"))
            version = txt.get("version", "1.0")[:32]
            query = urllib.parse.urlencode({"action": "getInfo", "version": version})
            info = request_json(address, port, f"{cpath}?{query}")
            if int(info.get("status", 0)) != 101:
                continue
            device_id = str(info.get("deviceID") or "").strip()
            if not DEVICE_ID_RE.fullmatch(device_id):
                continue
        except (ConnectError, TypeError, ValueError):
            continue

        model = str(info.get("modelDisplayName") or "").strip()[:120]
        brand = str(info.get("brandDisplayName") or "").strip()[:120]
        device = {
            "id": device_id,
            "name": receiver_name(info, service_name),
            "type": str(info.get("deviceType") or "Speaker").strip().title()[:80],
            "brand": brand,
            "model": model,
            "description": " · ".join(value for value in (brand, model) if value),
            "activeUser": bool(str(info.get("activeUser") or "").strip()),
            "tokenType": str(info.get("tokenType") or "default").strip().lower()[:40],
            "clientId": str(info.get("clientID") or "").strip()[:80],
            "localDiscovery": True,
            "activationRequired": True,
            "address": address,
            "port": port,
            "cpath": cpath,
            "serviceVersion": version,
            "publicKey": str(info.get("publicKey") or ""),
        }
        if include_volume and brand.casefold() == "sonos":
            try:
                device["volumePercent"] = sonos_volume(device)
            except ConnectError:
                # Discovery and playback control still work when a receiver
                # temporarily declines the supplemental volume query.
                pass
        discovered[device_id] = device
    return sorted(discovered.values(), key=lambda item: item["name"].casefold())


def find_receiver(device_id: str, attempts: int = 5) -> dict[str, Any] | None:
    """Resolve a receiver, tolerating the brief sleep after a playback transfer."""
    for attempt in range(max(1, attempts)):
        try:
            receiver = next(
                (item for item in discover_receivers() if item["id"] == device_id),
                None,
            )
            if receiver is not None:
                return receiver
        except ConnectError:
            pass
        if attempt + 1 < attempts:
            time.sleep(0.4)
    return None


def request_json_with_retry(
    address: str,
    port: int,
    path: str,
    method: str = "GET",
    fields: dict[str, str] | None = None,
    attempts: int = 5,
) -> dict[str, Any]:
    last_error: ConnectError | None = None
    for attempt in range(max(1, attempts)):
        try:
            return request_json(address, port, path, method, fields)
        except ConnectError as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(0.4)
    raise last_error or ConnectError("receiver did not respond")


def credentials_paths() -> list[Path]:
    state_root = os.environ.get("XDG_STATE_HOME")
    if not state_root:
        state_root = str(Path.home() / ".local" / "state")
    cache_root = os.environ.get("XDG_CACHE_HOME")
    if not cache_root:
        cache_root = str(Path.home() / ".cache")
    durable = Path(state_root) / "omarchy-spotify"
    legacy = Path(cache_root) / "spotifyd"
    return [
        durable / "oauth" / "credentials.json",
        durable / "zeroconf" / "credentials.json",
        legacy / "oauth" / "credentials.json",
        legacy / "zeroconf" / "credentials.json",
    ]


def credentials_path() -> Path:
    paths = credentials_paths()
    return next((path for path in paths if path.exists()), paths[0])


def load_credentials() -> tuple[str, int, bytes]:
    path = credentials_path()
    try:
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise ConnectError("local playback credentials are unavailable")
        if metadata.st_mode & 0o077 or metadata.st_size > 65_536:
            raise ConnectError("local playback credentials are not private")
        payload = json.loads(path.read_text(encoding="utf-8"))
        username = str(payload.get("username") or "")
        auth_type = int(payload.get("auth_type", -1))
        auth_data = base64.b64decode(str(payload.get("auth_data") or ""), validate=True)
    except ConnectError:
        raise
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        raise ConnectError("local playback credentials are unavailable") from error
    if not username or len(username.encode("utf-8")) > 512:
        raise ConnectError("local playback credentials are invalid")
    if auth_type not in (1, 2, 3) or not auth_data or len(auth_data) > 4096:
        raise ConnectError("local playback credentials are invalid")
    return username, auth_type, auth_data


class OpenSslCipher:
    def __init__(self) -> None:
        try:
            self.lib = ctypes.CDLL("libcrypto.so.3")
        except OSError:
            self.lib = ctypes.CDLL("libcrypto.so")
        self.lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
        self.lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
        self.lib.EVP_EncryptInit_ex.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_void_p, ctypes.c_void_p,
        ]
        self.lib.EVP_EncryptInit_ex.restype = ctypes.c_int
        self.lib.EVP_EncryptUpdate.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int),
            ctypes.c_void_p, ctypes.c_int,
        ]
        self.lib.EVP_EncryptUpdate.restype = ctypes.c_int
        self.lib.EVP_EncryptFinal_ex.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int),
        ]
        self.lib.EVP_EncryptFinal_ex.restype = ctypes.c_int
        self.lib.EVP_CIPHER_CTX_set_padding.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.lib.EVP_CIPHER_CTX_set_padding.restype = ctypes.c_int
        for name in ("EVP_aes_128_ecb", "EVP_aes_192_ecb", "EVP_aes_128_ctr"):
            getattr(self.lib, name).restype = ctypes.c_void_p

    def encrypt(self, data: bytes, key: bytes, mode: str, iv: bytes | None = None) -> bytes:
        if mode == "ecb" and len(key) == 24:
            cipher = self.lib.EVP_aes_192_ecb()
        elif mode == "ecb" and len(key) == 16:
            cipher = self.lib.EVP_aes_128_ecb()
        elif mode == "ctr" and len(key) == 16 and iv is not None and len(iv) == 16:
            cipher = self.lib.EVP_aes_128_ctr()
        else:
            raise ConnectError("unsupported cipher parameters")

        context = self.lib.EVP_CIPHER_CTX_new()
        if not context:
            raise ConnectError("could not initialize encryption")
        try:
            key_buffer = ctypes.create_string_buffer(key)
            iv_buffer = ctypes.create_string_buffer(iv) if iv is not None else None
            if self.lib.EVP_EncryptInit_ex(context, cipher, None, key_buffer, iv_buffer) != 1:
                raise ConnectError("could not initialize encryption")
            if mode == "ecb" and self.lib.EVP_CIPHER_CTX_set_padding(context, 0) != 1:
                raise ConnectError("could not configure encryption")
            source = ctypes.create_string_buffer(data)
            output = ctypes.create_string_buffer(len(data) + 32)
            first_length = ctypes.c_int()
            if self.lib.EVP_EncryptUpdate(
                context, output, ctypes.byref(first_length), source, len(data)
            ) != 1:
                raise ConnectError("could not encrypt credentials")
            final_length = ctypes.c_int()
            final_pointer = ctypes.byref(output, first_length.value)
            if self.lib.EVP_EncryptFinal_ex(
                context, final_pointer, ctypes.byref(final_length)
            ) != 1:
                raise ConnectError("could not finalize encryption")
            return output.raw[: first_length.value + final_length.value]
        finally:
            self.lib.EVP_CIPHER_CTX_free(context)


def write_int(value: int, output: bytearray) -> None:
    if value < 0x80:
        output.append(value)
    else:
        output.append(0x80 | (value & 0x7F))
        output.append(value >> 7)


def write_bytes(value: bytes, output: bytearray) -> None:
    write_int(len(value), output)
    output.extend(value)


def int_bytes(value: int) -> bytes:
    return value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")


def build_login_blob(
    username: str,
    auth_type: int,
    auth_data: bytes,
    device_id: str,
    remote_public_key: str,
) -> tuple[str, str]:
    try:
        remote_key = int.from_bytes(base64.b64decode(remote_public_key, validate=True), "big")
    except (ValueError, TypeError) as error:
        raise ConnectError("receiver public key is invalid") from error
    if remote_key <= 1 or remote_key >= DH_PRIME - 1:
        raise ConnectError("receiver public key is invalid")

    username_bytes = username.encode("utf-8")
    blob = bytearray()
    write_int(0x49, blob)
    write_bytes(username_bytes, blob)
    write_int(0x50, blob)
    write_int(auth_type, blob)
    write_int(0x51, blob)
    write_bytes(auth_data, blob)
    zero_count = 16 - (len(blob) % 16) - 1
    blob.extend([0] * zero_count)
    blob.append(zero_count + 1)
    for index in range(len(blob) - 0x11, -1, -1):
        blob[len(blob) - index - 1] ^= blob[len(blob) - index - 0x11]

    secret = hashlib.sha1(device_id.encode("utf-8")).digest()
    derived = hashlib.pbkdf2_hmac("sha1", secret, username_bytes, 0x100, 20)
    blob_key = hashlib.sha1(derived).digest() + bytes([0, 0, 0, 20])
    cipher = OpenSslCipher()
    encrypted_blob = cipher.encrypt(bytes(blob), blob_key, "ecb")
    encoded_blob = base64.b64encode(encrypted_blob)

    private_key = int.from_bytes(os.urandom(95), "big")
    public_key = pow(DH_GENERATOR, private_key, DH_PRIME)
    shared_key = pow(remote_key, private_key, DH_PRIME)
    base_key = hashlib.sha1(int_bytes(shared_key)).digest()[:16]
    encryption_key = hmac.new(base_key, b"encryption", hashlib.sha1).digest()[:16]
    encrypted = cipher.encrypt(encoded_blob, encryption_key, "ctr", FIXED_IV)
    checksum_key = hmac.new(base_key, b"checksum", hashlib.sha1).digest()
    checksum = hmac.new(checksum_key, encrypted, hashlib.sha1).digest()
    signed_blob = base64.b64encode(FIXED_IV + encrypted + checksum).decode("ascii")
    client_key = base64.b64encode(int_bytes(public_key)).decode("ascii")
    return signed_blob, client_key


def validated_access_token(access_token: str) -> str:
    token = str(access_token or "").strip()
    if len(token) < 20 or len(token) > 4096 or any(char.isspace() for char in token):
        raise ConnectError("speaker authorization is unavailable")
    return token


def exchange_access_token(access_token: str, receiver: dict[str, Any]) -> str:
    """Mint the access token addressed to an access-token receiver."""
    token = validated_access_token(access_token)
    client_id = str(receiver.get("clientId") or "").strip()
    device_id = str(receiver.get("id") or "").strip()
    if not re.fullmatch(r"[A-Fa-f0-9]{16,80}", client_id) \
            or not DEVICE_ID_RE.fullmatch(device_id):
        raise ConnectError("receiver authorization is unsupported")

    request = urllib.request.Request(
        SPOTIFY_DEVICE_AUTH_URL,
        data=json.dumps({"clientId": client_id, "deviceId": device_id}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "text/plain;charset=UTF-8",
            "User-Agent": "Spotify/124300420 Win32_x86_64/0 (PC desktop)",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            status_code = response.status
    except urllib.error.HTTPError as error:
        raw = error.read(MAX_RESPONSE_BYTES + 1)
        status_code = error.code
    except (OSError, TimeoutError, urllib.error.URLError) as error:
        raise ConnectError("Spotify receiver authorization did not respond") from error

    if len(raw) > MAX_RESPONSE_BYTES:
        raise ConnectError("Spotify receiver authorization returned too much data")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConnectError("Spotify receiver authorization returned an invalid response") from error
    result = str(payload.get("accessToken") or "") if isinstance(payload, dict) else ""
    if status_code != 200:
        raise ConnectError("Spotify could not authorize this receiver")
    return validated_access_token(result)


def exchange_authorization_code(access_token: str, receiver: dict[str, Any]) -> str:
    """Exchange a desktop streaming token for a receiver-scoped login code."""
    token = validated_access_token(access_token)

    brand = str(receiver.get("brand") or "").strip().casefold()
    audience = SONOS_CLIENT_ID if brand == "sonos" else str(receiver.get("clientId") or "")
    if not re.fullmatch(r"[A-Fa-f0-9]{16,80}", audience):
        raise ConnectError("receiver authorization is unsupported")

    fields = {
        "audience": audience,
        "client_id": SPOTIFY_DESKTOP_CLIENT_ID,
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "requested_token_type": "urn:spotify:params:oauth:authorization_code",
        "resource": "urn:spotify:resources:connect",
        "scope": "streaming",
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "subject_token": token,
    }
    request = urllib.request.Request(
        SPOTIFY_TOKEN_URL,
        data=urllib.parse.urlencode(fields).encode("utf-8"),
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "Spotify/124300420 Win32_x86_64/0 (PC desktop)",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            status_code = response.status
    except urllib.error.HTTPError as error:
        raw = error.read(MAX_RESPONSE_BYTES + 1)
        status_code = error.code
    except (OSError, TimeoutError, urllib.error.URLError) as error:
        raise ConnectError("Spotify receiver authorization did not respond") from error

    if len(raw) > MAX_RESPONSE_BYTES:
        raise ConnectError("Spotify receiver authorization returned too much data")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConnectError("Spotify receiver authorization returned an invalid response") from error
    result = str(payload.get("access_token") or "") if isinstance(payload, dict) else ""
    if status_code != 200 or len(result) < 20 or len(result) > 4096 \
            or any(char.isspace() for char in result):
        raise ConnectError("Spotify could not authorize this receiver")
    return result


def activate_receiver(device_id: str, access_token: str = "") -> dict[str, Any]:
    if not DEVICE_ID_RE.fullmatch(device_id):
        raise ConnectError("invalid receiver id")
    receiver = find_receiver(device_id)
    if receiver is None:
        raise ConnectError("receiver is no longer discoverable")
    username, auth_type, auth_data = load_credentials()

    info_query = urllib.parse.urlencode({
        "action": "getInfo", "version": receiver["serviceVersion"]
    })
    info = request_json_with_retry(
        receiver["address"], receiver["port"], f'{receiver["cpath"]}?{info_query}'
    )
    origin_name = "Omarchy Spotify"
    token_type = str(
        info.get("tokenType") or receiver.get("tokenType") or "default"
    ).strip().lower()
    if token_type not in {"default", "accesstoken", "authorization_code"}:
        token_type = "default"
    fields: dict[str, str] = {}
    attempts = 0
    minted_access_token = False
    while attempts < 7:
        attempts += 1
        if token_type == "authorization_code":
            blob = exchange_authorization_code(access_token, receiver)
            client_key = ""
        elif token_type == "accesstoken":
            # Official ZeroConf access-token login accepts the short-lived
            # streaming token as the blob. Device-scoped minting is only a
            # fallback: Spotify's device-auth reply is not always JSON, and
            # failing that call used to abort before addUser ran.
            if minted_access_token:
                try:
                    blob = exchange_access_token(access_token, receiver)
                except ConnectError:
                    token_type = "default"
                    time.sleep(0.25)
                    continue
            else:
                blob = validated_access_token(access_token)
            client_key = ""
        else:
            public_key = str(info.get("publicKey") or "")
            blob, client_key = build_login_blob(
                username, auth_type, auth_data,
                str(info.get("deviceID") or device_id), public_key
            )
        fields = {
            "action": "addUser",
            "version": str(receiver["serviceVersion"]),
            "tokenType": token_type,
            "clientKey": client_key,
            "loginId": username,
            "userName": username,
            "blob": blob,
            "deviceName": origin_name,
            "deviceId": hashlib.sha1(origin_name.encode("utf-8")).hexdigest(),
        }
        response = request_json_with_retry(
            receiver["address"], receiver["port"], receiver["cpath"], "POST", fields
        )
        status_value = int(response.get("status", 0))
        status_string = str(response.get("statusString") or "")
        if status_value == 101:
            return {"id": device_id, "status": "activated"}
        if status_value == 203 and status_string == "ERROR-INVALID-PUBLICKEY":
            time.sleep(0.25)
            info = request_json_with_retry(
                receiver["address"], receiver["port"], f'{receiver["cpath"]}?{info_query}'
            )
            # A receiver may advertise access-token login before its reusable
            # credential endpoint is awake. Try a device-scoped token first,
            # then the reusable-credential blob.
            if token_type == "accesstoken" and not minted_access_token:
                minted_access_token = True
            elif token_type == "accesstoken":
                token_type = "default"
            continue
        if status_value == 202 and status_string == "ERROR-LOGIN-FAILED" and attempts < 7:
            if token_type == "accesstoken" and not minted_access_token:
                minted_access_token = True
            elif token_type == "accesstoken":
                token_type = "default"
            time.sleep(0.25)
            continue
        raise ConnectError(f"receiver rejected activation ({status_value or 'unknown'})")
    raise ConnectError("receiver activation timed out")


def control_receiver(device_id: str, action: str, value: str = "") -> dict[str, Any]:
    if not DEVICE_ID_RE.fullmatch(device_id):
        raise ConnectError("invalid receiver id")
    receiver = read_cached_receiver(device_id) or find_receiver(device_id, attempts=3)
    if receiver is None:
        raise ConnectError("receiver is no longer discoverable")
    if str(receiver.get("brand") or "").strip().casefold() != "sonos":
        raise ConnectError("local playback control is unsupported for this receiver")

    command = str(action or "").strip().lower()
    raw_value = str(value or "").strip()
    service = SONOS_AVTRANSPORT
    path = "/MediaRenderer/AVTransport/Control"
    soap_action = ""
    arguments: dict[str, str] = {"InstanceID": "0"}
    if command == "play":
        soap_action = "Play"
        arguments["Speed"] = "1"
    elif command == "pause":
        soap_action = "Pause"
    elif command == "next":
        soap_action = "Next"
    elif command == "previous":
        soap_action = "Previous"
    elif command == "seek":
        if not raw_value.isdigit() or int(raw_value) > 86_400:
            raise ConnectError("invalid seek position")
        seconds = int(raw_value)
        soap_action = "Seek"
        arguments["Unit"] = "REL_TIME"
        arguments["Target"] = f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"
    elif command == "mode":
        mode = raw_value.upper()
        if mode not in SONOS_PLAY_MODES:
            raise ConnectError("invalid playback mode")
        soap_action = "SetPlayMode"
        arguments["NewPlayMode"] = mode
    elif command == "volume":
        if not raw_value.isdigit() or int(raw_value) > 100:
            raise ConnectError("invalid volume")
        service = SONOS_RENDERING_CONTROL
        path = "/MediaRenderer/RenderingControl/Control"
        soap_action = "SetVolume"
        arguments["Channel"] = "Master"
        arguments["DesiredVolume"] = str(int(raw_value))
    else:
        raise ConnectError("unsupported playback control")

    request_sonos_soap(receiver, service, path, soap_action, arguments)
    return {"id": device_id, "status": "controlled", "action": command}


def self_test() -> None:
    cipher = OpenSslCipher()
    plaintext = bytes.fromhex("00112233445566778899aabbccddeeff")
    key_128 = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    key_192 = bytes.fromhex("000102030405060708090a0b0c0d0e0f1011121314151617")
    if cipher.encrypt(plaintext, key_128, "ecb").hex() != "69c4e0d86a7b0430d8cdb78070b4c55a":
        raise ConnectError("AES-128 self-test failed")
    if cipher.encrypt(plaintext, key_192, "ecb").hex() != "dda97ca4864cdfe06eaf70a0ec0d7191":
        raise ConnectError("AES-192 self-test failed")
    ctr_key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
    ctr_iv = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
    ctr_plaintext = bytes.fromhex("6bc1bee22e409f96e93d7e117393172a")
    if cipher.encrypt(ctr_plaintext, ctr_key, "ctr", ctr_iv).hex() != "874d6191b620e3261bef6864990db6ce":
        raise ConnectError("AES-CTR self-test failed")


def main() -> int:
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    try:
        if command == "discover":
            devices = discover_receivers(include_volume=True)
            try:
                write_receiver_cache(devices)
            except (OSError, ConnectError):
                pass
            for item in devices:
                for private_field in (
                    "address", "port", "cpath", "serviceVersion", "publicKey", "clientId"
                ):
                    item.pop(private_field, None)
            emit({"schemaVersion": 1, "devices": devices})
            return 0
        if command == "activate":
            device_id = sys.stdin.readline(256).strip()
            access_token = sys.stdin.readline(4097).strip()
            emit(activate_receiver(device_id, access_token))
            return 0
        if command == "control":
            device_id = sys.stdin.readline(256).strip()
            action = sys.stdin.readline(65).strip()
            value = sys.stdin.readline(129).strip()
            emit(control_receiver(device_id, action, value))
            return 0
        if command == "self-test":
            self_test()
            emit({"status": "ok"})
            return 0
        return 2
    except ConnectError as error:
        # Error messages are intentionally generic and cannot contain response
        # payloads, credentials, encrypted blobs, keys, or endpoint URLs.
        sys.stderr.write(str(error)[:240] + "\n")
        return 6
    except Exception:
        sys.stderr.write("Spotify Connect helper failed\n")
        return 6


if __name__ == "__main__":
    raise SystemExit(main())
