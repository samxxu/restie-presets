# restie-presets

Platform presets for [RESTie](https://github.com/samxxu/restie), the transparent
RESTful API client.

This repository is **data**, not code. The RESTie binary contains no presets of
its own: it fetches [`catalog.yaml`](catalog.yaml) from here and turns each entry
into a site config. Adding, re-pointing or removing a platform is therefore a
one-file change here, with no RESTie release involved.

That split exists because platform APIs and their auth change far more often than
the client does. Alibaba Cloud and Tencent Cloud signing, for instance, should
never require shipping a new binary.

## Consuming it

```bash
restie presets update     # fetches catalog.yaml + the scripts it references
restie presets            # browse what arrived
```

`presets update` downloads this repository's `catalog.yaml` plus every script in
the `scripts:` manifest, validates them, and caches them under
`~/.config/restie/presets/`. RESTie also does this automatically, once, the first
time it needs presets on a machine where nothing is cached yet.

Point RESTie at a fork or a branch with `--repo`:

```bash
restie presets update --repo https://raw.githubusercontent.com/<user>/restie-presets/<branch>
export RESTIE_PRESETS_REPO=https://raw.githubusercontent.com/<user>/restie-presets/<branch>  # default
```

Local overrides (your own private presets) live in
`~/.config/restie/presets/catalog.local.yaml` and always win over this catalog;
`presets update` never touches that file.

## Layout

```
catalog.yaml             the platform list — the only file you normally edit
auth/                    signing scripts referenced by the catalog
  aws-sigv4.sh           AWS Signature v4
  aliyun-sign.sh         Alibaba Cloud (HMAC-SHA1)
  tencent-sign.sh        Tencent Cloud (TC3-HMAC-SHA256)
validate.py              schema check, mirrors the core's rules
.github/workflows/       runs validate.py + a bash syntax check on every push
```

## Adding or changing a platform

1. Edit `catalog.yaml`.
2. Run `python3 validate.py` (needs `pip install pyyaml`).
3. Commit and push. Users pick it up with `restie presets update`.

### Spec-based platforms

Most platforms publish an OpenAPI spec and authenticate with a token or header.
Those need an `openapi_url`; the command tree is generated from the spec.

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
rather than a bearer token. Those need a `base_url` instead of an `openapi_url`;
`restie generate <name>` writes a site config with no commands, and the platform
is called in raw mode.

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

Add the script under `auth/`, list it in the top-level `scripts:` manifest, and
remember it is executed as-is at request time.

## Rules the core enforces

`validate.py` mirrors `parse_catalog` in the core; a catalog that violates any of
these is refused rather than misread:

- `schema_version` must be a version the client understands.
- Preset `name` is unique, and `display_name` / `description` are non-empty.
- Spec-based presets need an http(s) `openapi_url`; raw-only ones need an http(s)
  `base_url`.
- Unknown fields are errors, in the file and in each entry.
- Script paths are relative and must not contain `..`. A preset can never point
  the client at an absolute path or outside the presets cache.
- `auth.env` carries variable **names**, with `${VAR}` indirections as values.
  Never commit a secret value here: values are resolved from the user's own
  environment at request time.

## Note on secrets

Nothing in this repository should ever contain a credential. `validate.py`
rejects an `auth.env` value that is not a `${VAR}` indirection, but the real
guarantee is that the core only ever reads the user's environment.

## License

MIT
