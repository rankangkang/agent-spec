---
name: git-worktree-workflow
description: This skill should be used when starting or cleaning up isolated feature work using git worktree, with smart directory selection, safety checks, and teardown after merge.
---

## 目的

将“需要与当前工作空间隔离的功能开发/实施”固化为可重复执行的 `git worktree` 工作流：
- 创建隔离工作树（新分支或已有分支）
- 自动选择安全的 worktree 目录
- 在关键删除操作前做强校验
- 在“开发完成（合并/显性完成特征）”后清理 worktree

## 适用场景（触发时机）

- 在开始一个需要与当前工作空间隔离的功能开发时。
- 在进入实施阶段之前，需要先创建独立目录承载变更时。
- 在需要并行维护多个分支（例如 hotfix 与 feature 并行）且不希望频繁切换分支时。

## 输入收集（最少信息）

在执行任何命令前，先收集并确认：
- **branch**：目标分支名（建议 `kebab-case`，例如 `feature/user-auth` 或 `user-auth`）。
- **base_ref**：新建分支的基线（默认 `origin/main`；也可为 `origin/master`、tag、commit）。
- **dir_mode**：目录策略（`inside`/`auto`/`sibling`，默认 `inside`；若用户明确希望“仓库同级隔离目录”，再选择 `sibling` 或 `auto`）。
- **completion_signal**：完成信号（默认用“已合并到主分支”判断；也支持用户显式确认“已完成，接下来请清理”）。

## 工作流（推荐顺序）

### 1) 预检查（Safety preflight）

- 确认当前目录在 Git 仓库内：`git rev-parse --show-toplevel`。
- 识别默认主分支：优先 `main`，否则 `master`。
- 刷新远端信息：`git fetch --prune`（避免用过期的 `origin/main`）。

> 允许当前工作区存在未提交改动；但要明确：这些改动不会自动带到新 worktree。

### 2) 选择 worktree 目录（Smart path selection）

目录策略定义：
- **auto（默认）**：优先在仓库同级创建 `.worktrees/<repo_name>/<branch>`（隔离性最好）；若无法创建则退化到仓库内 `.worktrees/<branch>`。
- **sibling**：强制使用仓库同级 `.worktrees/<repo_name>/<branch>`。
- **inside**：强制使用仓库内 `.worktrees/<branch>`（不跨出当前 workspace，通常不需要额外授权）。

安全约束：
- 目标目录必须是**空目录**或**不存在**。
- 目标目录不得是 Git 仓库根目录或其现有 worktree 路径。

### 3) 创建 worktree

优先使用本技能内置脚本 `scripts/wt.sh`（包含目录选择与强校验）：
- 创建（新分支）：
  - `bash skills/git-worktree-workflow/scripts/wt.sh create --branch <branch> --base <base_ref> --dir-mode inside`
- 创建（已有分支）：
  - `bash skills/git-worktree-workflow/scripts/wt.sh create --branch <branch> --dir-mode inside`

> 说明：`inside` 不会跨出当前仓库目录；若用户明确要求“仓库同级隔离目录”，再改用 `--dir-mode sibling`（或 `auto`）。

创建完成后：
- 输出 worktree 绝对路径，提示用户在 IDE 中打开该目录进行开发。
- 可选：在新 worktree 内执行一次 `git status`，确认当前分支与 HEAD 正确。

### 4) 开发期间的建议操作

- 用 `git worktree list --porcelain` 查看所有 worktree 及其分支归属。
- 保持分支可追溯：定期 push（尤其在准备清理前）。

### 5) 清理 worktree（仅在用户明确要求时执行）

#### 完成判定（Completion detection）

允许进行“检查与建议”，但**不得因为自动判定为已合并就直接执行清理**。

优先级从高到低：
1. **显式完成信号**：用户明确说“已合并/已完成/请清理/请删除 worktree”。
2. **自动判定已合并（只用于提示）**：
   - `git fetch --prune`
   - 判断分支是否已合并到主分支：`git branch --merged origin/<main_branch> | grep -F " <branch>"`

> 若无法确认是否合并（例如无远端、分支未 push、主分支名不确定），停止任何清理动作，并改为请求用户给出明确指令。

#### 清理动作（Teardown，二段式）

除非用户明确要求，否则 **Agent 只输出建议命令，不实际执行删除**。

- 第一步（dry run，仅展示将要删除的路径）：
  - `bash skills/git-worktree-workflow/scripts/wt.sh destroy --branch <branch> --dry-run`
- 第二步（用户明确确认“请清理/请删除”后才执行）：
  - `bash skills/git-worktree-workflow/scripts/wt.sh destroy --branch <branch>`

可选（更激进，需用户显式确认且通常仅在已合并时）：
- 删除本地分支：`git branch -d <branch>`
- 强制删除 worktree（会丢弃 worktree 内未提交改动）：
  - `bash skills/git-worktree-workflow/scripts/wt.sh destroy --branch <branch> --force`

## 安全规则（必须遵守）

- **默认不执行删除**：除非用户明确要求，否则不可执行任何删除动作，包括但不限于：
  - `git worktree remove ...` / `wt.sh destroy ...`
  - `git branch -d/-D ...`
  - 直接删除目录（`rm -rf` 等）
- 任何删除操作前，必须：
  - 通过 `git worktree list --porcelain` 证明目标路径确属当前仓库。
  - 明确展示将要移除的绝对路径与分支名，并优先先跑一次 `--dry-run`。
- 避免对不在当前 workspace 内的路径做文件操作；若必须创建到仓库同级目录，命令执行需要按平台要求走授权流程。
- 默认不删除分支；分支删除属于不可逆操作，只有在“已合并且用户明确同意”时才执行。

## 资源

- `scripts/wt.sh`：提供 `create`/`destroy` 两个子命令，封装目录选择、ref 校验、worktree 归属校验与 prune。
