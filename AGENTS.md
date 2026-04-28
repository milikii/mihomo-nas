# AGENTS.md

本文件只定义当前仓库**长期有效**的执行规则。
阶段性目标、优先级和当前主线一律写在 `docs/NEXT_STEP.md`，不要写死在这里。

---

## 1. 权威顺序

执行任何任务前，按以下顺序判断真相：

1. `AGENTS.md`
2. `docs/STATUS.md`
3. `docs/NEXT_STEP.md`
4. `docs/DECISIONS.md`
5. `docs/ARCHITECTURE.md`
6. 代码与测试真相

若代码真相与文档冲突，先判断是否属于文档滞后；确认后优先修正文档。

---

## 2. 仓库目标

本项目是运行在 **Debian NAS 宿主机** 上的 Go 版旁路由管理器，当前边界由 `docs/DECISIONS.md` 定义。

默认目标不是“多做功能”，而是：

- 保持默认分支可构建、可测试
- 保持 live host 变更可验证、可回滚、可追踪
- 让文档持续反映当前真相

---

## 3. 默认执行方式

- 默认按 `docs/NEXT_STEP.md` 当前主线连续推进
- 每轮只做一个最小闭环：实施 -> 验证 -> 必要文档同步 -> review diff -> commit
- 不做无关重构，不顺手扩功能，不把阶段性目标写进 `AGENTS.md`
- 若一轮结束后还有更保守、更小、可验证的下一步，继续推进

---

## 4. 稳定性优先级

当任务涉及以下链路时，**实机稳定性优先于继续追 coverage**：

- `setup`
- `start` / `stop` / `restart`
- `apply-rules` / `clear-rules`
- `healthcheck`
- `runtime-audit`
- `cutover-preflight` / `cutover-plan`
- `core-upgrade-alpha`
- `/var/lib/minimalist/mihomo/` 下的 runtime assets

对这类任务：

- 先考虑 live host 风险，再考虑代码整洁度
- 先做真实 smoke / systemd / controller / route 验证，再补 focused tests
- 不允许“先改了再上机看看”

---

## 5. 验证要求

- 能跑相关测试就先跑相关测试
- 影响范围较大时，运行全量回归入口：`GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./...`
- 涉及 service / routing / controller / runtime asset / upgrade 的改动，若本机环境可用，必须优先做真实验证
- 若当前环境无法完成某项验证，必须明确说明缺口、影响和下一步
- 没有最新验证证据，不宣称“已完成”或“已稳定”

---

## 6. 边界变更规则

以下变化默认不应直接落地，必须先明确影响，并同步 `docs/DECISIONS.md`：

- 产品边界变化
- 部署拓扑变化
- 协议或真相边界变化
- 升级策略变化
- 回滚策略变化
- 旧状态迁移兼容策略变化
- Debian NAS / IPv4 / `iptables + TProxy` 之外的能力扩展

若用户没有明确要求，不主动扩大这些边界。

---

## 7. 文档同步规则

发生以下变化时，同步更新对应文档：

- 当前状态变化 -> `docs/STATUS.md`
- 当前主线/退出条件变化 -> `docs/NEXT_STEP.md`
- 稳定决策变化 -> `docs/DECISIONS.md`
- 结构与数据流变化 -> `docs/ARCHITECTURE.md`

要求：

- `STATUS` 写当前真相，不写流水账
- `NEXT_STEP` 写当前主线，不写长期宪法
- `AGENTS.md` 只保留长期稳定规则

---

## 8. Git 纪律

- 每个闭环尽量独立 commit
- 未验证通过的改动，不伪装成完成态
- push 前确认本地状态、分支状态和目标远端清晰
- 不回滚用户未明确要求回滚的现有改动

---

## 9. 会话落盘

最近 3 轮会话摘要写入仓库根目录 `codex.md`：

- 默认加入 `.gitignore`
- 不提交 git
- 只作为会话交接，不替代正式项目文档

格式保持：

```markdown
## Round N

### 🎯 任务

### 🙋 用户

### 🤖 Codex

### 🔜 下一步
```
