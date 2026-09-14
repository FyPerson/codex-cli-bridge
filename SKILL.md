---
name: codex-cli-bridge
description: 手动触发的 Codex CLI 第二视角桥接技能。仅在用户显式要求（`/codex-review`、"用 codex 审一下"、"让 codex 看看"、"codex 二审"、"叫 codex 挑挑毛病"）时使用。把本机 `codex` 命令封装成稳定的辅助调用口，让 Codex 以第二视角审核方案、代码、SQL 等工作产物。Claude Code 保持主导，Codex 只给建议稿，最终决定权在用户。
disable-model-invocation: true
compatibility: Designed for Claude Code on Windows. Requires `codex` CLI installed and logged in (via `codex login`, uses ChatGPT subscription).
---

# Codex CLI Bridge

把本机 `codex` 命令收敛成一个稳定的"第二视角调用口"。主角是 Claude Code + 用户，Codex 是第二视角 specialist，只给建议，不碰文件、不替代收口。

## 非目标

- **不自动触发**：不要因为 Claude Code 自己觉得"当前方案需要第二视角"就去调 Codex。
- **不替代 Claude Code 收口**：Codex 的输出是建议稿，最终落地（文件改动、commit、部署）仍由 Claude Code 执行、用户拍板。
- **不碰本地文件**：Codex 调用强制 `--sandbox read-only`，只读审核，不允许写。
- **不替代用户的战略判断**：Codex 只给"技术层面能发现的问题"，战略层判断权在用户。

## 三方分工

| 角色 | 职责 |
|---|---|
| **用户** | 战略判断、最终决策、是否采纳某条建议 |
| **Claude Code（我）** | 方案/代码产出、Codex 意见整合、实现落地、自测、部署 |
| **Codex CLI** | 技术细节审核、问题清单、盲点发现（第二视角） |

## 触发方式

此 skill 是**手动触发**。以下任一情况才启用：

1. 用户输入 `/codex-review`（或 `/codex-review <arguments>`）
2. 用户在自然语言中明确要求：
   - "用 codex 审一下"
   - "让 codex 看看"
   - "codex 二审"
   - "叫 codex 挑挑毛病"
   - "调 codex 复查"
3. 用户明确提到 `codex` 且上下文在审核场景

以下情况**不要**使用此 skill：

- 用户没有提到 codex，即使 Claude Code 自己觉得需要第二视角
- 完成方案/代码后例行询问，用户没说调 codex
- 用户说"你自己再看一遍" —— 这是让 Claude Code 自检，不是调 Codex

## 模式

| 调用方式 | 用途 |
|----------|------|
| `/codex-review` | 默认 `spec-critique` 模式，审核当前会话中最后讨论的方案/文档/代码 |
| `/codex-review <文件路径>` | 对指定文件发起审核 |
| `/codex-review <主题>` | 按主题审核（由 Claude 从会话上下文组装 brief） |

## TaskType 清单（起点 4 种，后续按需扩展）

| TaskType | 用途 | 推荐 Mode |
|---|---|---|
| `spec-critique` | 方案、需求、设计文档、实现计划的第二视角审核（主力） | advice-only |
| `code-review` | 代码/脚本审核，发现逻辑问题、边界情况、可读性问题 | advice-only |
| `sql-review` | SQL、数仓脚本、ETL 逻辑审核，口径、性能、边界案例 | advice-only |
| `general-assist` | 其他明确边界的辅助审核子任务 | advice-only |

## Mode 清单

| Mode | 含义 |
|---|---|
| `advice-only` | 只给分析和建议，不假装改过文件、跑过测试 |
| `draft-only` | 允许给补丁/文案/结构草稿，但明确标注"未落地" |

> 本 bridge 刻意不提供 `execute-via-codex` 模式——落地一律由 Claude Code 执行，不让 Codex 直接改文件。

## 触发节点（方案 + 编码两阶段系统化）

codex 审在工作流中的固定触发节点（2026-05-24 v1.71.0 复盘系统化）：

> **审查强度分级指针（2026-07-05 加）**：codex 审每 commit 是保留铁律；是否在其上**叠加**更重的对抗审（如 ultracode 五视角）按风险分级评估——沾并发/事务/状态机/安全/跨端语义任一 → 全开；复刻既有范式/纯展示 → 砍；且**开启对抗审必先向用户声明（开启即告知，绝不静默开）**。分级判据的权威源在项目 auto-memory：当前项目存在 `feedback_assess_heavy_review_before_invoking.md`（示例项目 2026-07-03 沉淀）则按其执行；无该文件的项目默认只走本 SKILL 的 codex 审节点。

### 方案阶段触发节点

| 触发点 | 是否必审 | 侧重 |
|---|---|---|
| 方案 v0.1 大纲拍板**后** | ✅ 必审 | 决策点是否漏 / 边界是否清楚 / 是否过度设计 |
| 方案 v1.0 全文写完**后** | ✅ 必审 | 实现可行性 / 接口契约 / 边界 case / 隐藏假设 |
| 方案修订累计 ≥ 5 处**后** | ⚠️ 建议审 | 防止反复审不收敛，触发"β+γ 战略选择"门槛 |
| 方案审反复 ≥ 3 轮仍不收敛 | 🚨 战略选择 | 跳方案直接编码 / 砍范围推后 / 接受方案带"已知风险"上线（参考 5/22 v3.0 β+γ 战略） |

### 编码阶段触发节点

| 触发点 | 是否必审 | 侧重 |
|---|---|---|
| 每个 commit **后** | ✅ 必审（含豁免清单，见下方） | diff 实际落地是否符合方案 + 是否引入潜在 bug/风险 |
| 多个小 Step 合并为 1 commit | ⚠️ 按 commit 节奏走 | 不按 Step 节奏走（5/24 复盘共识：Step ≠ commit） |
| 编码完成、部署前 | ✅ 必审 | 完整改动集回归 + 历史功能影响面（可选合并到最后一个 commit 后审） |

### 复审后分流规则（2026-06-02 v1.74.0 复盘固化，8 次验证）

codex **首审**一个 commit 后，按 issue 严重度决定后续怎么走——是否要"复审"（修订后再审一轮确认修对+无新 bug）：

| 首审结果 | 处置 |
|---|---|
| **有 high / critical** | 必须修 → 修订后**走一次复审** → 复审 0 high 才放行 |
| **复审后仍有 high** | 继续修 + 再复审，直到复审无 high（不放行带 high 的 commit）|
| **首审 0 high（仅 medium / low）** | **当前阶段该改的 medium 在当前 commit 周期内修掉（不拖版本、不单独为它复审），搭车进下一个 commit 的 codex 审**；**后续阶段才碰的 medium 记 todo** |
| **首审 0 issue** | 直接放行 |

