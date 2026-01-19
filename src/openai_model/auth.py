from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum
import base64
import json
import os
from pathlib import Path
from typing import Any, Dict, Optional

import requests

AUTH_FILE_NAME = "auth.json"
OPENAI_API_KEY_ENV_VAR = "OPENAI_API_KEY"
CODEX_API_KEY_ENV_VAR = "CODEX_API_KEY"
TOKEN_REFRESH_INTERVAL_DAYS = 8
REFRESH_TOKEN_URL = "https://auth.openai.com/oauth/token"
REFRESH_TOKEN_URL_OVERRIDE_ENV_VAR = "CODEX_REFRESH_TOKEN_URL_OVERRIDE"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
ISSUER_BASE_URL = "https://auth.openai.com"
ISSUER_BASE_URL_OVERRIDE_ENV_VAR = "CODEX_ISSUER_BASE_URL_OVERRIDE"


class AuthError(RuntimeError):
    pass


class AuthMode(str, Enum):
    API_KEY = "api_key"
    CHATGPT = "chatgpt"


@dataclass
class IdTokenInfo:
    raw_jwt: str
    email: Optional[str] = None
    chatgpt_plan_type: Optional[str] = None
    chatgpt_account_id: Optional[str] = None


@dataclass
class TokenData:
    id_token: IdTokenInfo
    access_token: str
    refresh_token: str
    account_id: Optional[str] = None


@dataclass
class AuthDotJson:
    openai_api_key: Optional[str] = None
    tokens: Optional[TokenData] = None
    last_refresh: Optional[datetime] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "AuthDotJson":
        openai_api_key = data.get("OPENAI_API_KEY")
        tokens_data = data.get("tokens")
        tokens = None
        if isinstance(tokens_data, dict):
            id_token_raw = tokens_data.get("id_token") or ""
            tokens = TokenData(
                id_token=parse_id_token(id_token_raw),
                access_token=tokens_data.get("access_token") or "",
                refresh_token=tokens_data.get("refresh_token") or "",
                account_id=tokens_data.get("account_id"),
            )
        last_refresh = _parse_datetime(data.get("last_refresh"))
        return cls(
            openai_api_key=openai_api_key,
            tokens=tokens,
            last_refresh=last_refresh,
        )

    def to_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {"OPENAI_API_KEY": self.openai_api_key}
        if self.tokens:
            payload["tokens"] = {
                "id_token": self.tokens.id_token.raw_jwt,
                "access_token": self.tokens.access_token,
                "refresh_token": self.tokens.refresh_token,
                "account_id": self.tokens.account_id,
            }
        if self.last_refresh:
            payload["last_refresh"] = _format_datetime(self.last_refresh)
        return payload


