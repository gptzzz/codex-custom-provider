# 参与贡献

感谢你愿意改进这个仓库。它的价值在于**准确**：每条关于 Codex 的说法都要有官方文档或源码作依据，并写明核对日期。

## 欢迎的贡献

- **新的报错案例**：写进 `docs/errors.md`，按「现象（报错原文）→ 原因 → 验证 → 修复」的格式。请附上 `codex-doctor` 的输出（删掉 key），并注明 Codex 的版本（`codex --version`）。
- **doctor 的新检查**：`codex-doctor.sh` 和 `codex-doctor.ps1` 要一起改，并在 `tests/fixtures/` 里加一份能复现问题的 TOML，在 `tests/test_doctor.py` 里写上断言。
- **文档修正**：官方行为变了、链接失效、平台细节有误，都欢迎指出。

## 不接受的内容

- **第三方网关或中转站的收录、推荐、价格对比。**「已实测示例」一节只放维护者本人实测过的网关，避免仓库变成广告列表。你想证明某个网关兼容 Codex，用 `codex-doctor.sh --live` 自己验证即可。
- 没有出处的额度、价格、封号风险之类的说法。
- 任何真实的 key、token 或 `auth.json` 内容，包括截图里的。

## 本地开发

```bash
python3 -m unittest discover -s tests -v    # doctor 的 fixture 测试（Python 3.11+ 时同时测 tomllib 和内置行解析器）
python3 -m unittest discover -s cost -v     # 成本计算器
bash -n scripts/codex-doctor.sh
shellcheck --severity=warning scripts/codex-doctor.sh    # 如果装了 shellcheck
```

有 `pwsh` 时，测试会自动再跑一遍 PowerShell 版本。PowerShell 脚本只能包含 ASCII 字符，还要能在 Windows PowerShell 5.1 下运行：不要用 `??`、三元运算符、`&&` 这类 PowerShell 7 才有的语法。bash 脚本要兼容 macOS 自带的 bash 3.2：不要用关联数组、`${var,,}` 和 `mapfile`。

## 发版前核对

每次发版（或者每季度一次），逐条对照 [docs/sources.md](docs/sources.md) 重新核对：

1. 打开 [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) 和 [Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)，确认 `wire_api`、保留 ID、项目级配置忽略的键、profile 写法、各项默认值有没有变。
2. 查看 openai/codex 最新的 release tag，确认报错原文仍然存在：`gh api repos/openai/codex/releases/latest --jq .tag_name`。
3. 把 README、`docs/sources.md` 顶部的核对日期和 tag 更新成实际核对的那一天。**没有重新核对，就不要改日期。**
4. 「已实测示例」只有在维护者用真实 key 重新跑过 `codex-doctor.sh --live` 以后才更新日期。
5. 更新 `CHANGELOG.md`，打 tag，发 Release。

## 提交规范

- 一个 PR 只做一件事，写清楚改了什么、依据是什么（附链接）。
- 提交邮箱建议用 GitHub 的 noreply 地址。
