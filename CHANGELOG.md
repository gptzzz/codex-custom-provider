# 更新日志 / Changelog

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [2.0.0] - 2026-09-29

仓库从 `codex-cost-planner` 扩展为 Codex 自定义 provider 的配置指南，并改名为 `codex-custom-provider`。旧地址会自动跳转。

### 新增

- README：先说结论、最小配置、配置生效顺序、`config.toml` 逐字段解释、三种接法对比、报错对照、多 provider 切换、已实测示例。全部对照官方 Configuration Reference 和 openai/codex `rust-v0.158.0` 源码核对（2026-09-29）。
- `scripts/codex-doctor.sh`（bash 3.2+）和 `scripts/codex-doctor.ps1`（PowerShell 5.1 / 7）：10 项离线检查，加上 `--live` / `-Live` 时的 2 项真实请求；输出 PASS/WARN/FAIL 表，退出码等于 FAIL 的数量；key 只打印长度。
- `config/`：通用模板 `config.toml.example`、已实测的 `gptzzz.toml`、`profiles/`（0.134+ 的 profile 文件写法）。
- `docs/`：macOS/Linux、Windows/WSL、VS Code 扩展、15 条报错对照、`/v1/responses` 支持检测、成本规划、事实来源。
- `tests/`：12 份 TOML fixture，`test_doctor.py` 用子进程运行 doctor 并断言结果；`mock_gateway.py` 只监听 127.0.0.1，用来离线测试 `--live`。
- CI：shellcheck、PSScriptAnalyzer、用 `tomllib` 解析所有 TOML 示例；测试覆盖 Ubuntu（bash 5、mawk）、macOS（`/bin/bash` 3.2、BSD awk）、Windows（PowerShell 5.1 和 7）。
- MIT `LICENSE`、`CONTRIBUTING.md`、`SECURITY.md`。

### 变更

- 成本计算器 `calculator.py`、`sample_tasks.csv`、`test_calculator.py` 原样移到 `cost/` 目录，用法写进 `cost/README.md`。
- `docs/codex-paid-guide.md` 改写为 `docs/cost-planning.md`：补充第三方网关这条计费路径，官方链接换成 2026-09-29 的新地址。旧文件保留为跳转页。
- 按 2026 年后的官方写法，原来计划的 `profiles.toml.example`（`[profiles.x]` 表）改成了 `config/profiles/*.config.toml.example`（0.134+ 的单独文件）。

### 移除

- README 里一个指向非官方站点的外部链接。计费说法只引用 OpenAI 官方页面。
- `images/` 目录里的两张示意图（其中一张 1.6 MB）。改用 README 里的 Mermaid 图。

## [1.0.0] - 2026-08-28

- 初始发布（提交 `026fdd9`，当时没有打 tag）：零依赖的 Codex 任务成本计算器（`calculator.py`），附示例 CSV、单元测试和中文使用指南。
