# Long-Term Stability Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把当前 Go 版 `minimalist` 从“本机已成功切换并可用”推进到“更接近长期稳定值守”的下一阶段，优先补齐 runtime asset 自检、重启/重启后 smoke 闭环、以及 `core-upgrade-alpha` 的可执行恢复路径。

**Architecture:** 保持现有边界，不扩产品能力、不恢复 stable 通道、不引入自动 cutover。实现上只沿着现有 `internal/runtime`、`internal/app`、`internal/cli` 与运维文档收口：先提供 runtime asset 缺口判定原语，再让 `setup/start/restart/healthcheck/runtime-audit` 使用同一套 fail-fast 语义，随后把 `core-upgrade-alpha` 的恢复信息和 reboot/restart runbook 文档化。

**Tech Stack:** Go 标准库 `os`、`path/filepath`、`strings`，现有 `internal/runtime`、`internal/app`、`internal/cli`、`internal/system`，以及 `README.md` / `docs/CUTOVER.md` / `docs/STATUS.md` / `docs/NEXT_STEP.md`。

---

## File Map

- Modify: `internal/runtime/runtime.go`
  - 增加 runtime asset 路径与缺口判定 helper
- Modify: `internal/runtime/runtime_test.go`
  - 覆盖 asset 缺失 / 完整两条基础语义
- Modify: `internal/app/app.go`
  - 为 `setup` / `start` / `restart` / `healthcheck` / `runtime-audit` 接入统一 asset 自检
- Modify: `internal/app/app_test.go`
  - 补 asset 缺失 fail-fast、`runtime-audit` fatal-gap、无 systemctl 副作用等 focused tests
- Modify: `internal/app/core_upgrade.go`
  - 升级失败时明确输出 backup 路径与恢复建议
- Modify: `internal/app/core_upgrade_test.go`
  - 覆盖恢复提示与 backup 保留语义
- Modify: `internal/cli/cli_test.go`
  - 如输出契约变化，更新 CLI 透传断言
- Modify: `README.md`
  - 更新 asset 自检与恢复路径说明
- Modify: `docs/README_FLOWS.md`
  - 更新当前运行态与 fail-fast 真相
- Modify: `docs/CUTOVER.md`
  - 追加 restart/reboot smoke runbook 与升级失败恢复步骤
- Modify: `docs/STATUS.md`
  - 记录稳定性闭环推进结果
- Modify: `docs/NEXT_STEP.md`
  - 主线从 asset 自检推进到 reboot/restart smoke

---

### Task 1: Runtime Asset 缺口判定原语

**Files:**
- Modify: `internal/runtime/runtime.go`
- Test: `internal/runtime/runtime_test.go`

- [ ] **Step 1: 先写 failing tests，固定 asset 缺口语义**

```go
func TestMissingRuntimeAssetsReportsAbsentFilesAndDirectories(t *testing.T) {
	paths := Paths{RuntimeDir: t.TempDir()}
	if err := EnsureLayout(paths); err != nil {
		t.Fatalf("ensure layout: %v", err)
	}
	if err := os.RemoveAll(paths.UIPath()); err != nil {
		t.Fatalf("remove ui dir: %v", err)
	}

	missing := MissingRuntimeAssets(paths)
	want := []string{"Country.mmdb", "GeoSite.dat", "ui/"}
	if !reflect.DeepEqual(missing, want) {
		t.Fatalf("missing assets = %#v, want %#v", missing, want)
	}
}

func TestMissingRuntimeAssetsReturnsNilWhenAssetsPresent(t *testing.T) {
	paths := Paths{RuntimeDir: t.TempDir()}
	if err := EnsureLayout(paths); err != nil {
		t.Fatalf("ensure layout: %v", err)
	}
	if err := os.WriteFile(paths.CountryMMDBPath(), []byte("mmdb"), 0o640); err != nil {
		t.Fatalf("write mmdb: %v", err)
	}
	if err := os.WriteFile(paths.GeoSitePath(), []byte("geosite"), 0o640); err != nil {
		t.Fatalf("write geosite: %v", err)
	}

	missing := MissingRuntimeAssets(paths)
	if len(missing) != 0 {
		t.Fatalf("expected no missing assets, got %#v", missing)
	}
}
```

- [ ] **Step 2: 跑 focused tests，确认当前缺少实现**