class AuthStore:
    def __init__(self, root: Optional[Path] = None, auth_path: Optional[Path] = None) -> None:
        if auth_path is not None:
            path = Path(auth_path).expanduser()
            self.path = path
            self.root = path.parent
        else:
            self.root = root or Path.cwd()
            self.path = self.root / AUTH_FILE_NAME

    def load(self) -> Optional[AuthDotJson]:
        if not self.path.exists():
            return None
        with self.path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return AuthDotJson.from_dict(data)

    def save(self, auth: AuthDotJson) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(auth.to_dict(), indent=2, ensure_ascii=True)
        tmp_path = self.path.with_suffix(self.path.suffix + ".tmp")
        with tmp_path.open("w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.write("\n")
        _restrict_permissions(tmp_path)
        os.replace(tmp_path, self.path)

    def login_with_api_key(self, api_key: str) -> None:
        auth = AuthDotJson(openai_api_key=api_key, tokens=None, last_refresh=None)
        self.save(auth)

    def update_tokens(
        self,
        id_token: Optional[str],
        access_token: Optional[str],
        refresh_token: Optional[str],
    ) -> AuthDotJson:
        auth = self.load()
        if not auth or not auth.tokens:
            raise AuthError("Token data is not available.")
        if id_token:
            auth.tokens.id_token = parse_id_token(id_token)
        if access_token:
            auth.tokens.access_token = access_token
        if refresh_token:
            auth.tokens.refresh_token = refresh_token
        auth.last_refresh = datetime.now(timezone.utc)
        self.save(auth)
        return auth


@dataclass
class AuthSession:
    mode: AuthMode
    store: AuthStore
    auth: AuthDotJson

    def get_bearer_token(self) -> str:
        if self.mode == AuthMode.API_KEY:
            if not self.auth.openai_api_key:
                raise AuthError("OPENAI_API_KEY is missing.")
            return self.auth.openai_api_key
        if not self.auth.tokens:
            raise AuthError("Token data is not available.")
        if not self.auth.last_refresh:
            raise AuthError("Token data is missing last_refresh.")
        if _needs_refresh(self.auth.last_refresh):
            self._refresh_tokens()
        return self.auth.tokens.access_token

    def _refresh_tokens(self) -> None:
        if not self.auth.tokens:
            raise AuthError("Token data is not available.")
        response = _refresh_token(self.auth.tokens.refresh_token)
        updated = self.store.update_tokens(
            id_token=response.get("id_token"),
            access_token=response.get("access_token"),
            refresh_token=response.get("refresh_token"),
        )
        self.auth = updated


def load_auth_session(
    root: Optional[Path] = None, auth_path: Optional[Path] = None
) -> AuthSession:
    store = AuthStore(root=root, auth_path=auth_path)
    codex_api_key = _read_env_value(CODEX_API_KEY_ENV_VAR)
    if codex_api_key:
        auth = AuthDotJson(openai_api_key=codex_api_key)
        return AuthSession(mode=AuthMode.API_KEY, store=store, auth=auth)
    openai_api_key = _read_env_value(OPENAI_API_KEY_ENV_VAR)
    if openai_api_key:
        auth = AuthDotJson(openai_api_key=openai_api_key)
        return AuthSession(mode=AuthMode.API_KEY, store=store, auth=auth)
    auth = store.load()
    if not auth:
        raise AuthError(f"{AUTH_FILE_NAME} not found in {store.root}")
    if auth.openai_api_key:
        return AuthSession(mode=AuthMode.API_KEY, store=store, auth=auth)
    if auth.tokens:
        try:
            exchanged = _exchange_id_token_for_api_key(auth.tokens.id_token.raw_jwt)
        except AuthError:
            return AuthSession(mode=AuthMode.CHATGPT, store=store, auth=auth)
        if exchanged:
            auth.openai_api_key = exchanged
            store.save(auth)
            return AuthSession(mode=AuthMode.API_KEY, store=store, auth=auth)
        return AuthSession(mode=AuthMode.CHATGPT, store=store, auth=auth)
    raise AuthError(f"{AUTH_FILE_NAME} is missing OPENAI_API_KEY or tokens.")


def parse_id_token(raw_jwt: str) -> IdTokenInfo:
    if not raw_jwt:
        return IdTokenInfo(raw_jwt="")
    parts = raw_jwt.split(".")
    if len(parts) != 3:
        return IdTokenInfo(raw_jwt=raw_jwt)
    payload_b64 = parts[1]
    try:
        payload_bytes = _b64url_decode(payload_b64)
        claims = json.loads(payload_bytes.decode("utf-8"))
    except (ValueError, json.JSONDecodeError):
        return IdTokenInfo(raw_jwt=raw_jwt)
    email = claims.get("email") if isinstance(claims, dict) else None
    auth_claims = {}
    if isinstance(claims, dict):
        auth_claims = claims.get("https://api.openai.com/auth") or {}
    return IdTokenInfo(
        raw_jwt=raw_jwt,
        email=email,
        chatgpt_plan_type=_dict_get_str(auth_claims, "chatgpt_plan_type"),
        chatgpt_account_id=_dict_get_str(auth_claims, "chatgpt_account_id"),
    )


def _b64url_decode(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def _parse_datetime(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _format_datetime(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def _needs_refresh(last_refresh: datetime) -> bool:
    cutoff = datetime.now(timezone.utc) - timedelta(days=TOKEN_REFRESH_INTERVAL_DAYS)
    return last_refresh < cutoff


def _refresh_token(refresh_token: str) -> Dict[str, Any]:
    url = os.getenv(REFRESH_TOKEN_URL_OVERRIDE_ENV_VAR, REFRESH_TOKEN_URL)
    payload = {
        "client_id": CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email",
    }
    try:
        response = requests.post(url, json=payload, timeout=60)
    except requests.RequestException as exc:
        raise AuthError(f"Failed to refresh token: {exc}") from exc
    if response.status_code == 200:
        return response.json()
    if response.status_code == 401:
        raise AuthError(_classify_refresh_token_failure(response.text))
    message = _extract_error_message(response.text)
    raise AuthError(
        f"Failed to refresh token: {response.status_code} {message}".strip()
    )


def _exchange_id_token_for_api_key(id_token: str) -> Optional[str]:
    if not id_token:
        return None
    issuer = os.getenv(ISSUER_BASE_URL_OVERRIDE_ENV_VAR, ISSUER_BASE_URL).rstrip("/")
    payload = {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": CLIENT_ID,
        "requested_token": "openai-api-key",
        "subject_token": id_token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
    }
    try:
        response = requests.post(
            f"{issuer}/oauth/token",
            data=payload,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=60,
        )
    except requests.RequestException as exc:
        raise AuthError(f"API key exchange failed: {exc}") from exc
    if not response.ok:
        message = response.text.strip()
        raise AuthError(
            f"API key exchange failed: {response.status_code} {message}".strip()
        )
    data = response.json()
    access_token = data.get("access_token")
    return access_token if isinstance(access_token, str) and access_token else None


def _classify_refresh_token_failure(body: str) -> str:
    code = _extract_refresh_token_error_code(body)
    normalized = code.lower() if code else ""
    if normalized == "refresh_token_expired":
        return (
            "Your access token could not be refreshed because your refresh token has expired. "
            "Please log out and sign in again."
        )
    if normalized == "refresh_token_reused":
        return (
            "Your access token could not be refreshed because your refresh token was already used. "
            "Please log out and sign in again."
        )
    if normalized == "refresh_token_invalidated":
        return (
            "Your access token could not be refreshed because your refresh token was revoked. "
            "Please log out and sign in again."
        )
    return "Your access token could not be refreshed. Please log out and sign in again."


def _extract_refresh_token_error_code(body: str) -> Optional[str]:
    if not body.strip():
        return None
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return None
    if isinstance(data, dict):
        error_value = data.get("error")
        if isinstance(error_value, dict):
            code = error_value.get("code")
            if isinstance(code, str):
                return code
        if isinstance(error_value, str):
            return error_value
        code = data.get("code")
        if isinstance(code, str):
            return code
    return None


def _extract_error_message(body: str) -> str:
    if not body.strip():
        return ""
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return body.strip()
    if isinstance(data, dict):
        message = data.get("error") or data.get("message")
        if isinstance(message, dict):
            nested = message.get("message")
            return nested if isinstance(nested, str) else body.strip()
        if isinstance(message, str):
            return message
    return body.strip()


def _read_env_value(name: str) -> Optional[str]:
    value = os.getenv(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


def _dict_get_str(data: Dict[str, Any], key: str) -> Optional[str]:
    value = data.get(key)
    return value if isinstance(value, str) else None


def _restrict_permissions(path: Path) -> None:
    try:
        os.chmod(path, 0o600)
    except OSError:
        return
