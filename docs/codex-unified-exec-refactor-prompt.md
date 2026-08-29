# Codex Unified Exec 重构任务

请在 `/home/ts_user/rust_pro/fx` 中完成一次执行工具重构。

Codex 参考源码位于：

```text
/home/ts_user/rust_pro/codex
```

Codex 仓库只读，不要修改。开始前阅读两个仓库的 `AGENTS.md`、当前代码和测试，自行追踪相关调用链并设计最合适的实现方案。

## 目标

彻底移除 fx 当前面向模型的 `terminal` 工具，以 Codex 当前 Unified Exec 实现为行为基准，改为两个独立工具：

- `exec_command`
- `write_stdin`

不要保留旧 `terminal` action、参数、别名或兼容适配层。旧调用不需要继续工作。

## 必须实现的行为

- `exec_command` 启动命令后先等待一段时间。
- 命令在等待期间结束时，直接返回输出和退出状态。
- 命令仍在运行时，返回数字 session ID，并让同一个进程继续在后台运行。
- 等待时间只是 yield 窗口，不是进程运行超时，不能因为到达等待期限而杀掉进程。
- `write_stdin` 可以通过 session ID 轮询新增输出，也可以向支持交互的进程写入输入。
- Agent turn 结束或被 interrupt 时，已经启动的后台进程仍然存活。
- Session 关闭、显式停止或进程管理器销毁时，正确终止并清理后台进程及其子进程。
- stdout 和 stderr 必须持续排空并有界缓存，避免阻塞、无限内存增长和 UTF-8 截断问题。
- 并发轮询、进程退出和清理不能造成重复完成、僵尸进程、竞态或 use-after-free。

`exec_command` 和 `write_stdin` 的字段、默认值、范围、返回文本、错误语义、输出截断、进程上限和生命周期细节，以本地 Codex 当前源码为准，不要根据旧 fx 行为自行推断。

## fx 集成要求

- 新执行能力必须接入 fx 现有 permission-first 权限系统。
- 进程管理器属于 Core 或 Session runtime，不属于 UI。
- 后台线程和工具回调只能通过安全事件队列更新 TUI，不能直接修改 transcript。
- 删除只服务旧模型 `terminal` 工具的实现、协议、host、fixture、测试和文档。
- 不要误删仍有独立真实调用者的通用终端引擎、replay 或 hosted child-terminal 能力。
- Native Linux 和 macOS 是主要目标。无法完整支持 Unified Exec 的 host 不应广告这两个工具，也不能继续回退到旧 `terminal`。

## 测试与文档

自行定位并更新所有相关单元测试、E2E、fixture、权限测试、ACP/subagent 接入、工具描述、README、CHANGELOG 和 PGSO corpus。

测试至少应证明：

- 短命令同步完成。
- 长命令自动 yield，并保持原进程运行。
- `write_stdin` 能轮询、交互和取得最终退出状态。
- interrupt 不会杀掉后台进程。
- 显式清理会终止进程树。
- 输出有界且不会阻塞。
- 权限行为没有被绕过。
- 旧 `terminal` 工具和兼容入口已彻底消失。

完成后运行格式化、构建、相关测试和 E2E，并使用当前仓库刚构建的 `./zig-out/bin/fx` 真实执行长任务、轮询、interrupt 和 cleanup 路径。不要使用 PATH 中安装的 `fx`。

不要创建 commit、push、tag 或 PR，除非用户另行明确要求。不要覆盖工作区中已有的用户修改。

最终报告实现概述、删除和新增的主要内容、所有验证命令及结果、手动运行结果、未验证项，以及全仓旧 API 搜索结果。只有本地验证和 exact commit 的 Full CI 都满足仓库要求时，才能声称工作 ready。
