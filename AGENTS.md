# AGENTS.md

Guidance for AI coding assistants maintaining **restie-presets**, the platform
catalog for [RESTie](https://github.com/samxxu/restie).

This repository is **data, not code**. The RESTie binary ships no presets of its
own; it fetches [`catalog.yaml`](catalog.yaml) from here and turns each entry into
a site config. Adding, re-pointing or removing a platform is a one-file change
here — no RESTie release required.

## Repository layout

```
catalog.yaml             the platform list — the only file normally edited
auth/                    signing scripts referenced by the catalog
  aws-sigv4.sh           AWS Signature v4
  aliyun-sign.sh         Alibaba Cloud (HMAC-SHA1)
  tencent-sign.sh        Tencent Cloud (TC3-HMAC-SHA256)
validate.py              schema check (mirrors the core's parse_catalog)
.github/workflows/       validate.yml: runs validate.py + bash -n on every push
README.md                consumer + author docs
```

## Validation

Always run the validator after editing the catalog (each preset listed in
`auth/` and every script is covered):

```bash
python3 validate.py     # requires: pip install pyyaml
```

CI runs the same check plus `bash -n` on every `auth/*.sh` on push to `main`.
A catalog that fails `validate.py` will also be refused by the core.

## How to add or change a platform

1. Edit `catalog.yaml`.
2. Add any referenced signing script under `auth/` and list it in the top-level
   `scripts:` manifest.
3. Run `python3 validate.py` and fix until clean.
4. Commit and push. Users pick the change up with `restie presets update`.

### Spec-based platforms

Most platforms publish an OpenAPI spec and authenticate with a token/header.
Give them an `openapi_url`; the generated command tree comes from the spec.

```yaml
- name: example
  display_name: Example API
  openapi_url: https://example.com/openapi.json
  description: Example platform API
  auth:
    type: bearer_token
    token_env: EXAMPLE_TOKEN
```

### Raw-only platforms

Some platforms have no single unified spec and sign each request with a script
(AWS, Alibaba Cloud, Tencent Cloud). Give them a `base_url` instead of an
`openapi_url`; `restie generate <name>` writes site + auth only (no commands),
and the platform is called in raw mode.

```yaml
- name: example-raw
  display_name: Example (signed)
  base_url: https://api.example.com
  description: Example platform, request-signing auth
  auth:
    type: script
    command: auth/example-sign.sh
    env:
      EXAMPLE_KEY_ID: ${EXAMPLE_KEY_ID}
      EXAMPLE_KEY_SECRET: ${EXAMPLE_KEY_SECRET}
```

## Rules the catalog must obey

These mirror `parse_catalog` in the core; a violation means the catalog is
refused rather than misread:

- `schema_version` is required and must be a supported version. Raise it only
  for changes an older build would read wrongly.
- Preset `name` is unique and matches a short lowercase id (`[a-z0-9-]+`).
- `display_name` and `description` are required, non-empty strings.
- Spec-based presets need an http(s) `openapi_url`; raw-only (script-auth) ones
  need an http(s) `base_url`.
- **No unknown fields** — in the file or in any entry.
- Script paths are relative, and must not be absolute or contain `..`. A preset
  can never point the client outside the presets cache.
- `auth.env` values are `${VAR}` indirections (variable names, resolved from the
  user's environment at request time) — **never a secret value**.

## Hard rules

- **Nothing in this repo may contain a credential.** `validate.py` rejects an
  `auth.env` value that is not a `${VAR}` indirection, and the core only ever
  reads the user's environment. Do not commit tokens, keys, or secrets.
- **Signing scripts are executed as-is** at request time. Keep them strict
  (`set -euo pipefail`), self-contained, and free of anything that writes
  outside the process.
- Keep `catalog.yaml` and its comments aligned with the schema header at the top
  of the file; the header is the human spec for every field.

## When editing

1. Only touch `catalog.yaml` (+ `auth/`) — `validate.py` and the workflow are
   stable machinery.
2. Always run `python3 validate.py` before finishing.
3. If you add a script, make sure it passes `bash -n`.