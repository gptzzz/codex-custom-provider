# 怎么判断一个网关（中转站）支持 Codex 需要的 /v1/responses

Codex 只会通过 Responses API 调用模型：`wire_api` 唯一合法的值是 `responses`。所以网关光有 `/v1/chat/completions` 不够，必须实现 `POST /v1/responses`，而且流式输出要按 Responses 的事件格式发，最后一个事件是 `response.completed`。

下面四步从简单到严格，第 3 步就是 Codex 实际发出的那种请求。核对日期 2026-09-29。

> 先设置两个变量，后面的命令都会用到：
>
> ```bash
> export BASE="https://your-gateway.example.com/v1"   # 和 config.toml 里的 base_url 一致
> read -rs YOUR_GATEWAY_API_KEY && export YOUR_GATEWAY_API_KEY
> ```
>
> 下面的 `curl -H "Authorization: Bearer $YOUR_GATEWAY_API_KEY"` 会把 key 放进命令行参数，本机其他用户用 `ps` 能看到。在共用的机器上，改用 `bash scripts/codex-doctor.sh --live`，它通过标准输入把 key 交给 curl。

## 1. 模型列表：GET /models

```bash
curl -sS "$BASE/models" -H "Authorization: Bearer $YOUR_GATEWAY_API_KEY"
```

期望：HTTP 200，返回 `{"object":"list","data":[{"id":"..."}, ...]}`。这一步只能说明 key 和 `base_url` 是对的，不能说明网关支持 Codex。记下你要用的模型 ID。

## 2. 非流式：POST /responses

```bash
curl -sS "$BASE/responses" \
  -H "Authorization: Bearer $YOUR_GATEWAY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"your-model-id","input":"Reply with the single word: pong"}'
```

期望：HTTP 200，JSON 里有这些字段：

```json
{
  "id": "resp_...",
  "object": "response",
  "status": "completed",
  "output": [{"type": "message", "content": [{"type": "output_text", "text": "pong"}]}],
  "usage": {"input_tokens": 12, "output_tokens": 2, "total_tokens": 14}
}
```

## 3. 流式：Codex 实际发出的请求

```bash
curl -sS -N "$BASE/responses" \
  -H "Authorization: Bearer $YOUR_GATEWAY_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"model":"your-model-id","input":"Reply with the single word: pong","stream":true}'
```

`-N` 关闭 curl 的输出缓冲，这样事件到一个显示一个。期望看到一串事件，最后一个是 `response.completed`：

```text
event: response.created
data: {"type":"response.created","response":{"id":"resp_...","status":"in_progress",...}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"pong",...}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_...","status":"completed",...,"usage":{"input_tokens":12,"output_tokens":2,"total_tokens":14}}}
```

Codex 解析这个流时的要求（源码 [`codex-api/src/sse/responses.rs`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/codex-api/src/sse/responses.rs)）：

- 事件类型看的是 `data:` 里 JSON 的 `type` 字段，不是 `event:` 行。
- 流必须以 `response.completed` 结束；`response.incomplete` 只有在原因是 `interrupted` 时才算正常结束。否则报 `stream closed before response.completed`。
- `response.completed` 里的 `response.id` 必须是字符串。如果带了 `usage`，其中的 `input_tokens`、`output_tokens`、`total_tokens` 必须是整数。
- 两个事件之间的间隔超过 `stream_idle_timeout_ms`（默认 5 分钟），报 `idle timeout waiting for SSE`。

## 4. 工具调用：Codex 靠它执行命令、修改文件

Codex 通过工具调用来运行命令、编辑文件。网关如果丢掉 `tools` 字段，或者把 `function_call` 改坏了，Codex 能正常聊天，却不会动手改代码。

```bash
curl -sS "$BASE/responses" \
  -H "Authorization: Bearer $YOUR_GATEWAY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-id",
    "input": "What is the weather in Paris? Use the get_weather tool.",
    "tools": [{
      "type": "function",
      "name": "get_weather",
      "description": "Get the current weather for a city",
      "parameters": {
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"],
        "additionalProperties": false
      }
    }]
  }'
```

期望：`output` 里有一项 `"type": "function_call"`，并带有 `call_id`、`"name": "get_weather"`，以及可以解析成 JSON 的 `arguments`，例如 `"{\"city\":\"Paris\"}"`。

## 结果怎么看

| 结果 | 含义 | Codex 能不能用 |
|---|---|---|
| 1 通过，2 返回 404 / 405 | 网关只有 Chat Completions | 不能，见 [errors.md#responses-404](errors.md#responses-404) |
| 2 通过，3 返回一个完整的 JSON 而不是事件流 | 网关没理会 `stream: true` | 不能，Codex 会报 `stream closed before response.completed` |
| 3 有事件，但最后不是 `response.completed` | 网关转换事件时漏了最后一个 | 不能，同上 |
| 3 通过，4 没有 `function_call` | 工具调用没有透传 | 能聊天，但不会执行命令、改文件 |
| 1 到 4 全部通过 | 协议兼容 | 可以，再用 `codex exec "Reply with the single word: ready"` 做一次端到端确认 |

这些检查只能说明协议兼容，不能证明网关背后实际用的是哪个模型。

`bash scripts/codex-doctor.sh --live` 自动完成第 1 步和第 3 步，并按 Codex 的规则判断结果（11a、11b）。
