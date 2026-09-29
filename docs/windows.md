# Windows：Codex CLI 第三方 API 配置（PowerShell / cmd / WSL）

核对日期 2026-09-29。依据：[Codex CLI 官方页面](https://learn.chatgpt.com/docs/codex/cli)、[Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)、[WSL](https://learn.chatgpt.com/docs/windows/wsl)，以及 Codex 源码中确定配置目录的 [`utils/home-dir`](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/utils/home-dir/src/lib.rs)。

## 先分清楚：原生 Windows 还是 WSL

| | 原生 Windows（PowerShell / cmd） | WSL2 |
|---|---|---|
| Codex 运行在 | Windows | WSL 里的 Linux |
| 配置文件 | `%USERPROFILE%\.codex\config.toml` | WSL 里的 `~/.codex/config.toml`（Linux 用户的主目录） |
| 环境变量 | Windows 的用户变量或会话变量 | WSL 里的 `~/.bashrc` 等 |
| 自检脚本 | `scripts\codex-doctor.ps1` | `bash scripts/codex-doctor.sh` |

两边的配置和变量**互不相通**：在 Windows 设置的变量，默认不会传进 WSL。在 WSL 里跑 Codex 的，按 [macos-linux.md](macos-linux.md) 配置即可。VS Code 打开了 `chatgpt.runCodexInWindowsSubsystemForLinux` 的，扩展运行在 WSL 里，也按 WSL 的方式配置。

## 1. 安装

```powershell
irm https://chatgpt.com/codex/install.ps1 | iex     # 官方独立安装脚本
# 或者
npm install -g @openai/codex
codex --version
```

## 2. 写配置文件

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex" | Out-Null
Copy-Item config\config.toml.example "$env:USERPROFILE\.codex\config.toml"   # 第一次配置
notepad "$env:USERPROFILE\.codex\config.toml"
```

设置了 `CODEX_HOME` 时，配置文件在 `$env:CODEX_HOME\config.toml`，而且这个目录必须事先存在。

三个常见的坑：

1. **文件被存成了 `config.toml.txt`。** 资源管理器默认隐藏扩展名，看起来叫 `config.toml`，其实不是。打开「查看 → 显示 → 文件扩展名」确认一下。doctor 的第 2 项会专门检查这种情况。
2. **编码。** 用记事本保存为 UTF-8 即可。Windows PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会在文件开头写 BOM，想用命令写文件的话，用这个写法（不带 BOM）：
   ```powershell
   [IO.File]::WriteAllText("$env:USERPROFILE\.codex\config.toml", (Get-Content -Raw config\config.toml.example))
   ```
3. **反斜杠。** TOML 的双引号字符串里，`\` 是转义符。配置里要写 Windows 路径的（比如 `auth.command`），写成 `"C:\\Tools\\get-token.exe"`，或者用单引号字符串 `'C:\Tools\get-token.exe'`。

## 3. 设置 key

`env_key = "YOUR_GATEWAY_API_KEY"` 表示 Codex 从这个环境变量读 key。

### 只在当前窗口有效

```powershell
# PowerShell 7.1+：输入时不回显
$env:YOUR_GATEWAY_API_KEY = Read-Host -MaskInput "API key"

# Windows PowerShell 5.1
$s = Read-Host -AsSecureString "API key"
$env:YOUR_GATEWAY_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
```

cmd.exe 的写法是 `set YOUR_GATEWAY_API_KEY=...`，注意等号两边不要有空格。

### 长期保存（当前 Windows 用户）

```powershell
# PowerShell 7.1+。Windows PowerShell 5.1 先按上面的方法得到 $env:YOUR_GATEWAY_API_KEY，再把第二个参数换成它
[Environment]::SetEnvironmentVariable("YOUR_GATEWAY_API_KEY", (Read-Host -MaskInput "API key"), "User")
```

也可以在「设置 → 系统 → 系统信息 → 高级系统设置 → 环境变量」里添加「用户变量」。

**保存以后要重新打开终端**。已经开着的 PowerShell、Windows Terminal 标签页和 VS Code 看不到新变量，VS Code 要完全退出再打开。doctor 能识别这种情况：变量已经保存在用户级，但当前会话看不到，它会提示你重开。

`setx YOUR_GATEWAY_API_KEY "..."` 同样写入用户变量，但值会留在 PowerShell 或 cmd 的命令历史里，不推荐。

## 4. 运行自检

```powershell
powershell -ExecutionPolicy Bypass -File scripts\codex-doctor.ps1
powershell -ExecutionPolicy Bypass -File scripts\codex-doctor.ps1 -Live              # 真实请求一次，会产生很小的计费
powershell -ExecutionPolicy Bypass -File scripts\codex-doctor.ps1 -ProfileName work  # 叠加 work.config.toml
```

`-ExecutionPolicy Bypass` 只对这一次运行有效，不改变系统的执行策略。装了 PowerShell 7 的，也可以用 `pwsh -File scripts\codex-doctor.ps1`。脚本不依赖 Python 和 curl。

最后做一次端到端确认：

```powershell
codex exec "Reply with the single word: ready"
```

## 5. WSL 里的注意事项

- 在 WSL 里安装 Codex：`curl -fsSL https://chatgpt.com/codex/install.sh | sh`（[官方 WSL 文档](https://learn.chatgpt.com/docs/windows/wsl)）。
- 配置写在 WSL 的 `~/.codex/config.toml`，变量写在 WSL 的 `~/.bashrc`。
- 代码仓库放在 Linux 主目录下（比如 `~/code/...`），不要放在 `/mnt/c/...`。后者读写慢，还容易遇到权限和符号链接的问题（官方文档的建议）。
- 开头的对照表已经说过：Windows 的用户变量不会自动出现在 WSL 里。可以用 `WSLENV` 共享，但在 WSL 里单独设置一次更简单。

其他报错见 [errors.md](errors.md)。
