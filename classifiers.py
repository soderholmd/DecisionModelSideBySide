"""Classifiers for Azure OpenAI and Microsoft-Decision-1.

Each classifier returns a dict with the chosen label, the request that was sent
("prompt"), and the time spent inside the model call (model_ms).
"""

import functools
import json
import os
import random
import re
import time

import requests

from pricing import estimate_cost, mock_cost

DECISION_PATH = "/providers/microsoft/v1/systemone"
TOKEN_SCOPE = "https://cognitiveservices.azure.com/.default"
QUESTION_NAME = "category"

# Reuse connections across calls, like the OpenAI client does.
_session = requests.Session()


def _env(name, default=""):
    return os.getenv(name, default).strip()


REQUIRED_SETTINGS = {
    "openai": ["AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_DEPLOYMENT"],
    # DECISION_API_KEY is optional: without it, Microsoft Entra ID (DefaultAzureCredential) is used.
    "decision": ["DECISION_ENDPOINT", "DECISION_DEPLOYMENT"],
}


def missing_settings(model):
    """Names of required settings that are not configured for a model (none in mock mode)."""
    if mock_enabled():
        return []
    return [n for n in REQUIRED_SETTINGS[model] if not _env(n)]


def mock_enabled():
    return _env("MOCK_MODELS").lower() in ("1", "true", "yes")


def build_openai_messages(text, labels):
    label_lines = "\n".join(f"- {l['name']}: {l.get('description') or l['name']}" for l in labels)
    system = (
        "You are a classifier. Classify the user's text into exactly one of the following labels.\n"
        f"{label_lines}\n\n"
        "Respond with only the label name, exactly as written above, and nothing else."
    )
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": text},
    ]


def format_openai_prompt(messages):
    return "\n\n".join(f"[{m['role']}]\n{m['content']}" for m in messages)


def match_label(answer, labels):
    """Map a free-form model answer back to one of the label names."""
    answer = (answer or "").strip()
    names = [l["name"] for l in labels]
    for name in names:
        if answer.lower() == name.lower():
            return name
    answer = answer.strip("\"'.`").strip()
    for name in sorted(names, key=len, reverse=True):
        if name.lower() in answer.lower():
            return name
    return answer or "(no answer)"


def label_keys(labels):
    """Build unique, identifier-style keys for Decision 'choice' criteria, mapped to label names."""
    keys = {}
    for l in labels:
        base = re.sub(r"[^a-z0-9]+", "_", l["name"].lower()).strip("_") or "label"
        key, n = base, 2
        while key in keys:
            key, n = f"{base}_{n}", n + 1
        keys[key] = l["name"]
    return keys


def build_decision_request(text, labels):
    keys = label_keys(labels)
    descriptions = {l["name"]: l.get("description") or l["name"] for l in labels}
    return {
        "model": _env("DECISION_DEPLOYMENT"),
        "state": text,
        "questions": {
            QUESTION_NAME: {
                "type": "choice",
                "instructions": "Classify the text into the single best matching category.",
                "criteria": {k: descriptions[name] for k, name in keys.items()},
            }
        },
    }, keys


def _mock(text, labels):
    time.sleep(random.uniform(0.2, 0.6))
    words = set(re.findall(r"[a-z]+", text.lower()))
    best = max(labels, key=lambda l: len(words & set(re.findall(r"[a-z]+", (l["name"] + " " + l.get("description", "")).lower()))))
    return best["name"]


@functools.lru_cache(maxsize=1)
def _openai_client():
    from azure.identity import get_bearer_token_provider
    from openai import AzureOpenAI

    api_key = _env("AZURE_OPENAI_API_KEY")
    if api_key:
        authentication = {"api_key": api_key}
    else:
        authentication = {
            "azure_ad_token_provider": get_bearer_token_provider(_entra_credential(), TOKEN_SCOPE)
        }
    return AzureOpenAI(
        azure_endpoint=_env("AZURE_OPENAI_ENDPOINT"),
        api_version=_env("AZURE_OPENAI_API_VERSION", "2024-10-21"),
        **authentication,
    )


def classify_openai(text, labels):
    messages = build_openai_messages(text, labels)
    prompt = format_openai_prompt(messages)
    client = None if mock_enabled() else _openai_client()
    start = time.perf_counter()
    if client is None:
        label = _mock(text, labels)
        cost = mock_cost()
    else:
        resp = client.chat.completions.create(
            model=_env("AZURE_OPENAI_DEPLOYMENT"),
            messages=messages,
        )
        label = match_label(resp.choices[0].message.content, labels)
        usage = getattr(resp, "usage", None)
        if usage is not None:
            details = getattr(usage, "prompt_tokens_details", None)
            usage = {
                "input_tokens": usage.prompt_tokens,
                "output_tokens": usage.completion_tokens,
                "cached_input_tokens": getattr(details, "cached_tokens", 0) or 0,
                "cache_write_tokens": getattr(details, "cache_write_tokens", 0) or 0,
            }
        cost = estimate_cost("openai", getattr(resp, "model", None), usage)
    model_ms = (time.perf_counter() - start) * 1000
    return {"label": label, "prompt": prompt, "model_ms": model_ms, **cost}


@functools.lru_cache(maxsize=1)
def _entra_credential():
    from azure.identity import DefaultAzureCredential

    return DefaultAzureCredential()


def _decision_headers():
    """Use an API key when configured, otherwise a Microsoft Entra ID bearer token."""
    headers = {"Content-Type": "application/json"}
    api_key = _env("DECISION_API_KEY")
    if api_key:
        headers["api-key"] = api_key
    else:
        token = _entra_credential().get_token(TOKEN_SCOPE).token
        headers["Authorization"] = "Bearer " + token
    return headers


def parse_decision_response(data, keys):
    """Map a decision response back to (label name, confidence).

    A choice answer looks like {"type": "choice", "choice": <key>, "probabilities": {...}, "confidence": 0.9};
    the model can also decline to decide with {"type": "refusal"}.
    """
    answer = (data.get("answers") or {}).get(QUESTION_NAME) or {}
    if answer.get("type") == "refusal":
        return "(refused)", None
    choice = answer.get("choice")
    return keys.get(choice, choice or "(no answer)"), answer.get("confidence")


def classify_decision(text, labels):
    body, keys = build_decision_request(text, labels)
    prompt = json.dumps(body, indent=2)
    confidence = None
    headers = None if mock_enabled() else _decision_headers()
    start = time.perf_counter()
    if headers is None:
        label = _mock(text, labels)
        cost = mock_cost()
    else:
        url = _env("DECISION_ENDPOINT").rstrip("/") + DECISION_PATH
        resp = _session.post(
            url,
            headers=headers,
            json=body,
            timeout=60,
        )
        resp.raise_for_status()
        data = resp.json()
        label, confidence = parse_decision_response(data, keys)
        cost = estimate_cost("decision", data.get("model"), data.get("usage"))
    model_ms = (time.perf_counter() - start) * 1000
    return {"label": label, "prompt": prompt, "model_ms": model_ms, "confidence": confidence, **cost}


CLASSIFIERS = {"openai": classify_openai, "decision": classify_decision}