Run:

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./internal/runtime -run TestMissingRuntimeAssets -count=1
```

Expected:

```text
FAIL	minimalist/internal/runtime [build failed]
```

并且报错包含 `undefined: MissingRuntimeAssets` / `undefined: CountryMMDBPath`。

- [ ] **Step 3: 写最小实现，只提供路径和缺口列表，不做自动修复**

```go
func (p Paths) CountryMMDBPath() string { return filepath.Join(p.RuntimeDir, "Country.mmdb") }
func (p Paths) GeoSitePath() string     { return filepath.Join(p.RuntimeDir, "GeoSite.dat") }

func MissingRuntimeAssets(paths Paths) []string {
	missing := make([]string, 0, 3)
	for _, item := range []struct {
		label string
		path  string
		dir   bool
	}{
		{label: "Country.mmdb", path: paths.CountryMMDBPath()},
		{label: "GeoSite.dat", path: paths.GeoSitePath()},
		{label: "ui/", path: paths.UIPath(), dir: true},
	} {
		info, err := os.Stat(item.path)
		if err != nil {
			missing = append(missing, item.label)
			continue
		}
		if item.dir {
			if !info.IsDir() {
				missing = append(missing, item.label)
			}
			continue
		}
		if info.IsDir() || info.Size() == 0 {
			missing = append(missing, item.label)
		}
	}
	return missing
}
```

- [ ] **Step 4: 复跑 focused tests，确认 helper 语义通过**

Run:

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./internal/runtime -run TestMissingRuntimeAssets -count=1
```

Expected:

```text
ok  	minimalist/internal/runtime	0.xxxs
```

- [ ] **Step 5: 提交这一闭环**

```bash
git add internal/runtime/runtime.go internal/runtime/runtime_test.go
git commit -m "fix: detect missing runtime assets"
```

---

### Task 2: `setup/start/restart/healthcheck/runtime-audit` 统一 fail-fast

**Files:**
- Modify: `internal/app/app.go`
- Test: `internal/app/app_test.go`

- [ ] **Step 1: 先写 failing tests，固定高风险链路的 fail-fast 行为**

```go
func TestHealthcheckReportsMissingRuntimeAssets(t *testing.T) {
	app, _ := newTestApp(t)

	err := app.Healthcheck()
	if err == nil || !strings.Contains(err.Error(), "missing runtime assets") {
		t.Fatalf("expected missing runtime assets error, got %v", err)
	}
}

func TestStartFailsWhenRuntimeAssetsMissingWithoutSystemctlCall(t *testing.T) {
	app := newTestAppWithEnabledManualNode(t)
	var calls []commandCall
	app.Runner = fakeRunner{
		runFn: func(name string, args ...string) error {
			calls = append(calls, commandCall{name: name, args: append([]string{}, args...)})
			return nil
		},
	}

	err := app.Start()
	if err == nil || !strings.Contains(err.Error(), "missing runtime assets") {
		t.Fatalf("expected missing runtime assets error, got %v", err)
	}
	if hasRecordedCall(calls, "systemctl", "enable", "--now", "minimalist.service") {
		t.Fatalf("did not expect systemctl call when assets are missing")
	}
}

func TestRuntimeAuditReportsMissingRuntimeAssetsAsFatalGap(t *testing.T) {
	app, _ := newTestApp(t)
	app.Runner = fakeRunner{
		runFn: func(name string, args ...string) error {
			if name == "systemctl" && len(args) >= 2 {
				return nil
			}
			return nil
		},
		outputFn: func(name string, args ...string) (string, string, error) {
			if name == "journalctl" {
				return "", "", nil
			}
			return "", "", errors.New("unavailable")
		},
	}

	if err := app.RuntimeAudit(); err != nil {
		t.Fatalf("runtime audit: %v", err)
	}
	output := app.Stdout.(*bytes.Buffer).String()
	if !strings.Contains(output, "fatal-gap: runtime-assets-missing") {
		t.Fatalf("expected runtime asset fatal gap, output=\n%s", output)
	}
}
```

- [ ] **Step 2: 跑 focused tests，确认当前行为不满足要求**

Run:

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./internal/app -run 'TestHealthcheckReportsMissingRuntimeAssets|TestStartFailsWhenRuntimeAssetsMissingWithoutSystemctlCall|TestRuntimeAuditReportsMissingRuntimeAssetsAsFatalGap' -count=1
```

Expected:

```text
--- FAIL: TestHealthcheckReportsMissingRuntimeAssets
--- FAIL: TestStartFailsWhenRuntimeAssetsMissingWithoutSystemctlCall
--- FAIL: TestRuntimeAuditReportsMissingRuntimeAssetsAsFatalGap
```

- [ ] **Step 3: 写最小实现，复用同一个 asset readiness helper**

```go
func (a *App) ensureRuntimeAssetsReady() error {
	missing := runtime.MissingRuntimeAssets(a.Paths)
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf(
		"missing runtime assets: %s; preseed them under %s",
		strings.Join(missing, ", "),
		a.Paths.RuntimeDir,
	)
}
```

在以下链路里接入：

```go
func (a *App) Setup() error {
	// render files ...
	if err := a.ensureRuntimeAssetsReady(); err != nil {
		return err
	}
	// systemctl enable --now ...
}