**⚠️ 分流规则不豁免拍板环节（2026-06-10 硬化）**：本规则只管"修完要不要**复审**"，**不管"动手前要不要拍板"**——任何 severity（含 0-high 的 medium/low、含"核实后建议不采纳"项）都必须先走 4 件套呈现 + 用户拍板，**用户确认后才能动代码**。"当场改完"指修复的时间窗口（当前 commit 周期），不是跳过决策环节的授权；"用户历史上总是全按"也不构成先斩后奏的依据——全按是用户行使决策权的结果，不是让渡。**先修后呈现 = 把既成事实给用户看，违反本 SKILL 角色定位（Claude 替用户判断采纳与否即越权）**。踩坑来源：2026-06-10 codex 83/84 两轮 0-high 审，Claude 把"当场改完"过度解读为免拍板直接修 + commit，被用户当场纠正。

**0-high 特例（规则是触发下限，非禁止上限）**：首审 0 high 本可不复审，但若该 commit 含**结构性改动**（如事务重构 / 中间件顺序 / 权限边界），用户可主动选"稳妥走一次轻复审"。复审权由用户拍板，Claude 不主动加复审也不阻止用户加。

**与豁免规则的关系**：
- 本规则管"审过之后要不要复审"；豁免规则（下方）管"这个 commit 要不要审"。两者正交。
- `fix` 类若是"已 codex 审过的同主题 critical 修复补丁"，按豁免规则可由用户拍板**豁免复审**（如 v1.74.0 H-1 修复：codex 自己提的 issue + Claude 按 fix_points 落地 + 纯前端可见性收紧后端真闸门没动 → 用户拍板豁免）。

**操作流程**：
- 首审出 high → Claude 先 4 件套呈现 + 用户拍板 → 按拍板修订 → 主动准备复审 brief（聚焦"high 修对没 + 有没有引入新 bug"）→ 用户拍板启动复审。
- 首审 0-high → Claude **先 4 件套呈现 + 拍板汇总表**，提示"首审 0 high，按分流规则修完可不复审；若你认为本 commit 是结构性改动想稳妥复审，可拍板"→ **用户拍板后**才修，修完搭车下一 commit。
- **不允许 Claude 自己决定跳过该走的复审**（high 必复审）；也不主动给 0-high 加复审（避免过度审）；**任何 severity 都不允许先修后呈现**（见上方"分流规则不豁免拍板环节"）。

**验证来源（8 次，边界已稳定）**：C2/C3/C4 基础流转（high→复审→放行）→ C4a high→复审 → C5 首个 0-high 用户主动复审（揭示"下限非上限"）→ C6b/C6c high→复审 + 0-high 主动复审 → H-1 fix 豁免复审。覆盖了基础流转 / 0-high 处置 / medium 搭车 / 结构性改动主动复审 / fix 豁免五类边界。

### 编码阶段豁免规则（5/24 v1.71.0 复盘新增）

以下 commit 类型**可由用户拍板豁免** codex 审（Claude 不能自己豁，必须问用户）：

- `chore`：仅改 README / CLAUDE.md / 注释 / .gitignore / 目录结构调整 / 配置文件（非业务逻辑）
- `docs`：仅文档改动
- `fix`：已经 codex 审过的同主题 critical 修复补丁（避免重复审同主题）
- `test`：仅增加测试 / 验证脚本不改业务代码
- `refactor`：重命名 / 提取常量 / 调整文件位置类无行为变更的修改（用 grep 自检即可）

**豁免必须满足全部 3 条**：
1. 不引入新业务逻辑
2. 不动状态机 / 权限 / 事务边界 / 安全相关代码
3. diff 行数 ≤ 30 行（超过 30 行即使是 refactor 也建议审）

**操作流程**：
- Claude 看到 commit 满足豁免清单 → 主动提示用户"本 commit 属于 X 类型，diff Y 行，**建议豁免**，是否确认？"
- 用户拍板 → 豁免则跳到下一 commit；不豁免则正常走 codex 审 + 4 件套
- **不允许 Claude 自己豁免**：5/22 踩过的"Claude 替用户决定"反例，必须用户拍板

### 调用前必做

- 触发节点出现 → 主动准备 prompt + ContextFiles + sandbox 预检 + 预估耗时 → 用户拍板启动（半自动节奏）
- 用户拍板 = 手动触发（符合 SKILL "手动触发"原则；Claude 主动准备不等于自动启动）

## 默认工作流

1. **确认触发**：触发节点是否到达？用户是否明确要求？任一满足即启用此 skill。
2. **收窄任务**：把要审的东西收窄成一段明确的 brief（文件路径、要审什么、关注点、不要越权做什么）。
3. **选 TaskType 和 Mode**：默认 `spec-critique` + `advice-only`。
4. **组装 prompt**：优先使用 `references/prompt-templates.md` 里的模板，再补具体上下文。
   - **必查项目语境**：如果当前项目有 `project_*.md` 类型的记忆文件（如 `project_business_flow_scope.md`、`project_xxx_context.md`），把里面的"部署语境"/"容量设想"/"不在范围"等关键约束**摘到 prompt brief 顶部**——避免 codex 按通用 SaaS 高并发场景给不适用的意见。
   - 摘录格式建议：`# 项目语境（必读）\n本项目是 XX，部署在 YY，最大并发 N 人...请把建议聚焦在该场景，不要按"对外 SaaS / 高并发 / 大规模"给意见。`
   - 不要把整个项目记忆文件喂给 codex（太长 + 含敏感信息），只摘"影响审查口径的硬约束"。
   - ⚠️ **大文件先截 snippet 再喂，不要让单文件吃 80% 预算**：invoke_codex.ps1 按 `-ContextFiles` 顺序贪心装载，单文件超过 `MaxContextChars` 剩余预算时直接标 `skipped-context-budget` 跳过；若第一个文件就吃光预算，**后续文件全部跳过且 codex 不会主动告知**（只在 prompt 里留 `status="skipped-context-budget"` 标记）。表现：codex 报告里出现"无法给最终结论"+"X 个文件被截断/跳过"，confidence 降为 medium。
   - **判断准则**：单文件 > 50KB 或预计占 MaxContextChars > 50% 时，必须先 `grep -n "^(app\.|function|class)" + sed -n '<start>,<end>p'` 截关键段，目标 ≤ 30KB/文件。验证方式：跑完后 grep prompt 文件 `<file path.*status="skipped-context-budget"`，应为 0 个。
   - **检查方法**：调用结束后立即核 `<output>.prompt.txt`，看每个 `<file path="..."` 后面是否带 status 属性。无 status 才是真正读进去了；带 status 的都是没读到。如果有 `skipped-context-budget`，整轮审查需要重跑（confidence 不可信）。**用 Grep 查不要通读**（prompt.txt 含全部上下文文件正文，通读极耗 token）：`Grep pattern="skipped-context-budget" path=<prompt.txt>` 应 0 命中；顺带核 wrapper JSON 的 `contextFilesCount` 是否等于传入文件数。
   - 历史踩坑：2026-05-19 codex 十六审首轮直接传 server.js 全文 200KB + 5 个其他文件，server.js 一个吃光 200000 字符预算，其他 5 个全跳过，confidence=medium 不可用。第二轮截 server.js snippet 59KB 后 5 文件全 included，confidence=high。
