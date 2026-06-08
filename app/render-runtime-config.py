#!/usr/bin/env python3
"""Render runtime-only placeholders after instance values are available."""

from pathlib import Path


APP_DIR = Path(__file__).resolve().parent
ENV_FILE = APP_DIR / ".env"


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    return values


env = parse_env(ENV_FILE)
replacements = {
    "__VLLM_MODEL__": env["VLLM_MODEL"],
}

for relative_path in ("coder-template/main.tf",):
    path = APP_DIR / relative_path
    text = path.read_text()
    for old, new in replacements.items():
        text = text.replace(old, new)
    path.write_text(text)
