# 事实来源与核对记录

本仓库关于 Codex 的每一条具体说法，都能在下表找到出处。**最近一次核对：2026-09-29**，当时 Codex 的最新发布是 `rust-v0.158.0`（2026-09-28）。

官方文档在 2026 年迁到了 `learn.chatgpt.com/docs/...`。旧地址 `developers.openai.com/codex/...` 会用 HTTP 308 永久跳转到新地址，比如 `developers.openai.com/codex/config-reference` 跳到 `learn.chatgpt.com/docs/config-file/config-reference`。

每次发版前都要重新核对。流程见 [CONTRIBUTING.md](../CONTRIBUTING.md#发版前核对)。

## 配置行为

| 说法 | 出处 |
|---|---|
| 用户级配置在 `~/.codex/config.toml`；项目级 `.codex/config.toml` 只在信任的项目里加载 | [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic) |
| 配置的优先级：命令行 > 项目级 > profile 文件 > 用户级 > 云端下发 > `/etc/codex/config.toml` > 内置默认值 | [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic) |
| CLI 和 IDE 扩展共用同一套配置层 | [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic)、[Developer settings](https://learn.chatgpt.com/docs/developer-settings?surface=ide) |
| 项目级配置会忽略 `openai_base_url`、`chatgpt_base_url`、`model_provider`、`model_providers`、`profile`、`profiles`、`notify`、`otel` 等键，并在启动时提示 | [Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)；源码 [`config/src/loader/mod.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/config/src/loader/mod.rs)（`PROJECT_LOCAL_CONFIG_DENYLIST`） |
| 内置 provider ID `openai`、`ollama`、`lmstudio` 是保留的，不能覆盖 | [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)；源码 [`config/src/config_toml.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/config/src/config_toml.rs)（`validate_reserved_model_provider_ids`） |
| 自定义 provider 的 `name` 不能为空 | 源码 [`config/src/config_toml.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/config/src/config_toml.rs)（`validate_model_providers`） |
| `wire_api` 只支持 `responses`，省略时也是它；`chat` 会报错 | [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)；源码 [`model-provider-info/src/lib.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/model-provider-info/src/lib.rs)（`CHAT_WIRE_API_REMOVED_ERROR`） |
| Chat Completions 支持：2025-12-09 宣布弃用，2026 年 2 月移除 | [openai/codex#7782](https://github.com/openai/codex/discussions/7782) |
| 请求地址 = `base_url` 去掉末尾的 `/` 再加 `/responses` | 源码 [`codex-client/src/provider.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-client/src/provider.rs)（`url_for_path`）、[`codex-api/src/endpoint/responses.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-api/src/endpoint/responses.rs) |
| 没写 `base_url` 时，默认发往 `https://api.openai.com/v1`（用 ChatGPT 登录时是 ChatGPT 的后端） | 源码 [`model-provider-info/src/lib.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/model-provider-info/src/lib.rs)（`to_api_provider`） |
| `env_key` 指定的变量不存在或为空（去掉首尾空白后）时，报错 `Missing environment variable` | 源码 `model-provider-info/src/lib.rs`（`api_key`）、[`protocol/src/error.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/protocol/src/error.rs)（`EnvVarError`） |
| 默认值：`stream_idle_timeout_ms` 300000，`stream_max_retries` 5，`request_max_retries` 4 | [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)；源码 `model-provider-info/src/lib.rs` |
| `requires_openai_auth`：为 `true` 时走 OpenAI 登录流程，凭据存进 `auth.json`；为 `false`（默认）时 key 从 `env_key` 读取 | 源码 `model-provider-info/src/lib.rs` 中该字段的注释 |
| 内置 `openai` provider 使用 `codex login` 的凭据（`requires_openai_auth: true`），可以用 `openai_base_url` 改地址 | [Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)；源码 `model-provider-info/src/lib.rs`（`create_openai_provider`） |
| `[model_providers.<id>.auth]` 用命令获取 token，不能和 `env_key` 同时使用；默认 `timeout_ms` 5000、`refresh_interval_ms` 300000 | [Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)、[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) |
| `experimental_bearer_token` 不推荐使用，应该用 `env_key` | [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) |
| 从 0.134.0 起，profile 是单独的文件 `~/.codex/<名字>.config.toml`；`[profiles.x]` 不再读取，顶层 `profile = "x"` 会报错 | [Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)；源码 [`core/src/config/mod.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/core/src/config/mod.rs) |
| `CODEX_HOME` 默认是 `~/.codex`，设置了就必须是已经存在的目录；CLI 和 IDE 扩展都读它 | [Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)；源码 [`utils/home-dir/src/lib.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/utils/home-dir/src/lib.rs) |
| Windows 的配置目录是用户目录下的 `.codex`（`%USERPROFILE%\.codex`） | 源码 `utils/home-dir/src/lib.rs`（`dirs::home_dir()` 加上 `.codex`） |
| `--strict-config` 遇到不认识的键会报错；`/debug-config` 显示各配置层；`-m` / `--model`、`-p` / `--profile`、`-c` / `--config` | [Developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)、[Developer settings](https://learn.chatgpt.com/docs/developer-settings?surface=ide) |
| 调试日志：`RUST_LOG=debug codex -c log_dir=./.codex-log`，文件是 `codex-tui.log` | [Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables) |

## 流式响应（SSE）

| 说法 | 出处 |
|---|---|
| Codex 用 `POST /responses` 加 `Accept: text/event-stream` 请求流式响应 | 源码 [`codex-api/src/endpoint/responses.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-api/src/endpoint/responses.rs) |
| 事件类型取自 `data:` 里 JSON 的 `type` 字段；流必须以 `response.completed` 结束（`response.incomplete` 只有在原因是 `interrupted` 时可以） | 源码 [`codex-api/src/sse/responses.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-api/src/sse/responses.rs) |
| `response.completed` 需要字符串类型的 `response.id`；`usage` 需要整数的 `input_tokens`、`output_tokens`、`total_tokens` | 同上（`ResponseCompleted`、`ResponseCompletedUsage`） |
| 报错原文 `stream closed before response.completed`、`idle timeout waiting for SSE`、`stream disconnected before completion: ...` | 同上；[`protocol/src/error.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/protocol/src/error.rs) |
| HTTP 错误的格式是 `unexpected status <code>: <body>, url: <url>` | [`protocol/src/error.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/protocol/src/error.rs)（`UnexpectedResponseError`） |

## 安装与平台

| 说法 | 出处 |
|---|---|
| 安装：`curl -fsSL https://chatgpt.com/codex/install.sh \| sh`、`irm https://chatgpt.com/codex/install.ps1 \| iex`、`npm install -g @openai/codex`、`brew install --cask codex` | [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)、[Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables) |
| 独立安装脚本默认装到 `~/.local/bin`（Windows 是 `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin`） | [Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables) |
| WSL：在 WSL 里安装，仓库放在 Linux 主目录下；WSL1 从 0.115 起不再支持 | [WSL](https://learn.chatgpt.com/docs/windows/wsl) |
| IDE 扩展的 `chatgpt.*` 设置不写进 `config.toml`；`chatgpt.runCodexInWindowsSubsystemForLinux` | [Developer settings](https://learn.chatgpt.com/docs/developer-settings?surface=ide) |
| 从 GUI 启动的 VS Code 会读取 shell 配置文件里的环境 | [VS Code FAQ: Resolving shell environment fails](https://code.visualstudio.com/docs/supporting/faq) |

## 计费（cost-planning.md）

| 说法 | 出处 |
|---|---|
| Codex 包含在 ChatGPT Free、Go、Plus、Pro、Business、Edu、Enterprise 方案中；API key 路径按 API 价格计费、没有云端功能 | [Codex Pricing](https://learn.chatgpt.com/docs/pricing) |
| 「Model choice, context, reasoning, tool use, retrieval, and caching all affect usage」 | [Codex Pricing](https://learn.chatgpt.com/docs/pricing) 的 FAQ |
| API key 的用量通过 OpenAI Platform 账户按标准 API 价格结算 | [Authentication](https://learn.chatgpt.com/docs/auth) |
| API 单价 | [API Pricing](https://developers.openai.com/api/docs/pricing) |

本仓库不写任何套餐额度或价格数字。

## 已实测示例（config/gptzzz.toml）

| 说法 | 出处 |
|---|---|
| GPTZZZ 的 `GET /v1/models`、`POST /v1/responses` 通过；错误 key 返回 401 和 `{"code":"INVALID_API_KEY",...}`；推理档位的范围；模型 ID 列表；不提供 Embeddings | 维护者 2026-09-29 用真实 key 实测，没有第三方来源。你用自己的 key 跑 `codex-doctor.sh --live` 可以复现其中的接口检查 |
| 流式 `POST /v1/responses` 以 `response.completed` 结束 | 复测记录 2026-09-29：`codex-doctor.sh --config config/gptzzz.toml --live --model gpt-5.6-terra`，11 PASS、1 WARN（本机没有装 codex）、0 FAIL。11a：HTTP 200，19 个模型，`gpt-5.6-terra` 在列表里；11b：HTTP 200，9 个 SSE 事件，以 `response.completed` 结束，usage 输入 4393、输出 5 token。`codex exec` 端到端没有测 |