5. **报预估耗时 + 选执行模式**（关键原则）：调脚本前必须先告诉用户预估返回时间，让用户决定"等还是去做别的"。然后按预估**选执行模式**。

   **预估口径**（基于业务全景图实战校准）：
   - 短任务 30-90 秒：advice-only / 单 prompt + ≤80KB context / 单文件代码审 / 项目语境前置已聚焦
   - 中等任务 90-180 秒：advice-only / 80-150KB context / 多文件交叉审
   - 长任务 180-600 秒：spec-critique / 大方案审 / 历史多轮迭代审 / 复杂取舍
   - 超长任务 ≥ 5 分钟：复杂 deep-thinking / 跨项目对照 / 整章方案审

   **执行模式按预估分两档**：

   **A. 短/中等任务（≤ 3 分钟预估）→ 阻塞模式（默认）**

   直接同步调 invoke_codex.ps1，一次 tool call 内等结果：
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Users\<USER>\.claude\skills\codex-cli-bridge\scripts\invoke_codex.ps1 `
     -TaskType spec-critique `
     -Mode advice-only `
     -Prompt "审这份方案的权限口径和状态机..."
   ```
   优点：脚本自管 stdin/stdout/超时；失败时直接返回 wrapper JSON；用户体验"调用 → 等 N 秒 → 出结果"清晰简单。

   **B. 长任务（> 3 分钟预估）→ 后台模式 + ScheduleWakeup**

   长任务用阻塞模式会让 Claude 一个 tool call 挂着 5+ 分钟，期间用户看不到任何进度。改成后台模式让用户能看到倒计时：
   1. 用 `Bash run_in_background=true` 启动 invoke_codex.ps1（或直接用 codex exec 命令）
   2. 用 `ScheduleWakeup delaySeconds=<预估秒数>` 设个闹钟，例如 `delaySeconds=300` → 用户看到 `Next wakeup scheduled for HH:MM:SS (in 300s)`
   3. 闹钟响后读 wrapper JSON 处理结果

   触发条件：codex 进程预估 > 3 分钟、或 context > 150KB、或之前同类任务实测过长。

   **判断不准时的兜底**：
   - 默认走阻塞模式（A），但调用前在话术里说"如果 X 分钟没返回我会切到后台模式让你看到倒计时"
   - 跑完后如果实测远超预估（比如预估 90 秒实际 300 秒），下次同类任务直接走后台模式（B）

   **A 阻塞模式 - 带文件上下文**（推荐，中文路径友好）：
   ```powershell
   $ctx = @(
     "docs\local\数据协作模块_一阶段方案.md",
     "wbs-server\server.js"
   )
   & "C:\Users\<USER>\.claude\skills\codex-cli-bridge\scripts\invoke_codex.ps1" `
     -TaskType spec-critique `
     -Mode advice-only `
     -Prompt "对照下面的方案文档和 server.js，审状态机一致性" `
     -WorkingDirectory "C:\projects\example-project" `
     -ContextFiles $ctx `
     -MaxContextChars 80000
   ```
   ⚠️ **必须用 `@(...)` 数组语法**：写成 `-ContextFiles "a","b","c"` 时 PowerShell（取决于调用方式）可能把它收成单个字符串 `"a,b,c"`，脚本会当成单一文件路径找不到然后标 `status="missing"`，codex 表面上跑成功但实际只看到 brief 没看到附件。检查方法：跑完后看输出 JSON 里的 `contextFilesCount` 是否等于你传入的文件数；如果是 1（实际传了多个）就是踩了这个坑。

   **A 阻塞模式 - 让 codex 直接读项目**（仅英文路径，很少用）：
   ```powershell
   ... -IncludeProject -WorkingDirectory "C:\path\to\repo-in-ascii"
   ```

   **B 后台模式 - 推荐用法**：
   ```
   1. Bash run_in_background=true：
      powershell -File invoke_codex.ps1 -PromptFile X -ContextFiles ... -TimeoutSeconds 1200
   2. ScheduleWakeup delaySeconds=<预估秒数> reason="等 codex 跑完 X 审"
      用户立刻看到 "Next wakeup scheduled for HH:MM:SS (in Ns)"
   3. 闹钟响后 Read wrapper JSON 处理结果
   ```
   注：codex 调用结果文件路径在 wrapper JSON 的 `outputPath` 字段，这个路径在脚本启动时就已确定，可以提前存下来在闹钟响后直接 Read。
6. **读结果**：**默认读 `<output>.final.txt`**（Codex 最终消息纯正文）。

   ⚠️ **不要默认通读 `*.json`**（2026-08-31 加）：wrapper JSON 把同一份报告存了**两遍**——`finalMessage`（转义字符串）+ `structuredResponse`（对象），通读等于双倍 token。正确姿势：
   - 要报告内容 → 读 `*.final.txt`
   - 要元数据（`exitCode` / `timedOut` / `contextFilesCount` / `codexVersion` / 各 path 字段）→ `Read *.json limit=25`，这些字段都在文件头部，正文在其后
   - 只有 `structuredResponseParsed=false`（Codex 返回非法 JSON）时才需要人工读 final.txt 全文排查

   **踩坑来源**：2026-08-31 数仓会话单日 5 次调用全部通读 wrapper JSON，白读 5 份报告的量。
