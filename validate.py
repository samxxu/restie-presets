#!/usr/bin/env python3
"""Validate catalog.yaml against the schema RESTie enforces at fetch time.

RESTie refuses a catalog it cannot understand, so a bad entry here breaks every
user's `restie presets update`. Running this before pushing catches that.

This mirrors `parse_catalog` in the RESTie core repository (src/presets.rs).
When the core's rules change, update both.

Usage:  python3 validate.py
Needs:  pip install pyyaml
"""

from __future__ import annotations

import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "catalog.yaml")

# Keep in sync with SCHEMA_VERSION / MIN_SCHEMA_VERSION in the core.
SCHEMA_VERSION = 1
MIN_SCHEMA_VERSION = 1

TOP_LEVEL_FIELDS = {"schema_version", "scripts", "presets"}
PRESET_FIELDS = {"name", "display_name", "openapi_url", "base_url", "auth", "description"}
AUTH_FIELDS = {"type", "token_env", "header", "prefix", "command", "env"}
AUTH_TYPES = {"bearer_token", "api_key", "custom_header", "script", "none"}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

# A key that names a credential must be fed from the user's environment, never
# from a committed literal. Non-secret defaults (a service name, a region) are
# legitimately literals, so only credential-looking keys are hard errors.
CREDENTIAL_KEY_RE = re.compile(
    r"(SECRET|TOKEN|PASSWORD|PASSWD|ACCESS_KEY|KEY_ID|CREDENTIAL|_KEY$|_KEY_)", re.I
)


def is_http_url(value: object) -> bool:
    return isinstance(value, str) and value.strip() != "" and value.startswith(
        ("http://", "https://")
    )


def check_script_path(where: str, path: object, errors: list[str]) -> None:
    if not isinstance(path, str) or not path.strip():
        errors.append(f"{where}: script path is required")
        return
    if os.path.isabs(path) or ".." in path.split("/"):
        errors.append(f"{where}: unsafe path {path!r} (must be relative, no '..')")


def check_preset(
    index: int, preset: object, errors: list[str], notes: list[str], seen: set[str]
) -> str | None:
    """Validate one preset. Returns its auth.command, if any."""
    where = f"presets[{index}]"
    if not isinstance(preset, dict):
        errors.append(f"{where}: must be a mapping")
        return None

    name = preset.get("name")
    if not isinstance(name, str) or not name.strip():
        errors.append(f"{where}: 'name' is required")
    else:
        where = f"preset {name!r}"
        if name in seen:
            errors.append(f"{where}: duplicate name")
        seen.add(name)
        if not NAME_RE.match(name):
            errors.append(f"{where}: name must match {NAME_RE.pattern}")

    for field in sorted(set(preset) - PRESET_FIELDS):
        errors.append(f"{where}: unknown field {field!r} (core rejects unknown fields)")

    for field in ("display_name", "description"):
        value = preset.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{where}: '{field}' is required and must be non-empty")

    auth = preset.get("auth")
    auth_type = "none"
    if auth is not None:
        if not isinstance(auth, dict):
            errors.append(f"{where}: 'auth' must be a mapping")
            auth = {}
        else:
            for field in sorted(set(auth) - AUTH_FIELDS):
                errors.append(f"{where}: unknown auth field {field!r}")
            auth_type = auth.get("type")
            if auth_type not in AUTH_TYPES:
                errors.append(
                    f"{where}: auth.type must be one of {sorted(AUTH_TYPES)}, got {auth_type!r}"
                )

    # URL rules mirror the core: raw-only presets need the API host, spec-based
    # ones need the spec location.
    base_url = preset.get("base_url")
    openapi_url = preset.get("openapi_url")
    if auth_type == "script":
        if not is_http_url(base_url):
            errors.append(f"{where}: raw-only preset needs an http(s) 'base_url'")
    else:
        if not is_http_url(openapi_url):
            errors.append(f"{where}: needs an http(s) 'openapi_url'")
    if base_url is not None and not is_http_url(base_url):
        errors.append(f"{where}: 'base_url' must be an http(s) URL")
    if isinstance(openapi_url, str) and any(ch.isspace() for ch in openapi_url):
        errors.append(f"{where}: 'openapi_url' must not contain whitespace")

    command: str | None = None
    if auth_type == "script" and isinstance(auth, dict):
        command = auth.get("command")
        check_script_path(f"{where} auth.command", command, errors)
        if isinstance(command, str) and command.strip():
            if not os.path.isfile(os.path.join(HERE, command)):
                errors.append(f"{where}: auth.command {command!r} does not exist in this repo")

        env = auth.get("env")
        if env is not None and not isinstance(env, dict):
            errors.append(f"{where}: 'auth.env' must be a mapping")
        elif isinstance(env, dict):
            for key, value in env.items():
                if not isinstance(key, str) or not key.strip():
                    errors.append(f"{where}: auth.env has an empty variable name")
                if not isinstance(value, str):
                    errors.append(f"{where}: auth.env[{key!r}] must be a string")
                elif value.startswith("${") and value.endswith("}"):
                    pass  # indirection: resolved from the user's environment
                elif CREDENTIAL_KEY_RE.search(str(key)):
                    errors.append(
                        f"{where}: auth.env[{key!r}] names a credential, so it must be a "
                        f"${{VAR}} indirection, never a committed literal"
                    )
                else:
                    notes.append(
                        f"{where}: auth.env[{key!r}] is the literal default {value!r} "
                        f"(fine for non-secret config; make sure it is not one)"
                    )

    return command


def main() -> int:
    errors: list[str] = []
    notes: list[str] = []

    with open(CATALOG, encoding="utf-8") as fh:
        try:
            catalog = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            print(f"catalog.yaml is not valid YAML: {exc}")
            return 1

    if not isinstance(catalog, dict):
        print("catalog.yaml must be a mapping")
        return 1

    for field in sorted(set(catalog) - TOP_LEVEL_FIELDS):
        errors.append(f"unknown top-level field {field!r} (core rejects unknown fields)")

    version = catalog.get("schema_version")
    if not isinstance(version, int) or isinstance(version, bool):
        errors.append(f"schema_version must be an integer, got {version!r}")
    elif not MIN_SCHEMA_VERSION <= version <= SCHEMA_VERSION:
        errors.append(
            f"schema_version must be in {MIN_SCHEMA_VERSION}..={SCHEMA_VERSION}, got {version}"
        )

    scripts = catalog.get("scripts") or []
    if not isinstance(scripts, list):
        errors.append("'scripts' must be a list")
        scripts = []
    for script in scripts:
        check_script_path("scripts manifest", script, errors)
        if isinstance(script, str) and script.strip():
            if not os.path.isfile(os.path.join(HERE, script)):
                errors.append(f"scripts manifest: {script!r} does not exist in this repo")

    presets = catalog.get("presets")
    if not isinstance(presets, list) or not presets:
        errors.append("'presets' must be a non-empty list")
        return report(errors, notes, version)

    seen: set[str] = set()
    for index, preset in enumerate(presets):
        command = check_preset(index, preset, errors, notes, seen)
        if command and command not in scripts:
            errors.append(
                f"presets[{index}]: auth.command {command!r} is not listed in the "
                f"top-level 'scripts' manifest"
            )

    return report(errors, notes, version)


def report(errors: list[str], notes: list[str], version: object) -> int:
    if errors:
        print(f"catalog.yaml is INVALID ({len(errors)} problem(s)):")
        for err in errors:
            print(f"  - {err}")
        return 1
    for note in notes:
        print(f"note: {note}")
    print(f"catalog.yaml is valid (schema_version {version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
