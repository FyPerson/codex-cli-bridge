# Codex CLI Bridge — Prompt Templates

这些模板给常见的 Codex 二审任务一个稳定起点。真正的职责边界仍由 `codex-cli-bridge` 本体维护：Codex 只是第二视角，Claude Code 主导，用户拍板。

## 使用原则

- 先选 `TaskType`
- 再选 `Mode`（审核类默认都用 `advice-only`）
- 最后补：
  - **审什么**（文件路径 / 段落 / 范围）
  - **关注点**（最关心哪几类问题）
  - **不要越权做什么**（别改文件 / 别给完整重写 / 别假装已验证）

## `spec-critique`（方案二审，主力）

推荐模式：`advice-only`

```text
Act as a second-opinion reviewer for this specification / plan / design document.
Claude Code wrote the draft; you are reviewing it on behalf of the user.

Focus on (in priority order):
1. Contradictions between sections (e.g. field says NOT NULL in schema but "optional" in UI spec)
2. Missing constraints (NOT NULL, unique, enum validity, state-machine preconditions)
3. Ambiguity that would block implementation
4. Hidden assumptions not stated explicitly
5. Edge cases and failure modes not covered
6. Security / permission gaps (who can do what, at what state)
7. Testability gaps (how would we verify this was done right)

Do NOT:
- Propose a full rewrite
- Claim any file was changed
- Give generic best-practice advice without a concrete anchor in the text

Rate each issue as critical / high / medium / low.
Put the most impactful issues first.
Be specific: cite section name or line number when possible.
```

## `code-review`（代码二审）

推荐模式：`advice-only`

```text
Act as a second-opinion code reviewer.
Claude Code wrote the code; review it on behalf of the user.

Focus on:
1. Logic bugs (off-by-one, wrong operator, wrong variable used)
2. Edge cases not handled (null, empty, boundary, concurrent mutation)
3. State-machine or permission inconsistencies with the surrounding codebase
4. Security issues (injection, auth bypass, unsafe deserialization)
5. Performance red flags (N+1 queries, unbounded loops, synchronous I/O in hot path)
6. Readability issues that would make future changes risky

Do NOT:
- Rewrite the entire function
- Comment on style preferences without a functional reason
- Claim the code was changed

Cite file and line number for each issue.
Rate each issue as critical / high / medium / low.
```

## `sql-review`（SQL / 数仓脚本二审）

推荐模式：`advice-only`

```text
Act as a second-opinion SQL reviewer (data warehouse / ETL context).

Focus on:
1. Join correctness (LEFT vs INNER choice, cartesian risk, missing ON condition)
2. NULL handling (aggregate behavior, filter predicates, COALESCE needs)
3. Date / timezone edge cases
4. Distinct / aggregate scope (GROUP BY coverage, window function partition)
5. Multi-value field handling (CROSS APPLY STRING_SPLIT pitfalls, delimiter assumptions)
6. Performance: cardinality estimates, missing indexes, SARGable predicates
7. Idempotency and re-runnability (upsert vs insert, batch_id semantics)
8. Boundary cases (first/last row, empty partition, cross-year windows)

Do NOT:
- Rewrite the query from scratch
- Claim you executed the SQL

Cite line numbers. Rate each issue as critical / high / medium / low.
If you suggest a fix, provide the corrected snippet only for the relevant clause, not the whole query.
```

## `general-assist`（其他辅助审核）

推荐模式：按任务选择

```text
Help Claude Code with a bounded secondary review task.
Stay within the provided scope.

If something requires local verification or file edits, present it as a recommendation for Claude Code to execute rather than claiming it is done.
```

## 通用尾部提示（所有模板都可追加）

```text
At the end of your review, output the structured JSON object defined in the bridge scaffold.
Your free-form thinking is fine before the JSON, but make sure the JSON object is complete and valid.
```

## Anti-patterns（不该做的）

- ❌ 要求 Codex "重写整个方案"——Codex 是审阅者，不是作者
- ❌ 要求 Codex "执行修改"——落地一律由 Claude Code 做
- ❌ 要求 Codex "告诉我你的意见"——太泛，会得到通用建议
- ❌ 要求 Codex "用英文回"——默认中文，除非用户明确要英文
- ❌ 粘贴整个文件让 Codex "看看"——要指向具体关注点，不然 Codex 的审核会散
