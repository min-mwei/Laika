from __future__ import annotations

from pathlib import Path
from typing import Dict, Iterator, Optional, Tuple, Any, List
import json
import os

import requests

from .models import DEFAULT_OPENAI_BASE_URL

DEFAULT_INSTRUCTIONS = "You are a helpful assistant."
CHATGPT_BACKEND_MARKER = "backend-api/codex"
PROMPT_CACHE: Dict[str, str] = {}


class OpenAIError(RuntimeError):
    pass


class OpenAIResponsesClient:
    def __init__(
        self,
        token: str,
        base_url: Optional[str] = None,
        organization: Optional[str] = None,
        project: Optional[str] = None,
        account_id: Optional[str] = None,
        timeout: int = 60,
    ) -> None:
        if not token:
            raise OpenAIError("Missing OpenAI token.")
        self.base_url = (base_url or os.getenv("OPENAI_BASE_URL") or DEFAULT_OPENAI_BASE_URL).rstrip(
            "/"
        )
        self.token = token
        self.organization = organization or _read_env_value("OPENAI_ORGANIZATION")
        self.project = project or _read_env_value("OPENAI_PROJECT")
        self.account_id = account_id
        self.timeout = timeout
        self.session = requests.Session()

    def create_response(
        self,
        model: str,
        input_text: str,
        instructions: Optional[str] = None,
        reasoning_effort: Optional[str] = None,
    ) -> Tuple[Dict[str, Any], str]:
        payload, stream = _build_payload(
            model=model,
            input_text=input_text,
            instructions=instructions,
            reasoning_effort=reasoning_effort,
            stream=False,
            base_url=self.base_url,
        )
        if stream:
            response = self._post("/responses", payload, stream=True)
            text = "".join(_iter_sse_text(response))
            return {"output_text": text}, text
        response = self._post("/responses", payload, stream=False)
        data = response.json()
        return data, _extract_output_text(data)

    def stream_text(
        self,
        model: str,
        input_text: str,
        instructions: Optional[str] = None,
        reasoning_effort: Optional[str] = None,
    ) -> Iterator[str]:
        payload, stream = _build_payload(
            model=model,
            input_text=input_text,
            instructions=instructions,
            reasoning_effort=reasoning_effort,
            stream=True,
            base_url=self.base_url,
        )
        response = self._post("/responses", payload, stream=stream)
        return _iter_sse_text(response)

    def _post(self, path: str, payload: Dict[str, Any], stream: bool) -> requests.Response:
        url = f"{self.base_url.rstrip('/')}/{path.lstrip('/')}"
        response = self.session.post(
            url,
            headers=self._headers(),
            json=payload,
            stream=stream,
            timeout=self.timeout,
        )
        if not response.ok:
            raise OpenAIError(_format_http_error(response))
        return response

    def _headers(self) -> Dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }
        if self.organization:
            headers["OpenAI-Organization"] = self.organization
        if self.project:
            headers["OpenAI-Project"] = self.project
        if self.account_id:
            headers["ChatGPT-Account-ID"] = self.account_id
        return headers


def _build_payload(
    model: str,
    input_text: str,
    instructions: Optional[str],
    reasoning_effort: Optional[str],
    stream: bool,
    base_url: str,
) -> Tuple[Dict[str, Any], bool]:
    is_chatgpt = _is_chatgpt_backend(base_url)
    extra_messages: List[Dict[str, Any]] = []
    resolved_instructions = instructions or DEFAULT_INSTRUCTIONS
    resolved_stream = stream
    store_override: Optional[bool] = None

    if is_chatgpt:
        resolved_instructions = _load_chatgpt_instructions(model)
        resolved_stream = True
        store_override = False
        if instructions:
            extra_messages.append(_developer_message(instructions))

    input_messages = extra_messages + [
        {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": input_text}],
        }
    ]

    payload: Dict[str, Any] = {
        "model": model,
        "input": input_messages,
        "stream": resolved_stream,
        "instructions": resolved_instructions,
    }

    if store_override is not None:
        payload["store"] = store_override

    if reasoning_effort:
        payload["reasoning"] = {"effort": reasoning_effort}
    return payload, resolved_stream


def _iter_sse_text(response: requests.Response) -> Iterator[str]:
    for line in response.iter_lines(decode_unicode=True):
        if isinstance(line, bytes):
            line = line.decode("utf-8", errors="replace")
        if not line:
            continue
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue
        event_type = event.get("type") or event.get("event")
        if event_type == "response.output_text.delta":
            delta = event.get("delta")
            if isinstance(delta, str) and delta:
                yield delta
        elif event_type == "response.error":
            error = event.get("error") or {}
            if isinstance(error, dict):
                message = error.get("message")
            else:
                message = error
            raise OpenAIError(str(message or "Response stream error"))


def _extract_output_text(data: Dict[str, Any]) -> str:
    output_text = data.get("output_text")
    if isinstance(output_text, str):
        return output_text
    output = data.get("output")
    if not isinstance(output, list):
        return ""
    chunks = []
    for item in output:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "message":
            continue
        content = item.get("content") or []
        if not isinstance(content, list):
            continue
        for part in content:
            if isinstance(part, dict) and part.get("type") == "output_text":
                text = part.get("text")
                if isinstance(text, str):
                    chunks.append(text)
    return "".join(chunks)


def _format_http_error(response: requests.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        body = response.text
    return f"OpenAI request failed: {response.status_code} {body}"


def _is_chatgpt_backend(base_url: str) -> bool:
    return CHATGPT_BACKEND_MARKER in base_url


def _load_chatgpt_instructions(model: str) -> str:
    if "codex" in model:
        filename = "gpt-5.2-codex_prompt.md"
    else:
        filename = "gpt_5_2_prompt.md"
    cached = PROMPT_CACHE.get(filename)
    if cached is not None:
        return cached
    path = Path(__file__).resolve().parent / filename
    content = path.read_text(encoding="utf-8")
    PROMPT_CACHE[filename] = content
    return content


def _developer_message(text: str) -> Dict[str, Any]:
    return {
        "type": "message",
        "role": "developer",
        "content": [{"type": "input_text", "text": text}],
    }


def _read_env_value(name: str) -> Optional[str]:
    value = os.getenv(name)
    if value is None:
        return None
    value = value.strip()
    return value or None
