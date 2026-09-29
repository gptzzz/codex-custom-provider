# 安全说明

## 这个仓库怎么处理你的 key

- `codex-doctor` 只从 `env_key` 指定的环境变量读取 key，输出里只显示它的**长度**。
- 配置文件里如果出现疑似 key 的内容（`env_key` 里填了 key 本身、provider 表里写了 `api_key`、硬编码的 `Authorization` 请求头），doctor 只报告位置和长度，不打印内容。
- 默认不联网。加上 `--live` / `-Live` 以后，只请求你在 `base_url` 里写的地址：一次 `GET /models`，一次流式 `POST /responses`（会产生很小的计费）。
- bash 版本通过标准输入（`curl -K -`）把请求头交给 curl，key 不会出现在进程列表里。从响应里打印的内容，都会先把 key 替换成 `[REDACTED]`。
- PowerShell 版本在进程内用 .NET 的 `HttpClient` 发请求，不调用外部程序。

## 如果你的 key 泄露了

1. 立刻到网关或 OpenAI 后台作废这个 key，再换一个新的。
2. key 被提交进过 Git 的，只删掉那一行不够，它还留在历史里。作废 key 是唯一可靠的办法。
3. 检查 shell 历史（`~/.zsh_history`、`~/.bash_history`、PowerShell 的 `(Get-PSReadLineOption).HistorySavePath`）里有没有明文的 key。

## 报告安全问题

发现脚本本身的安全问题（比如会在某种情况下打印出 key），请**不要**公开提 issue。请使用 GitHub 的 [Private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) 私下报告（仓库页面 → Security → Report a vulnerability）。