7. **呈现 codex 原话 + Claude 4 件套建议**（关键原则）：先按 severity 分组展示 codex 原话，紧接着对每条 issue 给出 Claude 4 件套建议。最终决策权仍在用户。
   - **第一层（codex 原话）**：按 `issues[].severity` 分组（critical / high / medium / low），每条只展示 codex 原话：category、location、problem、suggestion；附上 recommendations、risks、notes_for_claude_code 三段
   - **第二层（Claude 4 件套建议，默认必走）**：对**每条 issue**给出以下 4 件套（issue 越多越值得走完整，0 issues 可降级）：

     ```markdown
     ### <severity>-<编号>（<severity> / <category>）<location>

     > codex 原话：<problem>
     > codex 建议：<suggestion>

     **💡 我的建议：[采纳 / 部分采纳 / 不采纳]**

     **采纳的理由**：<2-3 句，含本地真相 / 项目语境 / codex 没看到的事实>
     **不采纳的理由**：<2-3 句，反过来选的合理性，让用户能反着选；找不到也明确写"找不到反向理由">
     **🔟 第十人视角**：<5 角度任选 1 个，至少 1 条实质反驳；找不到也写"找不到，已走流程"。详见 shared-memory feedback_tenth_man_rule_in_ai_review.md>
     ```

   - **降级规则**（按 codex 输出复杂度自适应）：
     | codex 输出场景 | 4 件套走法 |
     |---|---|
     | ≥ 1 条 critical/high/medium/low issue | 4 件套**完整走**（不可降级） |
     | 0 issues + 有 recommendations/risks | 对每条 rec/risk 走"采纳建议 + 一句话理由"（双向理由 + 第十人可省） |
     | 0 issues + 0 recommendations + 0 risks | 一句话"通过，可进入下一步" |

   - **第三层（拍板节奏，5/24 v1.71.0 复盘批量化优化）**：呈现完所有 codex 原话 + Claude 4 件套建议后，在末尾加一个**汇总表格**让用户批量拍板：

     ```markdown
     ## 拍板汇总表

     | # | severity | 我的建议 | 一句话核心理由 |
     |---|---|---|---|
     | M-1 | medium | 采纳 | 攻击面真实存在 |
     | M-2 | medium | 不采纳 | 项目无此场景 |
     | L-1 | low | 部分采纳 | 原则采纳但范围缩小 |
     | ... | ... | ... | ... |

     **请回**（任选一种）：
     - **「全按」**——所有建议按推荐走
     - **「#X 改成 Y」**——某几条改判（如"#2 改成部分采纳"）
     - **「#X 想讨论」**——某条想展开讨论再定
     - **「全展开」**——所有意见的双向理由 + 第十人都展开（默认已展开，此选项备用）
     ```

   - **不折叠**：所有 severity 的 4 件套（含 medium/low）**默认完整展开**双向理由 + 第十人视角，让用户能看到全貌再批量拍板；汇总表是**额外的快速决策入口**，不替代展开内容（5/24 用户拍板修订：避免"看不到全貌反踩 5/24 同样坑"）
   - **Claude 不替用户拍板**——4 件套是"我的建议"，最终决策权仍在用户；汇总表是给用户**省点击次数**，不是省判断
   - **关闭 4 件套的唯一场景**：用户明确说"这次只看 codex 原话不要你的建议"。其他情况默认走 4 件套。
   - **呈现末尾**附上原始文件路径（`*.final.txt` / `*.json`），方便用户直接查看 codex 原文。

   **为什么默认开 4 件套**（2026-05-24 v1.71.0 Step 1 复盘修订）：
   - 历史踩坑：5/24 v1.71.0 Step 1 第二轮 codex 审完，Claude 严格按旧版 SKILL "默认不下结论"原则只展示原话不给建议，用户直接说"我没看到你的建议"——证明旧默认值与用户实际偏好相反
   - 双向理由是核心：没有"反过来选的理由"等于"Claude 替用户决定"，5/22 v3.0 14 条 issue 中 6 条"找不到反向理由"是假的（能找到只是没做），强制走 5 角度才解决
   - 一致性与 团队协作约定 三件套（双层汇报 / 独立推荐 / 先审取舍）原则一致——独立推荐本就是 Claude 的核心职责之一
8. **检查项目归档约定**（关键原则 / **必须与第 7 步同一轮回复完成**）：脚本默认输出落在 `%TEMP%`（系统临时目录会被清理），如果项目里已有持久化的审查归档目录，必须额外落一份到该目录，否则审查记录会丢。
   - **触发时机**：和"原样呈现给用户"在**同一轮 Claude 回复**里完成——先呈现 codex 报告（第 7 步），紧接着写归档文件（第 8 步），最后才把回复发给用户。**不要等用户下一条消息**——用户可能插入新话题，导致归档被遗忘。
   - **触发判断**：用 Glob/Grep 在项目里找类似 `docs/**/codex*` / `docs/**/审查记录` / `审查记录` / `code-review-log` 的目录，或读项目 README/CLAUDE.md 里有没有提到"AI 审查记录"约定。
   - **找到了**：按目录里现有文件的命名格式（编号 + 主题，如 `17-六审-xxx.md`、`code-review-2026-05-04-xxx.md`）顺延一个新文件，**直接套用下方固定模板**，不要临场编排结构。

     ```markdown
     # NN - <主题> <第N审>（YYYY-MM-DD）

     ## 元信息
     - 审查对象 / 复审焦点（聚焦式复审才写）/ codex 模式与版本 / confidence
     - 结果：<severity 计数>；关键正面结论（若有）
     - 原话档案：`_originals/NN-<主题>.final.txt`

     ## 第一层：非技术总结

     ## Claude 拍板记录（建议已给，用户决策待回填）

     | # | severity | 摘要 | Claude 建议 | 用户决策 |
     |---|---|---|---|---|
     | H-1 | high | ... | 采纳 / 部分采纳 / 不采纳 | （待拍板） |

     ## 第二层：codex 原话要点

     ## 落地记录
     （拍板后补）
     ```

     🔒 **硬约束（2026-08-31 加）**：新建归档时「用户决策」列一律写 `（待拍板）`、小节标题写"用户决策待回填"、落地记录写"（拍板后补）"——**这三处是必须原样写入的占位符，不是待填空白**。用户真实回复后才在第 10 步整体替换为「全按（日期）」等实际决策。

     **踩坑来源**：2026-08-31 数仓会话，同一天内**两次**（审查归档 10 号、12 号）把"用户决策"列直接预填成"全按"，当时用户尚未看到内容，两次均由 Claude 自行发现回滚。本步此前**已有**"先不写 Claude 判断 / 用户决策"的文字规则却照样违反——证明**光加文字约束无效，必须固化模板**：让预填决策需要主动删掉占位符（额外动作），而不是靠自觉不去填空。
   - **找不到**：不用强行建目录，跳过此步。但要在第 7 步的呈现末尾提一句"未发现项目审查归档目录，本次记录仅在 %TEMP%"，让用户知道。
   - **不要假装**：如果你不确定项目是否有归档约定，直接问用户"要不要落一份到 docs/xxx/"，不要默认创建。
   - **自检**：发回复给用户前，问自己一句"这轮 codex 报告归档了吗？"——如果答 No 且项目有归档目录，回头补；如果答"等下一轮再补"，那就是错的。
