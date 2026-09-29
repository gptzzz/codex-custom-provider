# 多个 provider 并存与切换（Codex 0.134+ 的 profile 文件）

从 Codex 0.134.0 起，`--profile <名字>` 读的是单独的文件 `~/.codex/<名字>.config.toml`。它叠加在 `~/.codex/config.toml` 之上，里面的键直接写在顶层。`[profiles.<名字>]` 表不再读取，顶层的 `profile = "<名字>"` 会直接报错（[Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)，2026-09-29 核对）。

| 文件 | 复制到 | 作用 |
|---|---|---|
| [config.toml.example](config.toml.example) | `~/.codex/config.toml` | 定义 gateway-a（默认）和 gateway-b 两个 provider |
| [gateway-b.config.toml.example](gateway-b.config.toml.example) | `~/.codex/gateway-b.config.toml` | `codex --profile gateway-b` 时改用 gateway-b |
| [chatgpt.config.toml.example](chatgpt.config.toml.example) | `~/.codex/chatgpt.config.toml` | `codex --profile chatgpt` 时切回内置的 `openai` provider，也就是 ChatGPT 登录 |

```bash
cp config/profiles/config.toml.example ~/.codex/config.toml                     # 已有配置的话，手动合并
cp config/profiles/gateway-b.config.toml.example ~/.codex/gateway-b.config.toml
cp config/profiles/chatgpt.config.toml.example ~/.codex/chatgpt.config.toml

codex                          # gateway-a
codex --profile gateway-b      # gateway-b
codex --profile chatgpt        # ChatGPT 登录
bash scripts/codex-doctor.sh --profile gateway-b    # 按叠加以后的结果自检
```

Windows 上把 `~/.codex/` 换成 `%USERPROFILE%\.codex\`。

## 为什么 provider 都定义在基础配置里

- profile 文件越短越好，只写和基础配置不同的键，一般就是 `model_provider` 和 `model`。
- 每个 provider 的 key 放在各自的环境变量里（`GATEWAY_A_API_KEY`、`GATEWAY_B_API_KEY`），切换 profile 不用改 key。
- 也可以把 `[model_providers.gateway-b]` 写进 `gateway-b.config.toml`。profile 文件属于用户级配置，provider 键在这里有效，只是这样定义会分散在几个文件里。

## 从旧写法迁移

```toml
# 旧写法（0.134 以前），在 ~/.codex/config.toml 里：
profile = "work"            # 现在会直接报错
[profiles.work]             # 现在不再读取
model = "gpt-x"
model_provider = "gateway-b"
```

```toml
# 新写法：新建 ~/.codex/work.config.toml
model = "gpt-x"
model_provider = "gateway-b"
```

然后删掉 `config.toml` 里的 `profile = "work"` 和 `[profiles.work]`，以后用 `codex --profile work` 选中。`codex-doctor` 第 10 项会检查有没有旧写法残留。
