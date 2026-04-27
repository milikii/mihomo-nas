# 当前状态

## 当前主线

- 当前主实现已经切到 Go 版 `minimalist`，旧 shell / Python 主入口已从主树清理。
- 当前定位仍是 Debian NAS / IPv4 旁路由 / `iptables + TProxy`，不承诺 OpenWrt、nftables 抽象或双栈模板。
- 当前主命令名：`minimalist`
- 配置真相：`/etc/minimalist/config.yaml`
- 状态真相：`/var/lib/minimalist/state.json`
- 运行产物：`/var/lib/minimalist/mihomo/`

## 已完成能力

- 单二进制 CLI 入口：`cmd/minimalist`
- 配置与状态真相：`internal/config`、`internal/state`
- provider 导入、订阅扫描与渲染：`internal/provider`
- 默认规则仓库初始化、搜索、增删与渲染：`internal/rulesrepo`
- 运行时配置、provider、rules、systemd unit 与 sysctl 文本生成：`internal/runtime`
- 业务命令、菜单与 CLI 分发：`internal/app`、`internal/cli`
- 外部命令封装：`internal/system`

当前保留命令：

- 核心主路径：`install-self`、`setup`、`render-config`、`start`、`stop`、`restart`
- 运维查看：`status`、`show-secret`、`healthcheck`、`runtime-audit`
- 交互与资源入口：`menu`、`router-wizard`、`import-links`
- 规则与订阅：`nodes`、`subscriptions`、`rules`、`acl`、`rules-repo`

## 质量状态

- `go build` 已覆盖当前主入口。
- `GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache go test ./...` 作为当前全量回归入口。
- 当前测试已经覆盖配置、状态、provider、rules-repo、runtime 渲染、核心 app 命令、CLI 分发、错误透传、路径阻塞、菜单/helper 边界与 system runner。
- 最近一轮补强重点已经从“补单元测试红灯”转为“收口命令链路失败路径和真实 smoke 前置条件”。

## 本机真实验证结论

- 本机当前用户是 `root`。
- 使用临时路径隔离环境后，`import-links`、`nodes enable`、`render-config` 均已实际跑通，并生成了 runtime 产物。
- `setup`、`start`、`restart` 已实际触达 `systemctl`，但当前宿主机无法连接 system scope bus，不能视为 systemd 实机通过。
- `apply-rules` 已实际触达 `iptables`，但当前宿主机缺少可用的 nft/netlink 权限，返回 `Operation not permitted`，不能视为透明路由实机通过。
- `clear-rules` 命令返回成功，但由于当前宿主机同样不允许读取/操作 `iptables`，只能说明命令未崩溃，不能证明规则真实清理完成。

## 当前风险与限制

- root 权限本身不足以完成网络栈 smoke；仍需要具备 `CAP_NET_ADMIN` / 可用 `iptables` / 可用 `ip rule` 的目标主机。
- `setup` / `start` / `restart` 的完整实机验证需要 systemd 正常运行的目标主机。
- 旧版本 `settings.env` / `router.env` / `state/*.json` 不兼容，不做迁移。
- 不恢复 `alpha/stable` 核心通道切换、core 回滚、自动同步安装目录、自定义更新/重启定时器和 `external-controller-tls`。