9. **等用户逐条判断**：用户说采纳哪些、不采纳哪些、需要讨论哪些。
10. **回写决策到归档**（如果第 8 步落了归档文件）：用户点完后，把"Claude 判断 / 用户决策 / 落地动作"追加到归档文件末尾。这样未来 git blame / 项目复盘时能看到完整闭环，而不只是 Codex 原话。
11. **按用户确认的意见落地**：改文件、跑验证、commit 由 Claude Code 执行。

### 角色定位（此工作流固化）

- **Codex** = 审核人（给原话意见）
- **用户** = 决策者（逐条判断是否采纳）
- **Claude Code** = 报告员（展示 Codex 原话）+ 执行者（按用户确认的意见改动）

任何一环越权（比如 Claude 替用户判断采纳与否）都违反此 skill 的设计。

## Prompt 约束

- 明确任务类型、模式、审核对象范围
- 明确不要越权：不要让 Codex 宣称已改文件、已验证
- 要求 Codex 返回结构化 JSON（脚本会自动加 scaffold）
- 审核类任务默认中文输出（面向中文用户）

## 脚本约束

- **默认只读沙箱**：`--sandbox read-only`，Codex 不能改本地文件
- **默认不读取项目文件**：除非用户传 `-IncludeProject` 或 `-ContextFiles`
- **强制 JSON 输出**：`--output-schema` + scaffold prompt 双重保证（脚本自动生成并复用 schema 文件）
- **非交互模式**：`codex exec`，不是交互式 TUI
- **落盘四件套**：prompt / raw / final / wrapped JSON，便于回溯
- **默认超时 300 秒**：超时后强制终止，避免 PowerShell 进程悬挂
- **记录 codex --version**：每次调用的 codex 版本写入 wrapper JSON

脚本关键参数：

| 参数 | 说明 |
|---|---|
| `-Prompt` / `-PromptFile` | 审核任务描述（brief） |
| `-TaskType` | spec-critique / code-review / sql-review / general-assist |
| `-Mode` | advice-only / draft-only |
| `-OutputLanguage` | zh-CN（默认）/ en-US |
| `-Model` | 默认不指定，让 codex 用配置的默认模型 |
| `-WorkingDirectory` | 脚本的工作目录（用于决定输出位置；codex 实际 -C 永远在安全英文目录）|
| `-ContextFiles` | **推荐的上下文传递方式**：Claude 读取指定文件，拼入 prompt。Codex 不直接访问项目文件。支持中文路径。|
| `-MaxContextChars` | `-ContextFiles` 的总字符预算，默认 60000，超出则截断 |
| `-IncludeProject` | **风险路径**：给 codex `--add-dir <WorkingDirectory>`，让 codex 直接读项目。仅当 WorkingDirectory 纯 ASCII 时可用（中文路径会触发 codex websocket UTF-8 bug，脚本会直接报错）|
| `-TimeoutSeconds` | codex 调用超时，默认 300，范围 30-1800 |
| `-RawPrompt`（开关）| 跳过 scaffold 包装，用原始 prompt 调 codex（调试用） |
| `-Api`（开关） | **API 中转模式**：走中转 API（按量付费）而非订阅。**仅当用户显式说"走 API / 走中转"时传**，未显式说明一律默认本机订阅（见「审查路径」节） |
| `-ApiEnvFile` | `-Api` 读取的 .env 路径，默认项目根目录的 `.env`（取 `CODEX_API_KEY` + `CODEX_API_BASE_URL`） |
| `-Remote`（开关） | **远端订阅模式**：把 codex 调用经 SSH 发到另一台机器执行，用那台机器上的第二个 ChatGPT 账号。**仅当用户显式说"走第二订阅 / 走远端 / 走家里那台"时传**。与 `-Api`、`-IncludeProject` 互斥（见「远端订阅模式」节） |
| `-RemoteTarget` | `-Remote` 的 SSH 目标，通过 `-RemoteTarget user@remote-host` 或 `CODEX_BRIDGE_REMOTE_TARGET` 环境变量指定，无内置主机 |
| `-RemotePreflight`（开关） | 只验远端链路（SSH / codex 可执行 / ChatGPT 登录态），不跑审核、不耗额度；输出末行 `REMOTE_PREFLIGHT_RESULT=PASS\|FAIL` 供机器判定 |

**`-IncludeProject` 与 `-ContextFiles` 互斥**，同时传会直接报错。优先使用 `-ContextFiles`：安全路径、中文路径友好、细粒度可控。仅在需要 codex 动态探索整个项目时才用 `-IncludeProject`（且项目路径必须是纯 ASCII）。

## 审查路径（三轨）——默认本机订阅，显式指定才切换

codex 审查有三条计费路径：

| 路径 | 开关 | 计费 | 认证 |
|---|---|---|---|
| **本机订阅**（默认） | 不传开关 | 本机 ChatGPT 订阅额度 | 本机 `~\.codex\auth.json` |
| **API 中转** | `-Api` | 按量付费 | 隔离 CODEX_HOME + key |
| **远端订阅** | `-Remote` | 远端机器上第二个 ChatGPT 账号的订阅额度 | 凭据只在远端，本机不存 |

**规则（用户 2026-09-09 拍板，取代 2026-09-02 的"未指定先问"）**：

- 用户说「走 codex 审」**没说走哪条** → **默认本机订阅，直接动手，不问**
- 用户显式说「走 API / 走中转」→ 传 `-Api`
- 用户显式说「走第二订阅 / 走远端 / 走家里那台」→ 传 `-Remote`
- 同一会话内用户已显式指定且未改口 → 后续送审沿用；**新会话回到默认本机订阅**（路径与费用挂钩，不跨会话记忆）——此条限**长任务之外**；长任务段内以其启动门的选择为准，不与"默认 API"例外冲突
- `-Api` 与 `-Remote` 互斥，脚本层直接 throw
- 例外：长任务段内按 long-task SKILL 的通道规则（见文末「通道选择」）

### API 中转模式（`-Api`）实现要点

