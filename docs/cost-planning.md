# Codex 成本估算：套餐额度、API key 与第三方网关三条计费路径

用 Codex 花多少钱，不能按「发了多少条消息」估算。解释一个小函数，和扫描整个仓库、跑测试、失败后再修，都可能只是一条消息，消耗却差很多。本文给出一个不依赖固定价格的估算方法，配套工具是 [cost/calculator.py](../cost/calculator.py)。

本文不写任何套餐的额度数字，也不写价格：它们会变，而且因账户而异。涉及官方计费的说法都附了出处，核对日期 2026-09-29。

## 先分清三条计费路径

| 路径 | 怎么计费 | 看哪里的数据 | 容易混淆的地方 |
|---|---|---|---|
| ChatGPT 套餐内的 Codex | 按套餐的使用额度，额度用完可以再买 credits（视账户而定） | 账户里的 Usage 页面、重置时间 | 套餐费不是 API 预存款 |
| OpenAI API key | 按标准 API 价格计 token，从 OpenAI Platform 账户扣费 | Platform 的用量和账单 | 和 ChatGPT 订阅是两本账 |
| 第三方网关 / 中转站的 key | 按该网关自己的价格表计 token | 网关后台的用量明细 | 单价、模型命名、缓存计费规则都以网关为准 |

官方依据：

- Codex 包含在 ChatGPT 的 Free、Go、Plus、Pro、Business、Edu、Enterprise 等方案里。各方案额度不同；用 API key 时「Pay for Codex usage based on API pricing」，没有云端功能（[Codex Pricing](https://learn.chatgpt.com/docs/pricing)）。
- 用 API key 登录时，「OpenAI bills API key usage through your OpenAI Platform account at standard API rates」（[Authentication](https://learn.chatgpt.com/docs/auth)）。
- API 的单价见 [API Pricing](https://developers.openai.com/api/docs/pricing)。

同一台机器上可能三条路径都在用：平时用 ChatGPT 登录，CI 用 API key，个人项目走网关。记账时把它们分开，`calculator.py` 的 `billing_path` 列就是为此设计的。

## 影响单个任务成本的五个因素

官方的说法是：「Model choice, context, reasoning, tool use, retrieval, and caching all affect usage」，所以不能只看提示词长度（[Codex Pricing](https://learn.chatgpt.com/docs/pricing) 的 FAQ）。落到实际开发中，主要是下面五个因素：

1. **上下文大小。** Codex 不只读你的提示词，还会读相关文件、项目说明、历史对话和工具输出。先限定目录和文件类型，再让它逐步扩大搜索范围，比一开始就把整个仓库塞进去更省，也更容易定位问题。
2. **任务闭环长度。** 「解释这段函数」是一问一答；「定位回归、改三处、跑测试、修失败、写变更说明」要来回很多轮。预算要按交付物计算，不能按提示次数。
3. **模型和推理强度。** 强模型、高推理档位适合做架构判断和疑难调试。格式化、重命名、机械迁移这类工作，用轻一些的模型或更低的档位就够了。
4. **并行程度。** 同时开多个 agent 能缩短等待时间，但总的上下文、工具调用和输出都会成倍增加。只有子任务边界清楚、改的文件不冲突、能各自验收时，并行才划算。
5. **返工率。** 最贵的往往不是第一次运行，而是需求模糊导致的反复重做。复现步骤、测试命令、不许改动的范围、完成标准，一次写清楚。改动前后各做一个 Git 检查点，失败时回退的成本也更低。

把这五个因素合在一起，是下面这个经验式（用来规划，不是官方的计费公式）：

```text
任务压力 = 上下文大小 × 闭环长度 × 模型系数 × 并行数 × 返工系数
```

在决定多买额度之前，先把这五项压下来。

## 用「每个通过验收的任务成本」做四周试算

与其追着会变的价格跑，不如连续记四周。每个任务记这几项：类型、计费路径、三类 token（输入、缓存输入、输出）、单价，以及是否通过验收（测试通过并且合并或实际采用）。

```text
每个通过验收的任务成本 = 这段时间的总成本 ÷ 通过验收的任务数
```

没通过、被废弃的任务同样花了钱，所以会拉高这个指标。这正是它的用处：它反映了返工的真实成本。

`calculator.py` 就是按这个口径算的：

```bash
python3 cost/calculator.py my_tasks.csv
```

CSV 的格式、计算公式和怎么解读输出，见 [cost/README.md](../cost/README.md)。

### token 数从哪里来

- **API key 和第三方网关**：Responses API 每次响应的 `usage` 字段里有 `input_tokens`、`output_tokens`，缓存命中的部分在 `input_tokens_details.cached_tokens`（不是每个网关都返回这一项）。网关后台的用量明细通常也能导出。
- **ChatGPT 套餐**：没有逐次的 token 账单，看 Usage 页面的额度消耗即可。这条路径可以按套餐费平摊，也可以只记任务数和是否通过验收，用来和其他路径比较效率。

### 单价从哪里来

- OpenAI API：[API Pricing](https://developers.openai.com/api/docs/pricing)，并以你账单上的实际数字为准。
- 第三方网关：网关自己的价格页或账单。注意它的模型 ID、缓存计费规则、最低消费可能和 OpenAI 不同。

## 调整方案前的检查清单

- [ ] 单价来自你账户适用的官方页面或实际账单，不是旧文章的截图。
- [ ] ChatGPT 登录、额外 credits、API key、网关 key 这几条路径分别标记了。
- [ ] 「通过验收」有统一标准，比如测试通过并已合并，而不是「生成了代码」。
- [ ] 统计周期覆盖了至少一段有代表性的开发时间。
- [ ] 成本特别高的任务，已经排查过无关上下文、重复并行和失败重试。
- [ ] 升级的收益用「减少了多少次被额度打断」来衡量，而不是只比较名义额度。

## 哪些话可以说，哪些不能说

可以确认的：Codex 能用 ChatGPT 账号登录；各套餐的使用上限不同；复杂任务通常比简单任务消耗多；API key 路径按 API 价格单独计费（出处见上文）。

不能承诺的：某个套餐永远包含固定数量的消息；一次任务固定消耗多少；所有地区、所有账户都能买额外的 credits；某个模型会一直可用；升级以后总成本一定下降。做购买决定时，记下查询日期，以结算页和 Usage 页面为准。
