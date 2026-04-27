# 下一步

## 当前阶段

- Go 版 `minimalist` 主实现已经落地，默认分支保持可构建、可测试。
- 单元与 focused 测试已经覆盖核心配置、状态、provider、rules-repo、runtime 渲染、app 命令编排、CLI 分发与多组失败路径。
- 本机已完成临时环境 smoke：`import-links`、`nodes enable`、`render-config` 通过。
- 本机仍不能完成完整实机 smoke：`systemctl` 无法连接 system scope bus，`iptables` / `ip rule` 缺少可用 netlink/nft 权限。

## 下一最小闭环

- 在具备 systemd 与 `CAP_NET_ADMIN` 的目标主机上执行真实 smoke：
  - `import-links`
  - `nodes enable`
  - `render-config`
  - `setup`
  - `start`
  - `restart`
  - `apply-rules`
  - 验证 `iptables` / `ip rule` 实际变化
  - `clear-rules`
  - 验证规则清理完成
- 若继续留在当前宿主机，只做文档、单元测试、focused tests 和不依赖 systemd/netlink 的命令验证。
- 保持 README / flows / STATUS 只描述 `minimalist` 当前真相，不回退旧 `mihomo` 叙述。

## 本轮不做

- 不恢复旧 `mihomo` 命令入口。
- 不做旧状态迁移兼容。
- 不引入 alpha/stable 切换、自同步、回滚 core 等旧运维能力。
- 不扩 `external-controller-tls`。

## 退出条件

- README 与权威文档只描述 Go 版 `minimalist` 当前真相。
- `go test ./...` 覆盖核心命令与系统编排关键路径。
- 在符合条件的目标主机上完成 `setup` / `start` / `restart` / `apply-rules` / `clear-rules` 真实 smoke。