- `-Api` 读 `.env` 的 `CODEX_API_KEY` + `CODEX_API_BASE_URL`（端点由用户自行配置）；隔离 CODEX_HOME，auth.json 只含 key，不碰订阅登录态
- 默认模型 `gpt-5.6-sol`（`-Model` 可覆盖）。首次使用前，请自行确认所配置端点与模型可用。
- 与计费路径无关的送审纪律照常有效——`-ContextFiles` 喂材料、显式抬 `-MaxContextChars`、送后核 `skipped-context-budget`、多文件先合并再送（`-File` 数组坑）、超时重试前隔离原 run 文件

## 远端订阅模式（`-Remote`）

**目的**：本机 codex 账号撞额度墙时，借用另一台自有机器上第二个 ChatGPT 账号的订阅额度。凭据永远不离开那台机器，本机不登录第二账号、不搬 auth.json。2026-09-09 端到端实测打通并经三轮 codex 审收敛（此脱敏副本不附带原始历史）。

**链路**：本机 → SSH（密钥认证）→ 用户配置的网络 → 远端 Windows → Codex CLI。

**远端只需要两样东西**：codex CLI + 第二账号登录态。不需要项目代码、git、.env——`-ContextFiles` 已由 Claude 在本机读文件拼进 prompt，随 prompt 一起送过去。因此 `-Remote` 与 `-IncludeProject` 互斥。

**执行五步**：远端建目录（顺带回收 6 小时前的陈旧目录）→ scp 上传 prompt+schema（远端启动 codex 前按本机记录的字节数校验两份输入，不一致即报 `[upload]` 失败，不跑）→ ssh 执行（远端复刻本机的 Start-Process 三路重定向）→ scp 拉回 raw/stderr/final（先下到 `.part` 校验大小再原子改名）→ finally 清理远端目录。

**清理是"尽力"而非"保证"**（2026-09-09 复审校准，此前文档写过头）：
- 远端执行脚本自带 finally 删 prompt.txt，本机断线时它仍会跑；wrapper 的 `remote.promptPurged` 回报结果，`false` 时 Claude 主动告警
- 但**上传期间断线**（远端脚本尚未启动）、**远端宿主被强杀**等情况下无法保证；6 小时回收**只在下次调用建目录时触发**，是回收阈值不是最长保留期——之后再不调用，残留会一直在
- **远端 codex 会像本机一样把整个会话（含 prompt 全文）持久化到 `~\.codex\sessions\`**。实测确认（55KB rollout 含被审 prompt）。这与本机路径行为完全一致，不是远端引入的新暴露面；那台机器是自有设备，按 2026-09-09 决策**接受并如实记录，不承诺"远端不保留代码"**。真正成立的边界是：凭据不离开远端、传输不经第三方明文、远端临时目录尽力清理

**用前先跑预检**：`invoke_codex.ps1 -Remote -RemoteTarget user@remote-host -RemotePreflight`，按 local / ssh / codex / auth 四层给诊断。久未使用、Tailscale 重登、远端重装 codex 后都该先跑。

**远端 codex 的 OAuth token 过期后需人到那台机器前重跑 `codex login`**（浏览器流程，SSH 里做不了），预检会报 `stage=auth`。

**实测坑（解药已固化在脚本注释里，改动前先读）**：

1. SSH 非交互会话里 codex 不在 PATH（PATH 里那个 `OpenAI\Codex\bin` 是空目录）→ 用绝对路径
2. `packages\standalone\current` 是 Junction：**执行**穿过它的路径会报重解析点错误，但 `Get-Item -Force` 读 `.Target` 正常 → 首选读 Junction 指向定位当前启用版本，按目录时间猜只作兜底
3. `codex exec` 会读 stdin，不给 EOF 会挂 → ssh 一律 `-n`
4. 远端工作目录非 git 仓库 → `--skip-git-repo-check`
5. 远端中文输出是 GBK → 远端命令前 `chcp 65001`
6. ssh→cmd→powershell 多层引号解析，`|` 会被 cmd 当管道符 → 远端命令一律 Base64 `-EncodedCommand`
7. PS 5.1 对原生命令用 `2>&1` 会把 stderr 包成 NativeCommandError，遇 `$ErrorActionPreference=Stop` 直接掀脚本 → 改 Start-Process 文件重定向
8. **PS 5.1 的 `Start-Process -PassThru` 读不到子进程退出码**（HasExited=True 但 ExitCode 为空，本机与远端均复现）→ 退出码一律标不可信，成败看输出标记 + 文件大小；wrapper 的 `remote.exitCodeKnown=false` 即此含义
9. `-o LogLevel=ERROR` 会连真实连接错误一起吞掉，故障时诊断全空 → 不用它，改为读到后按行过滤 known_hosts 告警
10. scp 的 `host:path` 与 Windows 盘符冒号打架 → 远端路径一律"相对家目录 + 正斜杠"
11. 远端脚本经 UTF-16LE+Base64 塞进一行 `-EncodedCommand`，膨胀约 2.7 倍；超过 Windows 8191 字符上限时 sshd 侧只回一句 GBK "命令行太长"，本机读成一行乱码（表现为 `ssh exit=-1` + 乱码）→ 注释行不上传 + 超 7500 明确报错。**模板约束**：远端模板里不得有多行字符串内以 `#` 开头的行，新增内容须重查

**刻意不做**：ssh 连接复用 / 远端自动安装登录 / 远端不可达时自动回退本机订阅（静默换账号换计费比失败更糟）/ 断点续传重试 / 第三方 PowerShell 模块 / 独立于下次调用的远端定时清理（要在那台机器注册计划任务，超出本 SKILL 边界）/ 删除或关闭远端 codex 的 rollout 持久化（本机也不做，威胁模型不变）。

**远端准备清单**（新机器接入时照做）：装 Tailscale 登同一账号 → 管理员 PowerShell 启用 OpenSSH Server（`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`，`Set-Service sshd -StartupType Automatic`）→ 本机公钥写入 `C:\ProgramData\ssh\administrators_authorized_keys`（管理员账户不认 `~\.ssh\authorized_keys`；用 `-Encoding ascii` 免 BOM；`icacls` 用 SID `*S-1-5-32-544` / `*S-1-5-18` 收权限）→ 那台机器上 `codex login` 登第二账号 → 本机跑 `-RemotePreflight`。

## 输出产物

