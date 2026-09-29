# Codex CLI custom provider setup: config.toml, model_providers and wire_api (with a doctor script)

The minimal correct setup for pointing Codex CLI and the Codex IDE extension at a third-party API relay, a self-hosted proxy or a company gateway, as long as it implements `POST /v1/responses`. Also included: `codex-doctor`, a script that tells you exactly which part of your config is wrong, and a small token cost planner.

[![CI](https://github.com/gptzzz/codex-custom-provider/actions/workflows/ci.yml/badge.svg)](https://github.com/gptzzz/codex-custom-provider/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **Checked on 2026-09-29** against the official Codex [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) and the source code of [openai/codex](https://github.com/openai/codex) `rust-v0.158.0` (released 2026-09-28). Every claim is sourced in [docs/sources.md](docs/sources.md). The detailed guides in `docs/` are in Chinese; the config files, scripts and their output are in English.
> 中文版：[README.md](README.md)

<!-- TOC -->
**Contents**

- [TL;DR](#tldr)
- [Minimal config](#minimal-config)
- [How the config is resolved](#how-the-config-is-resolved)
- [Field reference](#field-reference)
- [Which setup to use](#which-setup-to-use)
- [codex-doctor](#codex-doctor)
- [Does my gateway support /v1/responses?](#does-my-gateway-support-v1responses)
- [Common errors](#common-errors)
- [Several providers and profiles](#several-providers-and-profiles)
- [Tested example](#tested-example)
- [Cost planning](#cost-planning)
- [Tests and CI](#tests-and-ci)
- [Upgrading from codex-cost-planner](#upgrading-from-codex-cost-planner)
- [Contributing and license](#contributing-and-license)
<!-- /TOC -->

## TL;DR

1. **Providers only work in the user-level config**: `~/.codex/config.toml`, or `$CODEX_HOME/config.toml` if `CODEX_HOME` is set. Codex ignores `model_provider` and `model_providers` in a project's `.codex/config.toml` and prints `Ignored unsupported project-local config keys` at startup. ([source](https://learn.chatgpt.com/docs/config-file/config-advanced))
2. **Don't use `openai`, `ollama` or `lmstudio` as a provider ID.** They are built-in IDs, and `[model_providers.openai]` makes Codex refuse to start with `model_providers contains reserved built-in provider IDs`. ([source](https://learn.chatgpt.com/docs/config-file/config-reference))
3. **`base_url` stops at `/v1`.** Codex trims trailing slashes and appends `/responses` itself, so `.../v1/responses` or `.../v1/v1` ends in a 404. ([source](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-client/src/provider.rs))
4. **`wire_api` only supports `"responses"`, which is also the default.** `"chat"` was removed in February 2026, so the gateway must implement `POST /v1/responses`. A gateway that only has `/v1/chat/completions` cannot serve Codex. ([source](https://github.com/openai/codex/discussions/7782))
5. **The key comes from an environment variable named by `env_key`.** `env_key` holds the variable's **name**. The key itself never goes into a config file. ([source](https://learn.chatgpt.com/docs/config-file/environment-variables))

## Minimal config

Put this in `~/.codex/config.toml` (Windows: `%USERPROFILE%\.codex\config.toml`) and replace `your-gateway`, the host and the model ID. Full template: [config/config.toml.example](config/config.toml.example).

```toml
# Top-level keys must come before the first [table]
model = "your-model-id"            # an ID from GET <base_url>/models
model_provider = "your-gateway"    # must match the table name below

[model_providers.your-gateway]
name = "Your Gateway"                             # must not be empty
base_url = "https://your-gateway.example.com/v1"  # stop at /v1
env_key = "YOUR_GATEWAY_API_KEY"                  # a variable name, not the key
wire_api = "responses"                            # the only supported value
```

```bash
read -rs YOUR_GATEWAY_API_KEY && export YOUR_GATEWAY_API_KEY   # no echo, not in shell history
bash scripts/codex-doctor.sh                                    # offline checks
bash scripts/codex-doctor.sh --live                             # optional: one real (billed) /responses call
codex exec "Reply with the single word: ready"                  # smoke test without the TUI
```

## How the config is resolved

Codex merges layers in this order, highest first ([Config basics](https://learn.chatgpt.com/docs/config-file/config-basic)):

1. CLI flags and `-c key=value`
2. Project `.codex/config.toml` files (trusted projects only; provider keys are ignored there)
3. The profile file selected with `--profile <name>`: `~/.codex/<name>.config.toml`
4. The user config `~/.codex/config.toml`
5. Cloud-managed defaults, `/etc/codex/config.toml` on Unix, built-in defaults

The request URL is `base_url` with trailing slashes removed, plus `/responses`. The key is sent as `Authorization: Bearer <value of $env_key>`. Codex reads the answer as an SSE stream that must end with a `response.completed` event. Use `/debug-config` inside Codex to see which layer set what, and `/status` for the active model and provider.

## Field reference

Checked against the [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) and [`model-provider-info/src/lib.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/model-provider-info/src/lib.rs) on 2026-09-29.

| Key | Where | Values / default | Notes |
|---|---|---|---|
| `model` | top level | string | Model ID sent to the gateway. IDs differ per gateway; check `GET <base_url>/models` |
| `model_provider` | top level | default `openai` | Must equal the `[model_providers.<id>]` table name exactly |
| `model_reasoning_effort` | top level | e.g. `low` `medium` `high` `xhigh` `max` | Available levels depend on the model and the gateway |
| `name` | provider | string, **required** | `provider name must not be empty` otherwise |
| `base_url` | provider | URL | API root, usually ending in `/v1`. Without it, requests go to `https://api.openai.com/v1` |
| `env_key` | provider | variable name | Missing or blank variable: `Missing environment variable` |
| `env_key_instructions` | provider | string | Appended to that error message |
| `wire_api` | provider | `responses` only (default) | `chat` fails with `` `wire_api = "chat"` is no longer supported `` |
| `stream_idle_timeout_ms` | provider | default `300000` | SSE idle timeout |
| `stream_max_retries` | provider | default `5` | Stream reconnect attempts |
| `request_max_retries` | provider | default `4` | HTTP retry attempts |
| `http_headers` / `env_http_headers` | provider | table | Static headers, or header values read from environment variables |
| `query_params` | provider | table | Extra query parameters, e.g. Azure `api-version` |
| `requires_openai_auth` | provider | default `false` | `true` uses the OpenAI login flow (`auth.json`) instead of `env_key` |
| `experimental_bearer_token` | provider | string | Key stored in the config file; discouraged by the docs |
| `[model_providers.<id>.auth]` | provider sub-table | `command`, `args`, ... | Fetch the token from a command (e.g. the OS keychain). Not combinable with `env_key` |
| `supports_websockets` | provider | default `false` for custom providers | Responses-over-WebSocket; HTTP SSE otherwise |
| `openai_base_url` | top level | URL | Re-points the built-in `openai` provider instead of adding a new one |

Run `codex --strict-config` to turn unknown keys into errors instead of silently ignoring them.

## Which setup to use

| Setup | Key comes from | Use it for |
|---|---|---|
| **Custom provider (recommended)** | the variable named by `env_key` | third-party gateways and relays; self-hosted proxies with their own keys |
| `openai_base_url` | `codex login` credentials (ChatGPT sign-in or an OpenAI API key) | a proxy you control in front of OpenAI, or data residency projects |
| custom provider + `requires_openai_auth = true` | Codex's login cache (`auth.json` / keyring) | not recommended: the gateway key shares the login cache with your ChatGPT sign-in |

The built-in `openai` provider sends your `codex login` credentials (`requires_openai_auth: true` in the source). If `openai_base_url` points at a third-party gateway, those credentials go to that gateway. Use a custom provider for third-party gateways.

## codex-doctor

[scripts/codex-doctor.sh](scripts/codex-doctor.sh) runs on the bash 3.2 that ships with macOS and on Linux. [scripts/codex-doctor.ps1](scripts/codex-doctor.ps1) runs on Windows PowerShell 5.1 and PowerShell 7. Neither touches the network unless asked.

```bash
bash scripts/codex-doctor.sh                     # ~/.codex/config.toml (or $CODEX_HOME)
bash scripts/codex-doctor.sh --profile work      # plus ~/.codex/work.config.toml
bash scripts/codex-doctor.sh --live              # plus GET /models and one streamed POST /responses
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\codex-doctor.ps1 -Live
```

| # | Check | Typical FAIL / WARN |
|---|---|---|
| 1 | `codex --version` | not installed (WARN); older than 0.134.0 (WARN) |
| 2 | config file | missing; `CODEX_HOME` points to a missing directory; saved as `config.toml.txt` |
| 3 | TOML syntax | strict `tomllib` parse on Python 3.11+, otherwise a built-in line parser that catches unterminated strings and duplicate keys |
| 4 | key order | `model` / `model_provider` placed after a `[table]` |
| 5 | `model_provider` | missing; a reserved ID table; `model` missing (WARN) |
| 6 | provider table | table missing or `name` empty; unknown keys such as `api_key` (WARN) |
| 7 | `base_url` | missing; `/v1/v1`; already ends in `/responses`; query string; plain http (WARN); no `/v1` (WARN) |
| 8 | `wire_api` | `chat` or any other value |
| 9 | credentials | variable not set; the key pasted into `env_key`; quotes or whitespace around the key (WARN). Prints only the length |
| 10 | ignored keys | provider keys in a project `.codex/config.toml` (WARN); legacy `profile = "..."` (FAIL) or `[profiles.*]` (WARN) |
| 11a | live `GET /models` | 401/404; configured model not listed (WARN) |
| 11b | live streamed `POST /responses` | 404 (no Responses API); stream does not end with `response.completed`; JSON instead of SSE |

The exit code is the number of FAIL rows. The key reaches curl through stdin, so it never appears in the process list, and response text is scrubbed of the key before it is printed. Fixes for every check: [docs/errors.md](docs/errors.md) (Chinese; the error strings are quoted verbatim).

## Does my gateway support /v1/responses?

```bash
curl -sS -N "https://your-gateway.example.com/v1/responses" \
  -H "Authorization: Bearer $YOUR_GATEWAY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"your-model-id","input":"Reply with the single word: pong","stream":true}'
```

A compatible gateway streams `event:` / `data:` lines and ends with `response.completed`, which carries a string `response.id` and integer `usage` fields. A 404 means it has no Responses API. A stream that stops early makes Codex report `stream disconnected before completion`. More checks, including tool calls: [docs/check-responses-support.md](docs/check-responses-support.md).

## Common errors

| Codex says | Usual cause |
|---|---|
| `unexpected status 401 Unauthorized` | wrong key, or the shell or IDE that launched Codex does not have the variable |
| ``Missing environment variable: `X`.`` | variable not exported, or the key pasted into `env_key` |
| `unexpected status 404 ... url: .../v1/v1/responses` | `/v1` twice, or `base_url` already ends in `/responses` |
| 404 / 405 on `/responses` | the gateway only implements Chat Completions |
| `stream disconnected before completion: ...` | the gateway or a reverse proxy cuts or buffers SSE; long reasoning exceeds the idle timeout |
| Codex still uses OpenAI or asks for a ChatGPT sign-in | provider set in a project config, or top-level keys placed after a table |
| ``Model provider `x` not found`` | `model_provider` does not match the table name |
| `model_providers contains reserved built-in provider IDs` | the table is named `openai`, `ollama` or `lmstudio` |

## Several providers and profiles

Since Codex 0.134.0 a profile is a separate file, `~/.codex/<name>.config.toml`, selected with `codex --profile <name>`. `[profiles.<name>]` tables are no longer read, and a top-level `profile = "..."` is an error ([Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)). Define all providers in the base config and let each profile file switch only `model_provider` and `model`. Examples: [config/profiles/](config/profiles/README.md).

## Tested example

This section lists only gateways the maintainer has tested personally. Requests to list other gateways are not accepted.

[config/gptzzz.toml](config/gptzzz.toml) configures GPTZZZ (`base_url = "https://gptzzz.ai/v1"`, `env_key = "GPTZZZ_API_KEY"`, `wire_api = "responses"`). Results from a live test with a real key on 2026-09-29:

- `GET /v1/models` and `POST /v1/responses` pass.
- Streamed `POST /v1/responses`, the request Codex actually sends (`codex-doctor.sh --live`, check 11b): re-tested on 2026-09-29 with `gpt-5.6-terra`, 9 SSE events ending in `response.completed` with `usage`.
- A wrong key returns 401 with `{"code":"INVALID_API_KEY","message":...}`, not OpenAI's `{"error":{...}}` shape.
- Reasoning effort: `gpt-5.6`, `gpt-5.6-sol` and `gpt-5.6-terra` accept `none` to `max`; `gpt-6-astra` accepts `low` to `max` and rejects `none`; none of them accepts `minimal`. The other models were not tested value by value, so rely on the gateway's error message.
- Embeddings are not offered.

The file also passes every offline doctor check in CI. With your own key, run `codex-doctor.sh --live`, then `codex exec` for an end-to-end check.

## Cost planning

[cost/calculator.py](cost/calculator.py) is a zero-dependency Python CLI. Give it a CSV with one task per row: input, cached input and output tokens, and your own per-million rates. It reports per-task cost, totals by task type and by billing path, and the average cost per accepted task. The sample rates are for demonstration only. See [cost/README.md](cost/README.md).

```bash
python3 cost/calculator.py cost/sample_tasks.csv
```

## Tests and CI

```bash
python3 -m unittest discover -s tests -v   # doctor fixture tests: 12 TOML fixtures, plus --live against a 127.0.0.1 mock gateway
python3 -m unittest discover -s cost -v    # cost calculator
```

CI runs shellcheck, PSScriptAnalyzer and a `tomllib` parse of every TOML example, then runs the tests on Ubuntu (bash 5, mawk, pwsh), macOS (`/bin/bash` 3.2, BSD awk) and Windows (PowerShell 5.1 and 7).

## Upgrading from codex-cost-planner

This repository was `codex-cost-planner`. In v2.0.0 the calculator moved, unchanged, to [cost/](cost/README.md), and the repo became a configuration guide. Old URLs redirect. See [CHANGELOG.md](CHANGELOG.md).

## Contributing and license

Issues and PRs are welcome, especially new error cases with `codex-doctor` output (remove the key first). See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Licensed under [MIT](LICENSE).

---

**Disclosure:** the maintainer runs GPTZZZ, which is why the tested example lists only GPTZZZ. Everything else in this repository applies to any gateway that implements `/v1/responses`. This project is not affiliated with or endorsed by OpenAI. Codex and ChatGPT are OpenAI products and are named here only to describe compatibility.
