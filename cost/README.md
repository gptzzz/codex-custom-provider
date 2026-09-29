# Codex 成本估算器（cost/）

一个零依赖的 Python 命令行工具，只用标准库，Python 3.9+ 可用。它读一个 CSV，每行一个任务，写明三类 token 数和你自己填的单价，输出：

- 所有任务的总成本；
- 每个任务的输入、缓存输入、输出成本和合计；
- 按 `task_type` 汇总；
- 按 `billing_path` 汇总（ChatGPT 套餐、credits、API key、第三方网关分开算）；
- 通过验收的任务数，以及平均每个通过验收的任务花了多少钱。

> 工具里没有内置价格，也不代表任何一家的当前价格。`sample_tasks.csv` 里的单价只是用来演示计算的；实际使用时，请从你自己的账单或服务商价格页填写。

这个目录来自原来的 `codex-cost-planner` 仓库，三个文件原样保留（v2.0.0 之前在仓库根目录）。估算的思路见 [docs/cost-planning.md](../docs/cost-planning.md)。

## 用法

```bash
python3 cost/calculator.py                    # 默认读 cost/sample_tasks.csv
python3 cost/calculator.py path/to/tasks.csv  # 读你自己的记录
python3 -m unittest discover -s cost -v       # 跑测试
```

建议先复制一份 `sample_tasks.csv`，把内容换成自己的任务记录，再把运行结果存进项目的成本说明里。

## CSV 格式

必需的列：

| 列名 | 类型 | 说明 |
|---|---|---|
| `task_id` | 字符串 | 任务的唯一标识，不能重复 |
| `task_type` | 字符串 | 任务类型，用于分组，比如 `bugfix`、`refactor` |
| `billing_path` | 字符串 | 计费路径，比如 `chatgpt-plan`、`credits`、`api-key`、`gateway` |
| `input_tokens` | 非负整数 | 未命中缓存的输入 token |
| `cached_input_tokens` | 非负整数 | 命中缓存的输入 token |
| `output_tokens` | 非负整数 | 输出 token（含推理 token） |
| `input_usd_per_million` | 非负小数 | 每百万输入 token 的单价 |
| `cached_input_usd_per_million` | 非负小数 | 每百万缓存输入 token 的单价 |
| `output_usd_per_million` | 非负小数 | 每百万输出 token 的单价 |
| `accepted` | 布尔值 | `true/false`、`yes/no` 或 `1/0`，表示是否通过验收 |

计算公式：

```text
task_cost = input_tokens        / 1,000,000 × input_usd_per_million
          + cached_input_tokens / 1,000,000 × cached_input_usd_per_million
          + output_tokens       / 1,000,000 × output_usd_per_million
```

金额用十进制定点数计算，避免二进制浮点在累加时产生误差。以下情况都会报错，指出出错的行号和字段，并以非零状态退出，不会悄悄跳过：字段为空、负数、`task_id` 重复、`accepted` 的值无法识别。

用第三方网关的，`billing_path` 填 `gateway`（或者网关的名字），单价按网关的价格页填写。网关用人民币计价的，把单价换算成美元再填，或者把整列都当成人民币看待：计算器只做乘法和加法，不关心币种。

## 示例输出

`python3 cost/calculator.py` 的实际输出（第一行是 CSV 的绝对路径，这里做了缩写）：

```text
Source: .../codex-custom-provider/cost/sample_tasks.csv

Per-task costs
----------------------------------------------------------------------------------------------
task_id                      task_type              billing_path       accepted       cost_usd
----------------------------------------------------------------------------------------------
explain-auth-flow            code-explanation       chatgpt-plan       yes             $0.0223
fix-session-timeout          bugfix                 api-key            yes             $0.1840
refactor-cache-layer         refactor               credits            no              $0.4252
review-payment-module        code-review            chatgpt-plan       yes             $0.0785

By task type
--------------------------------------------------
bugfix                                     $0.1840
code-explanation                           $0.0223
code-review                                $0.0785
refactor                                   $0.4252

By billing path
--------------------------------------------------
api-key                                    $0.1840
chatgpt-plan                               $0.1008
credits                                    $0.4252

Grand total: $0.7100
Accepted tasks: 3/4
Average cost per accepted task: $0.2367
```

## 怎么看结果

- **Per-task costs**：找单个任务的异常。一个小修复比同类任务贵很多的，回头看它是不是读了太多文件、失败重试了很多轮，或者走错了计费路径。
- **By task type**：比较 bugfix、refactor、code-review 等类别，判断哪类任务值得交给 agent。
- **By billing path**：把套餐、credits、API key、网关分开。最后即使要合并进同一个项目预算，也先保留原始路径，免得把订阅费当成 API 余额。
- **Average cost per accepted task**：总成本除以通过验收的任务数。没通过、被废弃的任务同样花了钱，会拉高这个数字，所以它比只统计成功任务更能反映返工成本。

## 常见问题

**为什么示例单价不是官方的当前价格？** 价格、模型和优惠都会变，不同账户适用的路径也可能不同。示例只用来验证计算方法，免得这个仓库变成一张过期的价格表。

**买了 ChatGPT 套餐，还要记 API key 的用量吗？** 要。API key 路径按 API 规则单独计费（[Authentication](https://learn.chatgpt.com/docs/auth)），不能指望用 ChatGPT 订阅抵扣。在 `billing_path` 里标清楚。

**`accepted` 有什么用？** 它表示任务是否通过测试、被合并或实际采用。工具据此算出「平均每个通过验收的任务花多少钱」，避免把一大堆没被采用的输出也算成产出。