输出目录：
- WorkingDirectory 为纯 ASCII：`<WorkingDirectory>\tmp\codex-runs\`
- WorkingDirectory 含非 ASCII（如中文）：`%TEMP%\codex-bridge-workspace\runs\`（自动切换到英文路径）

文件组（每次调用 5 个）：
- `codex_<TaskType>_<timestamp>.prompt.txt`：实际发给 Codex 的完整 prompt（含 bridge scaffold + 可选 context files 内容）
- `codex_<TaskType>_<timestamp>.raw.jsonl`：**纯 stdout**——Codex 原始 JSONL 事件流，可被 `jq -c` 等工具直接流式消费
- `codex_<TaskType>_<timestamp>.stderr.txt`：**纯 stderr**——schema 校验错误、登录/连接错误等 CLI 非结构化输出。超时标记**不**写入此文件，只在 wrapper.timedOut 字段
- `codex_<TaskType>_<timestamp>.final.txt`：Codex 最终消息（Codex `-o` 参数直接写入）
- `codex_<TaskType>_<timestamp>.json`：包装后的结构化结果（Claude Code 主要消费这个）

包装 JSON（wrapperVersion=2）含：
- 元数据：`taskType` / `mode` / `outputLanguage` / `modelRequested` / `codexVersion` / `invokedAt` / `workingDirectory`
- 调用参数回显：`includeProject` / `contextFilesCount` / `maxContextChars` / `timeoutSeconds` / `promptScaffoldVersion`
- 结果：`exitCode` / `timedOut` / `finalMessage` / `structuredResponseParsed` / `structuredResponse`
- 路径：`outputPath` / `rawOutputPath` / `stderrPath` / `promptPath` / `finalMessagePath` / `schemaPath`
- 计费路径：`apiMode` / `remoteMode`；`-Remote` 时另有 `remote` 块（`target` / `codexPath` / `codexResolvedBy` / `runId` / `exitCodeKnown` / `promptPurged` / `diagnostics`），否则 `remote=null`。**`exitCodeKnown=false` 表示 `exitCode` 是推断值**（PS 5.1 读不到子进程退出码），成败以 `finalMessage` 为准

**自动清理**：脚本启动时删除默认输出目录下 7 天前的 bridge 命名文件（`codex_*.{prompt.txt|raw.jsonl|stderr.txt|final.txt|json}`）。自定义 `-OutputPath` 的目录**不自动清理**，避免误删用户其他文件。

## 采用规则

- **Codex 输出默认是建议稿，不是真相源。**
- 如果 Codex 建议与当前代码/运行结果/用户明确意图冲突，以本地真相源为准。
- 最终采纳与否由用户拍板，Claude Code 只做整理和建议。
- 不要把 Codex 输出当成"权威审核"。它和 Claude Code 是同级别模型，只是第二视角。
- 如果 Codex 输出明显偏离（比如审的是方案但它给了代码补丁），视为 Codex 越权，Claude Code 过滤掉越权内容。

## 失败处理

如果脚本调用失败，按这个顺序排查：

1. `codex` 命令是否可用（`codex --version`）
2. 是否已登录（`codex login` 检查，使用 ChatGPT 订阅）
3. 工作目录是否存在
4. Codex 输出是否返回了非结构化文本（`structuredResponseParsed = false`）
5. 是否超时（`timedOut = true`）
6. 模型配额是否用完
7. `-Remote` 时先跑 `-RemotePreflight`，按 `stage=local/ssh/codex/auth` 定位是本机缺 ssh、Tailscale/sshd 不通、远端 codex 不可执行、还是远端登录态失效/非 ChatGPT 订阅

失败时 Claude Code 应当：

- 先从 wrapper JSON 里读 `exitCode` / `timedOut` / `finalMessage` 做**摘要性判断**，用一两句话告诉用户"看起来是什么原因"
- **附上 `rawOutputPath`（stdout）和 `stderrPath`（stderr）两个路径**，让用户自己决定要不要打开。schema/登录/连接类错误通常在 stderr
- **不要默认贴 `raw.jsonl` 全文**——该文件可能很长，含 prompt / 路径 / 上下文等敏感信息
- 只有用户明确说"把日志给我看看"时，再去读取具体片段并提供

常见失败情景对应的 Claude Code 话术：

| 信号 | 摘要话术 |
|---|---|
| `timedOut = true` | "Codex 调用超过 {timeoutSeconds} 秒未返回，已强制终止。stdout：{rawOutputPath}；stderr：{stderrPath}" |
| `exitCode != 0` 且 `finalMessage` 为空 | "Codex 没有返回最终消息，可能是登录过期、schema 校验失败或配额用完。错误原因通常在 stderr：{stderrPath}；建议先跑 `codex --version` / `codex login` 确认。" |
| `structuredResponseParsed = false` | "Codex 返回了文本但不是合法 JSON，脚本无法解析。final.txt 路径：{finalMessagePath}，需要你人工读一下" |
| `-Remote` 预检 throw（`stage=ssh`） | "远端链路不通：{ssh 报错原文}。按序查两端 Tailscale 是否在线、远端 sshd 是否在跑、公钥是否在 administrators_authorized_keys。要不要这次先回退本机订阅？"（**不自动回退**，等用户拍板） |
| `-Remote` 预检 throw（`stage=auth`） | "远端不是 ChatGPT 订阅登录：{LoginStatus}。继续会静默变成按量付费，已停下。需要到那台机器前面重跑 `codex login`。" |
| `-Remote` 执行 throw（`[upload]`） | "上传后远端校验大小不一致（{UPLOAD_MISMATCH}），已停在启动 codex 之前，没有消耗额度。重跑即可；反复出现则查网络稳定性。" |
| `-Remote` 执行 throw（`[download]`） | 按 throw 里 `[state]` 行分述，不预设原因："final.txt 未能取回（远端 FINAL_SIZE={n}）。远端执行状态：timedOut={…}、promptPurged={…}。" FINAL_SIZE=-1 说明远端根本没生成（看 stderr 拉回了没）；FINAL_SIZE≥0 但取不回才是传输问题。清理是否成功以 `[diag]` 为准，不要断言"目录已清理" |
| wrapper `timedOut=true`（`-Remote`） | 与本机超时同话术；`remote.diagnostics` 里有远端 `CODEX_KILLED` 与 `promptPurged`，一并给出 |
| `remote.promptPurged = false` | **主动告警**："远端 prompt.txt（含被审代码原文）未能删除，请到 {remoteDir} 手工确认"——这是安全事项，不等用户问 |

## 已知限制

- **路径含空格未充分测试**：脚本通过 `Start-Process -ArgumentList $arguments` 传路径给 `codex.cmd`（再转 node.exe），若 `$env:TEMP`、`WorkingDirectory`、`-OutputPath` 等路径里包含空格（如 `C:\Users\John Doe\...`），argv quoting 在 `.cmd` shim 层的行为未验证，可能出现参数被误拆的风险。当前中文开发者账户常见路径（`C:\Users\<USER>\...`、`C:\projects\example-project\...`）都无空格，所以未做 quoting 处理。如果未来真遇到含空格路径，需要补一个 argv quoting 工具函数。**`-Remote` 继承同一限制**（远端也是 `Start-Process -ArgumentList`，远端用户目录含空格同样会拆参）——codex 审曾把它当新缺陷报 high，实为既有已接受限制；要修应单开 commit 同时修两侧，不借远端改造之名做本机重构。
- **`-Remote` 下 `-Model` 只允许 `[A-Za-z0-9._\-\[\]]`**：它会被拼进远端脚本，字符集收紧是防注入。本机路径不受此限。

## 旁路用法：生图（image-gen）

> 这是本 skill 的一个**旁路能力，不走 read-only 审核主流程**，与上面所有约束物理隔开。仅在用户明确要"让 codex 生图 / 配图 / 画示意图"时按需用。审核类任务一律走主流程，不要混用。

**原理**：codex CLI（实测 0.133.0）内置 `image_gen` 工具，底层是 OpenAI 的 `gpt-image-2` 模型（2026.04.21 起为默认）。在 prompt 里写 `$imagegen` 触发，可直接产出 PNG。生图计入 codex 用量额度。**它画不准精确数字/刻度**——数据图表（柱状/折线/精确数值）应由 Claude 手写 SVG，codex 只生「概念示意图」（架构、隐喻、分层、对比关系）。本次实战即「数据项 Claude 手绘 SVG + 定性项 codex 生图」的混合方案。

**与审核主流程的 5 处关键差异**（照搬主流程会失败）：
- **⚠️ 代理前缀必带（2026-07-17 定案·最易误诊）**：命令前必须加 `HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897`。本机走本地代理（注册表用户级 ProxyEnable=1），但 Claude 的 shell 环境**没有**代理环境变量，codex（Rust）只认环境变量不读注册表 → 不带前缀时生图请求直连 `chatgpt.com` 必死，报 `network error: error sending request for url (.../images/generations)` 或干脆卡死数分钟无输出——**报错像网络故障，根因是没走代理**。文字审核请求（小 payload）偶尔能直连成功，所以审核主流程从来没暴露这个问题、文字探针通过也≠生图链路健康。误诊代价：曾先后错怀疑 exec 模式/沙箱策略/工作目录，耗一整晚。
- **沙箱**：生图必须 `--sandbox workspace-write`（要写文件），不是主流程的 `read-only`。
- **不走 `invoke_codex.ps1`**：生图直连 `codex exec`，封装脚本的 JSON schema 对生图无意义。
- **产物落点**：图存到 `$CODEX_HOME/generated_images/<id>/*.png`（通常 `C:\Users\<USER>\.codex\generated_images\`），codex 也会尝试复制一份到 `-C` 工作目录。**codex 报错/卡死 ≠ 没出图**——先查 `generated_images` 会话目录再下失败结论（2026-07-17 一次 network error 的会话目录里实际躺着 2.1MB 成品图；有效图约 1-2MB，几十 KB 是失败残留）。
- **EPERM 踩坑**：codex 沙箱对 **E 盘等非工作盘写二进制会报 EPERM**。对策——让 codex 在 `%TEMP%\claude\` 等可写目录生图，再由 **Claude（无沙箱）复制到目标中文路径**。长中文 prompt 先写文件再 `cat` 喂入，避免命令行转义坑。

**可照抄的最小命令**（在可写目录生图；生成后由 Claude 复制到最终位置）：
```bash
HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 \
codex exec --skip-git-repo-check --sandbox workspace-write -C "<可写工作目录>" \
  "$(cat <prompt文件>)"
# prompt 文件内容形如：
# $imagegen 生成一张企业汇报概念示意图……（左墨绿#2E7D5B右暗红#C13838、米色羊皮纸#f5f4ed底、
# 扁平商务插画、不要任何文字数字、尺寸1024x1024、质量high、保存到 <可写目录>\xxx.png）
```
预估单张约 60-120 秒，多张用后台模式（`run_in_background` + `ScheduleWakeup`）。生成后用 PNG→宽760 JPEG q82→base64 内联进 HTML，可保 PDF 无外部依赖。

**沉淀来源**：2026-05-29 金总汇报一页纸图解版实战（5 项对比：2 项 Claude 手绘 SVG 图表 + 3 项 codex 生概念图）；2026-07-17 代理根因定案 + `generated_images` 兜底核查（同日验证 exec 链路端到端跑通：1024×1024 三标签中文示意图一次过 QA）。带中文标签的内容配图另见 `guizang-material-illustration` skill（其 `references/imagegen-backend.md` 与本节同源同步）。

## 迁移备注

此 skill 当前面向 Claude Code + Windows PowerShell。若要迁移到其他环境：

- 脚本语言：PowerShell 版重写成 bash/python（Codex CLI 本身跨平台）
- 触发入口：Windows 的 `/codex-review` → Linux/Mac 同名命令
- 输出目录：`tmp\codex-runs\` 改为平台合适的临时目录

## 用下面的句式开始

```text
使用 codex-cli-bridge 调一下本机 Codex CLI 做第二视角审核，输出结构化建议后由 Claude Code 整理呈现，不要替代用户的最终判断。
```

## 通道选择（2026-09-02 立规双轨 → 2026-09-09 扩为三轨）

- **长任务之外**（常规送审）：**默认本机订阅，不问**；用户显式说走 API → `-Api`，显式说走第二订阅/远端 → `-Remote`。详见「审查路径（三轨）」节。
- **长任务段内**：仍按 long-task SKILL 执行循环第 5 步——启动门必问三选（API 中转·默认推荐 / 本机订阅 / 远端订阅 `-Remote`，后者须先预检 PASS 才可选），并约定回退顺序（默认 API → 本机订阅 → 远端订阅；2026-09-09 用户拍板把 `-Remote` 纳入）；失败按类型分流（额度墙立即回退下一通道／网络超时同通道 3 次再回退，`-Remote` 的 ssh/传输失败归此类／风控类改措辞不换通道）。`-Remote` 回退前先 `-RemotePreflight`，`stage=auth` 失败=远端登录态过期，直接回退并记通道事件。
- 判定成功恒=`final.txt` 存在且非空 + `skipped-context-budget`=0；额度墙形态（raw 4 行 turn.failed + error 带恢复时刻·exit 0）见项目记忆 codex_invoke_gotchas 坑六。
