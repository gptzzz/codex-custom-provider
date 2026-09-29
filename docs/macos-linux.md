# macOS / Linux：Codex CLI 第三方 API 配置

核对日期 2026-09-29。安装命令来自 [Codex CLI 官方页面](https://learn.chatgpt.com/docs/codex/cli)，配置路径和环境变量来自 [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic) 和 [Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)。

## 1. 安装或更新 Codex CLI

任选一种：

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh    # 官方独立安装脚本；再跑一次就是更新
npm install -g @openai/codex                           # npm
brew install --cask codex                              # Homebrew；更新用 brew upgrade --cask codex
```

```bash
codex --version
```

## 2. 写配置文件

```bash
mkdir -p ~/.codex
cp config/config.toml.example ~/.codex/config.toml   # 第一次配置
${EDITOR:-vi} ~/.codex/config.toml                  # 改 your-gateway、base_url、model
```

`~/.codex/config.toml` 里原来就有内容的话，不要直接覆盖。把 `model`、`model_provider` 两行放到文件开头（第一个 `[表]` 之前），再把 `[model_providers.your-gateway]` 整段贴到文件末尾。

设置了 `CODEX_HOME` 时，配置文件在 `$CODEX_HOME/config.toml`，而且这个目录必须事先存在，Codex 不会自动创建。

## 3. 设置 key

`env_key = "YOUR_GATEWAY_API_KEY"` 表示 Codex 从这个环境变量读 key。按需要的持久程度选一种。

### 只在当前终端有效（最安全）

```bash
read -rs YOUR_GATEWAY_API_KEY && export YOUR_GATEWAY_API_KEY
```

`read -rs` 读取输入时不回显，也不会进 shell 历史。终端关掉，变量就没了。

### 每次打开终端都有

| shell | 写到哪个文件 | 写法 |
|---|---|---|
| zsh（macOS 默认） | `~/.zshrc` | `export YOUR_GATEWAY_API_KEY="..."` |
| bash（Linux） | `~/.bashrc` | 同上 |
| bash（macOS 登录 shell） | `~/.bash_profile` | 同上 |
| fish | 不用改文件 | `set -Ux YOUR_GATEWAY_API_KEY "..."` |

这样做 key 是明文保存在文件里的。至少执行一次 `chmod 600 ~/.zshrc`，并且不要把这类文件同步到公开的 dotfiles 仓库。改完以后重开终端，或者执行 `source ~/.zshrc`。

### 不在文件里存明文（推荐）

**macOS 钥匙串 + 环境变量**：把 key 存进钥匙串，`~/.zshrc` 里只写读取命令：

```bash
# 存一次。-w 放在最后，会提示你输入 key
security add-generic-password -a "$USER" -s your-gateway-api-key -w
```

```bash
# ~/.zshrc
export YOUR_GATEWAY_API_KEY="$(security find-generic-password -s your-gateway-api-key -w 2>/dev/null)"
```

**让 Codex 自己跑命令取 key（`auth.command`）**：Codex 支持用一条命令获取 token（[Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)）。这样 key 连环境变量都不进：

```toml
[model_providers.your-gateway]
name = "Your Gateway"
base_url = "https://your-gateway.example.com/v1"
wire_api = "responses"
# 用了 [...auth] 就不要再写 env_key，两者不能同时使用

[model_providers.your-gateway.auth]
command = "/usr/bin/security"
args = ["find-generic-password", "-s", "your-gateway-api-key", "-w"]
# timeout_ms = 5000              # 命令最长运行时间，默认 5000
# refresh_interval_ms = 300000   # 多久重新取一次，默认 300000
```

Linux 上可以用 libsecret 的 `secret-tool`：

```bash
secret-tool store --label="your-gateway API key" service your-gateway   # 提示你输入 key
```

```toml
[model_providers.your-gateway.auth]
command = "secret-tool"
args = ["lookup", "service", "your-gateway"]
```

这个命令不会收到任何标准输入，只要把 token 打印到标准输出即可。Codex 会去掉首尾空白；输出为空时报错。

## 4. 验证

```bash
bash scripts/codex-doctor.sh           # 离线检查
bash scripts/codex-doctor.sh --live    # 真实请求一次（很小的计费）
codex exec "Reply with the single word: ready"
```

进入 Codex 的 TUI 以后，`/status` 显示当前的模型和 provider，`/debug-config` 显示每一层配置从哪里加载。

## 5. SSH、tmux、无界面服务器和 CI

- **SSH 登录后运行**：变量要放在远程机器上，写进远程的 `~/.bashrc` 或 `~/.zshrc`。本地的变量不会跟着 SSH 过去。
- **tmux / screen**：新窗格继承的是 tmux 服务端启动时的环境。在已经开着的 tmux 里新设的变量，其他窗格看不到。可以重启 tmux，或者用 `tmux set-environment YOUR_GATEWAY_API_KEY "$YOUR_GATEWAY_API_KEY"`。
- **systemd 服务**：用 `EnvironmentFile=` 指向一个权限为 600 的文件，不要把 key 写在 unit 文件里。
- **CI（比如 GitHub Actions）**：key 放进仓库的 Secrets，只在运行 `codex exec` 的那一步通过 `env:` 注入，不要设成整个 job 的环境变量。官方文档对 `CODEX_API_KEY` 也是这样建议的：运行仓库里的代码时，把它设在单条命令上。配置文件在这一步里写到 `$CODEX_HOME/config.toml` 即可。

## 6. 常见问题

- 提示 `codex: command not found`：安装目录不在 `PATH` 里。独立安装脚本默认装到 `~/.local/bin`（可以用 `CODEX_INSTALL_DIR` 修改）；npm 装的，检查 `npm prefix -g` 下的 `bin` 目录。
- 其他报错见 [errors.md](errors.md)。
