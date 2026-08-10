---
title: "mdoc 重构：从 Claude Code skill 到任意目录可解析的 CLI 工具库"
published: 2026-08-10
description: "把 /mdoc 个人 skill 重构为 core+CLI 分层、打包分发，再到 0.1.1 版本支持任意目录解析文档库的完整过程：架构决策、阶段迁移、验收踩坑与配置解析优先级定稿"
tags: [mdoc, 重构, CLI, 工具, Python, 开源]
category: 工具搭建
draft: false
---

作为 Claude Code 的个人技能，`/mdoc` 曾经把修复方案文档管理的规则全部写死在 SKILL.md 里，文档存放在 auto-memory 目录。用得越久问题越明显：规则散落在各处、命令直接读写文档文件、路径硬编码、也无法分发给别人使用。

这篇文章记录了我把 `/mdoc` 重构为可安装 CLI 工具库的全过程：从 core+CLI 三层分层、打包分发，到 0.1.1 版本支持任意目录解析文档库。项目已开源在 [github.com/sanya2485/mdoc](https://github.com/sanya2485/mdoc)。

## 背景与目标

原来的 `/mdoc` skill 把文档管理规则写死在 SKILL.md 里，问题集中在四个方面：

- 规则散落，维护困难
- 命令直接 Read/Write 文档文件，缺少抽象
- 路径硬编码在 skill 中，换个环境就失效
- 无法分发，只能自己用

重构目标很明确：**把确定性操作锁进代码**——分类、kebab-case 文件名、frontmatter、索引同步、搜索、校验等全部交给程序；skill 退化为 LLM 前端，只负责驱动 CLI。最终打包成可安装产物，分发给 Claude Code 用户各用各的库。

## 总体架构与决策

采用三层架构，单一事实来源在 core：

| 层 | 组件 | 职责 |
|---|------|------|
| core | `mdoc/core.py` | 纯逻辑，零依赖，可单测，唯一数据写入方 |
| CLI | `mdoc/cli.py` | core 的薄壳，argparse + `--json` 结构化输出 |
| skill | LLM 前端 | 模型驱动 mdoc 命令，不直接碰文件 |

关键决策：

- **MCP 后置**——先让 core+CLI 落定，MCP 服务作为将来对多台机器的能力出口
- 用 `doc.json` / `patch.json` 中间格式承载创建/更新
- 写操作二次确认：`--dry-run` 预览 + 用户确认保证
- 零第三方依赖，stdlib 单测 119 个

## 阶段 1-2：core + CLI

core 层实现了全部确定性逻辑：

- 分类过滤（`type: reference`，排除 user/feedback/project）
- kebab-case 文件名
- frontmatter 解析与 YAML 安全（含「冒号+空格」的字段自动加引号）
- INDEX/MEMORY 索引同步
- 全文搜索（索引 + frontmatter + 正文，相关度 + 时间排序）
- validate 校验

CLI 提供 `init/config/list/search/get/create/update/delete/slugify/validate` 命令，`--json` 模式下 stdout 只输出一条 JSON 供 skill 消费。

## 阶段 3：迁移现网 skill 命令协议

把现网 skill 的 SKILL.md 里三处直接跑 python 脚本的逻辑替换为 mdoc 命令；创建/更新/删除流程改为 `mdoc create/update/delete` + `--dry-run` 确认。个人胶水内容（auto-memory 路径、node_type 兼容、博客发布规则等）保留不动。

## 阶段 4：打包 + 通用 skill 模板 + 分发

打包分发阶段做了四件事：

- **pyproject**：SPDX license = MIT、`package-data` 收 skill_template、动态版本、入口 `mdoc = mdoc.cli:main`，新增 LICENSE
- **通用模板** `mdoc/skill_template/SKILL.md`：自包含、零机器路径（不含任何个人机器路径）、命令协议全走 mdoc CLI，斜杠调用形式为空格分隔：

```
/mdoc -f   # 按名字查文档
/mdoc -l   # 列出文档
/mdoc -c   # 创建
/mdoc -u   # 更新
/mdoc -d   # 删除
```

- `core.init_store` 幂等写入模板到 `<store>/SKILL.md`（返回 written|exists|absent）；`load_config` 增加 cwd 向上发现 `.mdoc.toml`
- 构建 wheel + sdist，在干净 venv 里跑陌生机流程（init → 建库 → 搜索 → 删除）验收通过

## 0.1.1：任意目录可解析文档库（2026-08-10）

重构完成后收到用户反馈：`pip --force-reinstall` 重装后，`mdoc list` 报「未配置文档库」，文档像"消失"了——但文件其实都在。

**根因**：文档库在 `<桌面>/mdoc` 子目录。从桌面根目录运行 `mdoc list` 时，store_dir 解析的 cwd 向上发现 `.mdoc.toml`（桌面 → 更上层）**不进入子目录**，又缺少用户级配置，于是 store_dir 为空，报「未配置」。文件从未被删除——唯一的文件删除路径是显式 `mdoc delete`，重装没有任何钩子动数据。

**修复（v0.1.1）**：`mdoc init` 新增 `_ensure_user_store_dir`，把新建库注册进用户级配置的 `store_dir` 字段：

- 用正斜杠规避 TOML 转义
- 行级编辑，保留 `index_file` / `[classification]` / `[style]` 等既有配置
- 已有有效 store_dir 时不覆盖，防止劫持已有库

之后**在任意目录**跑 mdoc 命令都能解析到库，无需先 cd 进库目录。

**重装安全**：`pip --force-reinstall` 只更新程序本体，不改文档和配置；重跑 `mdoc init <库目录>` 幂等，只补缺失文件。

**恢复方式**（如果遇到同样问题）：

```bash
# 方式一：重跑 init，幂等
mdoc init <你的库目录>

# 方式二：手动写入用户级配置
# 在 ~/.mdoc.toml 写入（注意用正斜杠）
# store_dir = "<你的库路径>"
```

**验证**：119 个单测全绿（新增 4 个：用户配置写入 / 不覆盖已有库 / 保留其他键 / 库外任意目录 list 解析到库）；干净 venv 陌生机验收完整复刻用户场景——先报「未配置」，重跑 init 后任意目录 list 成功。

## 验收踩坑（重要）

1. **Windows 编码 bug**：非 UTF-8 locale 下 `--stdin` 读中文按 GBK + surrogateescape 解码成孤立代理对，写回 UTF-8 时报 `UnicodeEncodeError: surrogates not allowed`。修复：在 `main()` 里把 stdin/stdout/stderr 全部 `reconfigure(utf-8)`。
2. **解析顺序 bug**（手工验收抓到）：在陌生库目录内跑 `mdoc config` 解析到了用户配置里的默认库，把 create/delete 打到了错误位置。根因是 store_dir 解析时用户配置排在了 cwd 发现之前，与文档化的优先级链相悖。修复：cwd 发现的库优先于用户配置，并补了回归测试。
3. **教训**：陌生机验收如果用 `MDOC_CONFIG=nonexistent` 隔离用户配置，反而会掩盖配置优先级顺序 bug——真实陌生机验收要保留用户配置在场。

## 配置解析优先级（最终定稿）

store_dir 的解析优先级最终定为：

```
--store > MDOC_DIR > 当前目录向上发现 .mdoc.toml（最多 5 层，到主目录即停）
        > 用户配置 ~/.mdoc.toml（$MDOC_CONFIG 可换）> 未配置
```

选定库后，库本地配置 `<store>/.mdoc.toml` 再覆盖 `index_file` / 排除项 / 风格等；在库目录内运行命令会自动选中该库。

## 未来：MCP 服务

重构的初衷之一是将来做成 MCP 服务，供多台机器使用。core+CLI 的分层为 MCP 预留了自然挂点：MCP tool 可以直接复用 core 函数（确定性），也可以包一层 CLI。当前决策是 MCP 后置，等 core+CLI 稳定后再评估。

## 总结

这次重构把一套散落在 skill 里的"约定"变成了可测试、可分发、可复用的工具。核心收益有三个：确定性操作全部由代码保证，skill 只做 LLM 前端；零依赖的 core 让单测（119 个）和验收可以完整覆盖；0.1.1 的任意目录解析能力让安装后的使用体验真正脱离了"必须 cd 进库目录"的限制。项目开源在 [github.com/sanya2485/mdoc](https://github.com/sanya2485/mdoc)。