func (a *App) Start() error {
	if err := a.RenderConfig(); err != nil {
		return err
	}
	if err := a.ensureRuntimeAssetsReady(); err != nil {
		return err
	}
	return a.Runner.Run("systemctl", "enable", "--now", "minimalist.service")
}

func (a *App) Restart() error {
	if err := a.RenderConfig(); err != nil {
		return err
	}
	if err := a.ensureRuntimeAssetsReady(); err != nil {
		return err
	}
	return a.Runner.Run("systemctl", "restart", "minimalist.service")
}

func (a *App) Healthcheck() error {
	if err := a.ensureRuntimeAssetsReady(); err != nil {
		return err
	}
	// existing controller checks ...
}
```

并把 `runtime-audit` 的 fatal gap 扩成：

```go
if err := a.ensureRuntimeAssetsReady(); err != nil {
	fatalGaps = append(fatalGaps, "runtime-assets-missing")
	fmt.Fprintf(a.Stdout, "runtime-assets: %v\n", err)
}
```

- [ ] **Step 4: 跑 focused tests 与相关回归**

Run:

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./internal/app -run 'TestHealthcheckReportsMissingRuntimeAssets|TestStartFailsWhenRuntimeAssetsMissingWithoutSystemctlCall|TestRuntimeAuditReportsMissingRuntimeAssetsAsFatalGap|TestSetupWithProvidersEnablesService|TestRestartRendersConfigAndRestartsService' -count=1
```

Expected:

```text
ok  	minimalist/internal/app	0.xxxs
```

- [ ] **Step 5: 提交这一闭环**

```bash
git add internal/app/app.go internal/app/app_test.go
git commit -m "fix: fail fast when runtime assets are missing"
```

---

### Task 3: `core-upgrade-alpha` 恢复路径可执行化

**Files:**
- Modify: `internal/app/core_upgrade.go`
- Test: `internal/app/core_upgrade_test.go`
- Modify: `README.md`
- Modify: `docs/CUTOVER.md`

- [ ] **Step 1: 先写 failing test，要求升级失败时明确告知 backup 与恢复方式**

```go
func TestCoreUpgradeAlphaRestartFailureMentionsBackupPathAndRestoreCommand(t *testing.T) {
	app, root := newTestApp(t)
	coreBin := filepath.Join(root, "bin", "mihomo-core")
	// prepare config, old core, release API, download payload...

	err := app.CoreUpgradeAlpha()
	if err == nil {
		t.Fatalf("expected restart failure")
	}
	if !strings.Contains(err.Error(), coreBin+".bak") {
		t.Fatalf("expected backup path in error, got %v", err)
	}
	if !strings.Contains(err.Error(), "mv "+coreBin+".bak "+coreBin) {
		t.Fatalf("expected restore command in error, got %v", err)
	}
}
```

- [ ] **Step 2: 跑 focused test，确认当前错误信息不够可执行**

Run:

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./internal/app -run TestCoreUpgradeAlphaRestartFailureMentionsBackupPathAndRestoreCommand -count=1
```

Expected:

```text
--- FAIL: TestCoreUpgradeAlphaRestartFailureMentionsBackupPathAndRestoreCommand
```

- [ ] **Step 3: 最小实现，只增强错误上下文，不新增 rollback 子命令**

```go
backupPath, err := replaceCoreBinaryAtomically(cfg.Install.CoreBin, candidate)
if err != nil {
	return err
}
if err := a.restartMinimalistServiceAfterCoreUpgrade(); err != nil {
	return fmt.Errorf(
		"%w; backup preserved at %s; restore with: mv %s %s && systemctl restart minimalist.service",
		err,
		backupPath,
		backupPath,
		cfg.Install.CoreBin,
	)
}
```

- [ ] **Step 4: 更新 runbook 与 README**

在 `README.md` 增加一句：

```markdown
- `core-upgrade-alpha` 若替换成功但服务重启失败，会保留 `<core_bin>.bak` 并输出恢复命令
```

在 `docs/CUTOVER.md` 增加恢复段：

```bash
sudo mv /usr/local/bin/mihomo-core.bak /usr/local/bin/mihomo-core
sudo systemctl restart minimalist.service
sudo /usr/local/bin/minimalist healthcheck
```

- [ ] **Step 5: 跑 focused tests**

Run:

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./internal/app -run 'TestCoreUpgradeAlphaRestartFailureMentionsBackupPathAndRestoreCommand|TestCoreUpgradeAlphaSurfacesRestartFailureWithLogs' -count=1
```

