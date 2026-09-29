# Codex 中转 / 自定义 provider 常见报错对照

每条都按「现象 → 原因 → 验证 → 修复」写。报错原文取自 [openai/codex](https://github.com/openai/codex) `rust-v0.158.0` 的源码，不同版本的措辞可能略有差别。核对日期 2026-09-29。

先跑一遍自检，大多数问题它会直接指出是哪一项：

```bash
bash scripts/codex-doctor.sh            # 离线检查
bash scripts/codex-doctor.sh --live     # 另外真实请求 /models 和 /responses（会产生很小的计费）
```

| doctor 检查项 | 对应的小节 |
|---|---|
| 2 配置文件 | [CODEX_HOME 指向的目录不存在](#codex-home)、[Windows：config.toml.txt 与编码](#windows-txt) |
| 3 TOML 语法 | [顶层键写在了表后面](#toml-key-order) |
| 4 顶层键的位置 | [顶层键写在了表后面](#toml-key-order) |
| 5 model_provider | [保留的 provider ID](#reserved-id)、[项目级配置不生效](#project-config-ignored) |
| 6 provider 表 | [Model provider not found](#provider-not-found)、[provider name must not be empty](#provider-name-empty) |
| 7 base_url | [404：/v1/v1 或 /responses/responses](#404-v1-v1) |
| 8 wire_api | [wire_api = "chat" is no longer supported](#wire-api-chat) |
| 9 凭据 | [Missing environment variable](#missing-environment-variable)、[401 Unauthorized](#401) |
| 10 被忽略的键 | [项目级配置不生效](#project-config-ignored)、[旧版 profile 写法](#legacy-profile) |
| 11a live /models | [401 Unauthorized](#401)、[模型不存在](#model-not-found) |
| 11b live /responses | [/responses 返回 404](#responses-404)、[stream disconnected before completion](#stream-disconnected) |

## 目录

1. [401 Unauthorized](#401)
2. [Missing environment variable](#missing-environment-variable)
3. [404：/v1/v1 或 /responses/responses](#404-v1-v1)
4. [/responses 返回 404 或 405：网关没有 Responses API](#responses-404)
5. [wire_api = "chat" is no longer supported](#wire-api-chat)
6. [stream disconnected before completion](#stream-disconnected)
7. [模型不存在（model not found）](#model-not-found)
8. [项目级配置不生效](#project-config-ignored)
9. [顶层键写在了表后面](#toml-key-order)
10. [Model provider not found](#provider-not-found)
11. [保留的 provider ID](#reserved-id)
12. [provider name must not be empty](#provider-name-empty)
13. [旧版 profile 写法](#legacy-profile)
14. [CODEX_HOME 指向的目录不存在](#codex-home)
15. [Windows：config.toml.txt 与编码](#windows-txt)

---

<a id="401"></a>
## 1. 401 Unauthorized

**现象**

```text
unexpected status 401 Unauthorized: {...}, url: https://your-gateway.example.com/v1/responses
```

响应体的格式取决于网关。有的是 OpenAI 的 `{"error":{"message":...}}`，有的是 `{"code":"...","message":...}`。

**原因**（按出现频率排序）

1. 启动 Codex 的那个进程看不到这个环境变量。比如变量只在另一个终端里 `export` 过；写进了 `~/.zshrc` 但没有重开终端；VS Code 是在设置变量之前启动的。
2. key 本身有问题：复制时多了引号、空格或换行；key 属于另一家网关，或者属于另一个分组；key 过期或被停用。
3. provider 设了 `requires_openai_auth = true`。这时 Codex 走的是 `codex login` 的凭据，不读 `env_key`，发出去的就不是网关的 key。
4. 没写 `base_url`。请求被发到了 `https://api.openai.com/v1`，OpenAI 自然不认识网关的 key。

**验证**

```bash
bash scripts/codex-doctor.sh          # 第 9 项：变量是否可见、长度多少、是否带引号或空格
bash scripts/codex-doctor.sh --live   # 11a：网关是否接受这个 key
```

**修复**

- 在启动 Codex 的同一个 shell 里设置变量，确认 `printenv YOUR_GATEWAY_API_KEY >/dev/null && echo set` 输出 `set`。IDE 的情况见 [vscode-extension.md](vscode-extension.md)。
- 去掉 key 两边的引号和空白，重新复制一次。
- 删掉 `requires_openai_auth = true`，改用 `env_key`。
- 补上 `base_url`。

---

<a id="missing-environment-variable"></a>
## 2. Missing environment variable

**现象**

```text
Missing environment variable: `YOUR_GATEWAY_API_KEY`.
```

如果 provider 里写了 `env_key_instructions`，这段文字会附在报错后面。

**原因**

- 变量没有设置，或者只设了普通 shell 变量，没有 `export`（子进程看不到）。
- 变量的值是空字符串或者只有空白。Codex 会先去掉首尾空白再判断是否为空。
- `env_key` 里直接填成了 key 本身，比如 `env_key = "sk-..."`。Codex 会去找一个名字叫 `sk-...` 的环境变量。

**验证**

```bash
bash scripts/codex-doctor.sh   # 第 9 项。如果 env_key 看起来像 key 本身，会提示并只显示它的长度
```

**修复**

`env_key` 只写变量名，key 放进这个变量：

```toml
env_key = "YOUR_GATEWAY_API_KEY"
```

```bash
read -rs YOUR_GATEWAY_API_KEY && export YOUR_GATEWAY_API_KEY
```

如果不小心把 key 写进过配置文件，建议到网关后台作废这个 key 再换一个新的，尤其是配置文件曾经被提交到 Git 的情况。

---

<a id="404-v1-v1"></a>
## 3. 404：/v1/v1 或 /responses/responses

**现象**

```text
unexpected status 404 Not Found: ..., url: https://your-gateway.example.com/v1/v1/responses
```

注意报错里的 `url:`，它就是 Codex 实际请求的地址。

**原因**

Codex 的拼接方式是：`base_url` 去掉末尾的 `/`，再加上 `/responses`（[`codex-client/src/provider.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-client/src/provider.rs)）。所以：

| base_url | 实际请求 |
|---|---|
| `https://gw.example.com/v1` | `https://gw.example.com/v1/responses`（正确） |
| `https://gw.example.com/v1/` | `https://gw.example.com/v1/responses`（正确，末尾的 `/` 会被去掉） |
| `https://gw.example.com/v1/v1` | `https://gw.example.com/v1/v1/responses`（404） |
| `https://gw.example.com/v1/responses` | `https://gw.example.com/v1/responses/responses`（404） |
| `https://gw.example.com` | `https://gw.example.com/responses`（多数网关 404） |

**验证**：doctor 第 7 项会打印拼好的地址。

**修复**：`base_url` 写到 API 根目录，大多数网关是 `https://<域名>/v1`。

---

<a id="responses-404"></a>
## 4. /responses 返回 404 或 405：网关没有 Responses API

**现象**：`GET /models` 正常，`POST /responses` 返回 404、405 或 `Invalid URL (POST /v1/responses)`。

**原因**：网关只实现了 `/v1/chat/completions`。Codex 从 2026 年 2 月起只支持 Responses API（[openai/codex#7782](https://github.com/openai/codex/discussions/7782)），这类网关没法直接给 Codex 用。

**验证**

```bash
bash scripts/codex-doctor.sh --live   # 11b
```

或者按 [check-responses-support.md](check-responses-support.md) 用 curl 手动测一次。

**修复**：换一个支持 `/v1/responses` 的网关，或者问网关方有没有单独的 Responses 端点。把 `wire_api` 改成 `chat` 解决不了问题，见下一节。

---

<a id="wire-api-chat"></a>
## 5. wire_api = "chat" is no longer supported

**现象**：Codex 启动时报错：

```text
`wire_api = "chat"` is no longer supported.
How to fix: set `wire_api = "responses"` in your provider config.
More info: https://github.com/openai/codex/discussions/7782
```

**原因**：老教程里的 `wire_api = "chat"`。Chat Completions 支持在 2025-12 宣布弃用，2026 年 2 月移除。现在 `wire_api` 唯一合法的值是 `responses`，省略时默认也是它（[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)）。

**修复**：改成 `wire_api = "responses"`，并确认网关支持 `/v1/responses`（见上一节）。

---

<a id="stream-disconnected"></a>
## 6. stream disconnected before completion

**现象**：TUI 先显示 `Reconnecting... 1/5` 这类提示，重试用完后报错：

```text
stream disconnected before completion: stream closed before response.completed
stream disconnected before completion: idle timeout waiting for SSE
```

**原因**

Codex 请求 `/responses` 时带 `stream: true`，读的是 SSE 流，只有收到 `response.completed` 事件才算这一轮结束（源码 [`codex-api/src/sse/responses.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-api/src/sse/responses.rs)）。

- `stream closed before response.completed`：连接已经关闭，但没收到 `response.completed`。常见的情况有三种：网关把 Chat Completions 转成 Responses 格式时漏发了最后一个事件；网关前面的反向代理把长连接切断了；网关没理会 `stream: true`，直接返回了一个 JSON。
- `idle timeout waiting for SSE`：超过 `stream_idle_timeout_ms`（默认 300000 毫秒，即 5 分钟）没有收到任何数据。常见于长时间推理时网关不发心跳，或者中间有代理在缓冲数据。

**验证**

```bash
bash scripts/codex-doctor.sh --live   # 11b 会检查最后一个事件是不是 response.completed、是否带 id 和 usage
```

还可以打开 Codex 的调试日志（[Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)）：

```bash
RUST_LOG=debug codex -c log_dir=./.codex-log
tail -F ./.codex-log/codex-tui.log
```

**修复**

- 11b 失败：问题出在网关或它前面的代理，要找网关方解决。如果是你自己部署的网关，在 nginx 里对这条路径关掉缓冲、调大读超时，比如 `proxy_buffering off;` 和 `proxy_read_timeout 600s;`。nginx 的 `proxy_read_timeout` 默认只有 60 秒。
- 11b 通过，但长任务仍然断：适当调大空闲超时和重连次数：

```toml
[model_providers.your-gateway]
# ...
stream_idle_timeout_ms = 600000
stream_max_retries = 10
```

- 公司网络或本地代理会切断长连接的，换一个网络环境验证一下。

---

<a id="model-not-found"></a>
## 7. 模型不存在（model not found）

**现象**：HTTP 400 或 404，响应体里有 `model_not_found`、`does not exist`、`invalid model` 之类的字样。

**原因**：`model` 填的 ID 不在这个网关（或这个 key 所在分组）的模型列表里。常见的情况有：照抄了别人教程里的模型名；拼写或大小写不对；没写 `model`，Codex 用了自己的默认模型名。

**验证**

```bash
bash scripts/codex-doctor.sh --live   # 11a 会列出网关返回的模型 ID，并检查配置里的模型在不在其中
```

**修复**：把 `model` 改成列表里的 ID。临时换模型可以用 `codex -m <id>`，或者在 TUI 里输入 `/model`。

---

<a id="project-config-ignored"></a>
## 8. 项目级配置不生效

**现象**：provider 写在项目的 `.codex/config.toml` 里，Codex 却还在用 OpenAI 或 ChatGPT 登录。启动时可能看到：

```text
Ignored unsupported project-local config keys in /path/to/repo/.codex/config.toml: model_provider, model_providers. If you want these settings to apply, manually set them in your user-level config.toml.
```

**原因**：项目目录里的内容可能来自别人，所以项目级配置不允许决定凭据发往哪里。`openai_base_url`、`chatgpt_base_url`、`model_provider`、`model_providers`、`profile`、`profiles`、`notify`、`otel` 等键在项目级配置里都会被忽略（[Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)）。另外，没被信任的项目会整个跳过 `.codex/` 目录。

**验证**：doctor 第 10 项会从当前目录往上找到 Git 根目录，列出每个 `.codex/config.toml` 里被忽略的键。在 Codex 里输入 `/debug-config` 可以看到实际加载了哪些配置层。

**修复**：provider 相关的键移到 `~/.codex/config.toml`（或 `$CODEX_HOME/config.toml`）。项目级配置只留 `model`、`model_reasoning_effort` 这类不涉及凭据的键。

---

<a id="toml-key-order"></a>
## 9. 顶层键写在了表后面

**现象**：看起来什么都写对了，Codex 却还在用默认 provider，或者弹出 ChatGPT 登录。

**原因**：TOML 规定，`[表]` 之后的每一个键都属于这个表，直到出现下一个表头为止。下面这种写法里，`model_provider` 实际上变成了 `model_providers.your-gateway.model_provider`，顶层根本没有 `model_provider`：

```toml
[model_providers.your-gateway]
name = "Your Gateway"
base_url = "https://your-gateway.example.com/v1"

model_provider = "your-gateway"   # 错：这一行属于上面的表
```

往已有的 `config.toml` 末尾追加内容时，最容易出这个错。

**验证**：doctor 第 4 项会报出行号。也可以用 `codex --strict-config` 启动，Codex 会把不认识的键当成错误报出来。

**修复**：`model`、`model_provider` 等顶层键移到文件开头，写在第一个 `[表]` 之前。

---

<a id="provider-not-found"></a>
## 10. Model provider not found

**现象**

```text
Model provider `your-gateway` not found
```

**原因**：`model_provider` 的值和 `[model_providers.<id>]` 的表名不一致，比如一个写 `gateway`，另一个写 `my-gateway`。表名区分大小写。另一种可能：表写在了项目级配置里，被忽略了。

**修复**：让两处完全一致：

```toml
model_provider = "your-gateway"
[model_providers.your-gateway]
```

---

<a id="reserved-id"></a>
## 11. 保留的 provider ID

**现象**：Codex 拒绝启动：

```text
model_providers contains reserved built-in provider IDs: `openai`. Built-in providers cannot be overridden. Rename your custom provider (for example, `openai-custom`).
```

**原因**：`openai`、`ollama`、`lmstudio` 是内置 provider 的 ID，自定义表不能用（[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)）。

**修复**：把表名和 `model_provider` 改成你自己的 ID，比如 `my-gateway`。如果你只是想让内置的 OpenAI provider 走一个代理，用顶层的 `openai_base_url`。它会带上 `codex login` 的凭据，只适合你自己控制的代理，见 [README 的「三种接法怎么选」](../README.md#三种接法怎么选)。

---

<a id="provider-name-empty"></a>
## 12. provider name must not be empty

**现象**

```text
model_providers.your-gateway: provider name must not be empty
```

**原因**：自定义 provider 必须有非空的 `name`。

**修复**：加上 `name = "Your Gateway"`。

---

<a id="legacy-profile"></a>
## 13. 旧版 profile 写法

**现象**（任选其一）

```text
legacy `profile = "work"` config is no longer supported; use `--profile work` with `work.config.toml` instead
--profile `work` cannot be used while ~/.codex/config.toml contains legacy `profile = "work"` or `[profiles.work]` config; ...
```

**原因**：从 Codex 0.134.0 起，profile 必须是单独的文件 `~/.codex/<名字>.config.toml`。`config.toml` 里的 `[profiles.<名字>]` 表不再读取，顶层的 `profile = "..."` 会直接报错（[Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)）。

**修复**：把 `[profiles.work]` 里的键原样挪到 `~/.codex/work.config.toml`，写成顶层键；删掉原来的表和 `profile = "work"`；以后用 `codex --profile work` 选中。示例见 [config/profiles/](../config/profiles/README.md)。

---

<a id="codex-home"></a>
## 14. CODEX_HOME 指向的目录不存在

**现象**

```text
CODEX_HOME points to "/path/to/dir", but that path does not exist
```

**原因**：设置了 `CODEX_HOME` 环境变量，但目录不存在。Codex 不会自动创建这个目录（[Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)）。

**修复**：`mkdir -p "$CODEX_HOME"`，或者取消这个变量，回到默认的 `~/.codex`。

---

<a id="windows-txt"></a>
## 15. Windows：config.toml.txt 与编码

**现象**：配置明明写了，doctor 第 2 项却提示找不到 `config.toml`，但存在 `config.toml.txt`；或者第 3 项报语法错误。

**原因与修复**

- 资源管理器默认隐藏扩展名，记事本「另存为」时可能自动加上 `.txt`。打开「查看 → 显示 → 文件扩展名」，把文件改名为 `config.toml`。
- Windows PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写入 BOM。建议用记事本保存为 UTF-8，或者用 `[IO.File]::WriteAllText()`，写出来是不带 BOM 的 UTF-8。doctor 能识别 BOM。
- TOML 的双引号字符串里，反斜杠是转义符。Windows 路径要么写成 `"C:\\Users\\me"`，要么用单引号字符串 `'C:\Users\me'`。

更多内容见 [windows.md](windows.md)。
