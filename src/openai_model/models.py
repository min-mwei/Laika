DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"
DEFAULT_CHATGPT_BASE_URL = "https://chatgpt.com/backend-api/codex"

DEFAULT_API_MODEL = "gpt-5.2"
DEFAULT_CHATGPT_MODEL = "gpt-5.2-codex"

GPT5_2_REASONING_LEVELS = ["low", "medium", "high", "xhigh"]
GPT5_2_BASE_MODELS = ["gpt-5.2", "gpt-5.2-codex"]


def _expand_reasoning_variants(models: list[str]) -> list[str]:
    expanded: list[str] = []
    for base in models:
        expanded.append(base)
        for level in GPT5_2_REASONING_LEVELS:
            expanded.append(f"{base}-{level}")
    return expanded


GPT5_2_MODELS = _expand_reasoning_variants(GPT5_2_BASE_MODELS)
