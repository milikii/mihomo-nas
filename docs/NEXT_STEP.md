# 下一步

## 当前阶段

- 当前主线处于阶段 5：代码结构收口。
- 阶段 5 第一轮已完成运行态/审计展示、安装与同步链路、manager sync unit 渲染链的共用逻辑收口。
- `lib/render.sh` 的 `render_config` 已完成当前块级收口，输出顺序 focused tests 已补齐。
- 阶段 5 下一闭环转向 `mihomo` 主脚本中的运行前准备与服务启停编排。

## 下一最小闭环

- 在 `mihomo` 收口运行前准备与服务启停编排块
- 优先围绕 `prepare_runtime_assets`、`start_service_command`、`restart_service_command`、`enable_and_start_service_command` 收口重复前置逻辑
- 保持现有启动/重启/启用输出文本、准备步骤与失败路径不变
- 补 focused tests 或复用 `service_mock`，确保服务侧链路不回归
- 文档同步切到阶段 5 当前真相

## 本轮不做

- 不新增用户可感知功能
- 不调整运行态真相边界
- 不扩 `external-controller-tls` 实现
- 不继续新增 manager sync unit 单行 helper
- 不回退已完成的 `render_config` 职责块收口
- 不做跨文件大规模拆分

## 退出条件

- 运行前准备与服务启停的职责块边界更清晰，重复前置逻辑下降
- `start` / `restart` / `enable --now` 的行为、输出与退化路径保持不变
- 相关 smoke / service-mock 回归通过
- 文档同步更新当前阶段结论
