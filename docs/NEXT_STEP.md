# 下一步

## 当前阶段

- 当前主线处于阶段 5：代码结构收口。
- 阶段 5 第一轮已完成运行态/审计展示、安装与同步链路、manager sync unit 渲染链的共用逻辑收口。
- `lib/render.sh` 的 `render_config` 已完成当前块级收口，输出顺序 focused tests 已补齐。
- `mihomo` 的运行前准备与服务启停编排已完成当前最小收口。
- `mihomo` 的部署与修复编排已完成当前最小收口。
- `mihomo` 的订阅刷新编排已完成当前最小收口。
- 阶段 5 下一闭环转向 `mihomo` 主脚本中的剩余交互式长编排。

## 下一最小闭环

- 在 `mihomo` 收口 `import_links` 编排块
- 优先围绕输入采集、scan 结果分支、节点追加与 imported/skipped 统计收口职责块
- 保持现有交互提示、有效/无效节点处理和最终提示文本不变
- 优先补可通过 `stdin` 驱动的 focused tests，确保交互链路可回归
- 文档同步切到阶段 5 当前真相

## 本轮不做

- 不新增用户可感知功能
- 不调整运行态真相边界
- 不扩 `external-controller-tls` 实现
- 不继续新增 manager sync unit 单行 helper
- 不回退已完成的 `render_config` 职责块收口
- 不回退已完成的运行前准备与服务启停编排收口
- 不回退已完成的部署与修复编排收口
- 不回退已完成的订阅刷新编排收口
- 不提前切到 `router_wizard` 或 `main`
- 不做跨文件大规模拆分

## 退出条件

- `import_links` 的职责块边界更清晰，输入循环与分支复杂度下降
- `import-links` 的交互提示、导入结果与跳过路径保持不变
- 相关 smoke / service-mock 回归通过
- 文档同步更新当前阶段结论