Expected:

```text
ok  	minimalist/internal/app	0.xxxs
```

- [ ] **Step 6: 提交这一闭环**

```bash
git add internal/app/core_upgrade.go internal/app/core_upgrade_test.go README.md docs/CUTOVER.md
git commit -m "fix: document recoverable core upgrade failures"
```

---

### Task 4: Restart / Reboot Smoke Runbook 与主线同步

**Files:**
- Modify: `docs/CUTOVER.md`
- Modify: `docs/README_FLOWS.md`
- Modify: `docs/STATUS.md`
- Modify: `docs/NEXT_STEP.md`

- [ ] **Step 1: 写出 restart / reboot smoke runbook**

在 `docs/CUTOVER.md` 增加一节：

```markdown
## Post-cutover restart / reboot smoke

### service restart smoke

```bash
sudo systemctl restart minimalist.service
systemctl is-active minimalist.service
systemctl is-enabled minimalist.service
/usr/local/bin/minimalist healthcheck
/usr/local/bin/minimalist runtime-audit
ip rule show
ip route show table 233
iptables -t mangle -S | grep MIHOMO_PRE
iptables -t nat -S | grep MIHOMO_DNS
```

### host reboot smoke

```bash
sudo reboot
# reconnect after boot
systemctl is-active minimalist.service
systemctl is-enabled minimalist.service
/usr/local/bin/minimalist healthcheck
/usr/local/bin/minimalist runtime-audit
ip rule show
ip route show table 233
```
```

- [ ] **Step 2: 同步主线文档**

更新：

- `docs/README_FLOWS.md`：说明 restart/reboot smoke 是当前长期稳定主线的一部分
- `docs/STATUS.md`：记录 runbook 已落地，但 reboot smoke 是否真实执行要与结果分开写
- `docs/NEXT_STEP.md`：把“下一闭环”更新成“执行并验证 restart/reboot smoke”

- [ ] **Step 3: review 文档 diff**

Run:

```bash
git diff -- docs/CUTOVER.md docs/README_FLOWS.md docs/STATUS.md docs/NEXT_STEP.md
```

Expected:

```text
只包含 restart/reboot smoke runbook 与主线状态同步，没有无关历史回抄
```

- [ ] **Step 4: 提交这一闭环**

```bash
git add docs/CUTOVER.md docs/README_FLOWS.md docs/STATUS.md docs/NEXT_STEP.md
git commit -m "docs: add restart and reboot smoke runbook"
```

---

### Task 5: 最终回归与收尾

**Files:**
- Verify only: `internal/runtime/runtime.go`, `internal/runtime/runtime_test.go`, `internal/app/app.go`, `internal/app/app_test.go`, `internal/app/core_upgrade.go`, `internal/app/core_upgrade_test.go`, `internal/cli/cli_test.go`, `README.md`, `docs/CUTOVER.md`, `docs/README_FLOWS.md`, `docs/STATUS.md`, `docs/NEXT_STEP.md`

- [ ] **Step 1: 跑全量回归**

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./...
```

Expected:

```text
ok  	minimalist/internal/app
ok  	minimalist/internal/runtime
```

并且没有失败包。

- [ ] **Step 2: 跑 build**

```bash
GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go build -o /tmp/minimalist-build-check ./cmd/minimalist
```

Expected:

```text
exit 0
```

- [ ] **Step 3: 如本机环境允许，执行最小实机 smoke**

```bash
/usr/local/bin/minimalist healthcheck
/usr/local/bin/minimalist runtime-audit
systemctl is-active minimalist.service
systemctl is-enabled minimalist.service
ip rule show
ip route show table 233
```

Expected:

```text
healthcheck 成功
runtime-audit 输出 alerts-24h / alerts-recent / fatal-gaps
minimalist.service active
table 233 与 fwmark 规则存在
```

- [ ] **Step 4: 提交最终文档同步**

```bash
git add README.md docs/CUTOVER.md docs/README_FLOWS.md docs/STATUS.md docs/NEXT_STEP.md
git commit -m "docs: sync long-term stability hardening status"
```
