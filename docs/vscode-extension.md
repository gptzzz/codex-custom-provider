# VS Code 等 IDE 扩展：会不会读同一份 Codex 配置？

**会。** 官方文档原文是「The CLI and IDE extension share the same configuration layers」（[Config basics](https://learn.chatgpt.com/docs/config-file/config-basic)，2026-09-29 核对）。`CODEX_HOME` 也同时作用于 CLI 和 IDE 扩展（[Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)）。所以 `~/.codex/config.toml` 里的 `model_provider` 和 `[model_providers.*]` 对扩展同样生效，不需要在扩展里另配一遍。

扩展里最常见的问题不是配置本身，而是**扩展看不到你设置的环境变量**。

## 打开扩展正在用的 config.toml

在 Codex 侧边栏点齿轮图标，选择 **Codex Settings → Open config.toml**（[Developer settings](https://learn.chatgpt.com/docs/developer-settings?surface=ide)）。

VS Code 设置里以 `chatgpt.*` 开头的项属于扩展本身，比如 `chatgpt.openOnStartup`。它们**不写进** `config.toml`，provider 相关的设置也不在这里。

## 环境变量：扩展是从哪里继承的

扩展由 VS Code 进程启动，环境变量继承自 VS Code：

- **macOS / Linux**：从 Dock 或应用菜单启动的 VS Code，启动时会运行一个小进程，读取 `.zshrc`、`.bashrc` 或 PowerShell profile 里定义的环境（VS Code FAQ「[Resolving shell environment fails](https://code.visualstudio.com/docs/supporting/faq)」）。写在这些文件里的 `export YOUR_GATEWAY_API_KEY=...` 通常能被读到。只在某个终端窗口里临时 `export` 的变量读不到。
- **Windows**：VS Code 继承它启动时的用户变量。设置变量之前就打开的 VS Code 看不到新变量。

实际操作建议：

1. 变量写进 shell 配置文件（macOS/Linux），或者设为用户变量（Windows）。做法见 [macos-linux.md](macos-linux.md) 和 [windows.md](windows.md)。
2. **完全退出 VS Code 再打开**。macOS 上按 Cmd+Q；只关窗口或 Reload Window 不一定会重新读取环境。
3. 还有一个最直接的办法：从已经设置好变量的终端里启动 VS Code，比如执行 `code .`，VS Code 会继承这个终端的环境。
4. 如果你用了 [`auth.command`](macos-linux.md#不在文件里存明文推荐) 从钥匙串取 key，就不存在上面这些问题，因为 key 是 Codex 自己运行命令取的。

## 怎么确认扩展用的是你的 provider

- 在扩展的对话框里输入 `/status`，查看当前的模型和 provider。
- 在 VS Code 的集成终端里运行 `bash scripts/codex-doctor.sh`（Windows 用 `scripts\codex-doctor.ps1`）。集成终端的环境和扩展的环境不一定完全相同，但第 1 到 8 项、第 10 项检查的是配置文件本身，结论同样适用。

## Windows 和 WSL

- 打开了 `chatgpt.runCodexInWindowsSubsystemForLinux`（「Run Codex in WSL when WSL is available」）的，Codex 运行在 WSL 里。配置和环境变量要设在 WSL 这一侧，见 [windows.md](windows.md)。
- 用 VS Code 的 WSL 远程窗口打开项目时（状态栏显示 `WSL: <发行版>`），官方建议把仓库放在 Linux 主目录下，并确认 WSL 里能找到 `codex`：`which codex`（[官方 WSL 文档](https://learn.chatgpt.com/docs/windows/wsl)）。

## 扩展还是报 401 或「Missing environment variable」

按顺序排查：

1. 在集成终端里运行 `printenv YOUR_GATEWAY_API_KEY >/dev/null && echo set`（PowerShell 用 `[bool]$env:YOUR_GATEWAY_API_KEY`），确认 VS Code 这一侧能看到变量。
2. 完全退出 VS Code 再重开，或者从终端用 `code .` 启动。
3. 仍然不行的，改用 `auth.command`，或者看 [errors.md#401](errors.md#401)。
