# 仓库、分支与 GitHub 同步指南

**状态：2026-09-10 起有效，这是本仓库 git 情况的权威说明。**
`repo_sync_and_backup_20260821.md` 记录的 git bundle 备份方案已退役，那份文档
保留作历史查阅。

---

## 1. 一句话现状

Pathfinder 上 `/projects/hpcl-cli185/proj-shared/zw5/E3SM` 这份 checkout 是主
工作副本，它的全部提交现在推送到**私有**仓库
`zzw0034/E3SM-pathfinder`（remote 名 `mygh`）。`origin` 仍指向 ORNL 的 fork，
只读，用来取上游更新。

## 2. 三个仓库、两个 remote

| 仓库 | remote 名 | 权限 | 作用 |
| --- | --- | --- | --- |
| `E3SM-Project/E3SM` | 无 | 公开只读 | 真正的上游。Pathfinder 机器修复在其 `fmyuan/ornl-pathfinder-machine-settings` 分支上。我们没有 remote 指向它，需要时用一次性 `git fetch <URL> <branch>` |
| `ORNL-Ecosystem-Projects/E3SM` | `origin` | **读通、写被拒** | 2026-05-18 clone 的来源。2026-08-21 用 `push --dry-run` 验证过没有写权限 |
| `zzw0034/E3SM-pathfinder` | `mygh` | 私有，可读写 | **我们的权威备份与发布点**，2026-09-10 建立 |

**为什么是新建私有仓库而不是 fork。** fork 一个公开仓库只能得到公开仓库，而
`docs/` 里写了集群路径、Slurm 账号 `hpcl-cli185`、分区拓扑和作业号。新建空仓库
再整段推送，代价也不大：打包后的历史只有 364 MiB，`.git` 那 4.6 GB 几乎全是
53 个子模块的内部目录，不参与推送。

**子模块不用单独推。** 53 个子模块全部停在记录的 SHA，没有本地改动。超级工程
里存的是指针，克隆方用 `--recursive` 从各自的原仓库取。

## 3. 历史谱系

```text
c181c41b1a  上游 E3SM-Project/E3SM 的 master 尖端（2026-03-19），共同基点
   │
   ├─ +5 个 cherry-pick   fmyuan 的 Pathfinder 机器设置提交
   ├─ +38 个自己的提交
   │
2d7b31f799  尖端（2026-09-10）
```

本地这份是 2026-05-18 按 Nick 邮件的 recipe 建的：clone ORNL fork，再用
`git fetch <URL> <branch>` 从**上游**临时取来 5 个 fmyuan 的 commit 做
cherry-pick。这种临时 fetch 只写 `FETCH_HEAD`、不建 remote-tracking ref，所以
`git branch -r --contains <sha>` 查不到它们，看着像本地独有，其实不是。

**我们的 `master` 和 `origin/master` 是兄弟不是父子。** 两者共同祖先是
`c181c41b1a`，从那以后 ORNL 走了 1131 个提交，我们走了 43 个，互不包含。
`ahead 43, behind 1131` 描述的是分叉，不是"落后了要追"。为什么不合并
`origin/master`，见 `repo_sync_and_backup_20260821.md` §4，结论是收益为零且会
打断生产链。

## 4. 分支

**`master` 是唯一的分支。**

曾经有一条 `zw5/seus-halfdeg-metdata-type`，2026-09-10 快进合并进 `master` 之后
本地和远端都删掉了，提交一个没丢。它原本是给 0.5 度气象数据用的，后来装进了
tindex 越界修复这类无关的通用改动，边界已经没有意义。**约定：以后直接提交到
`master`**，只有做实验性、可能要丢弃的改动时才另开分支。

合并用的是 `git branch -f master <分支>` 而不是 `checkout` + `merge`。因为是快
进，移动指针就够了，工作树一个字节都不动，源码时间戳不变，不会触发多余的
`case.build` 重编译。

## 5. 我改了什么

截至 `2d7b31f799`（2026-09-10），43 个提交合计 31 个文件，`+3626 / -75`。
数字锚定到具体提交，因为记录数字的那次提交本身又会让数字过期，不锚定就得反复
追改。用 `git diff --stat origin/master...HEAD` 取当前值。按用途分四类：

**机器接入（`cime_config/machines/`）**

- `config_machines.xml`、`config_batch.xml`、`config_pio.xml`、
  `cmake_macros/pathfinder_gnu.cmake`
- 5 个 fmyuan cherry-pick 提供了 Pathfinder 机器条目本身，以及 PETSc / ATS /
  AMANZI-TPLS 的设置
- 自己加的：单节点最大任务数提到 128；修掉 `case.build` 时的 Lmod load-storm
  （去掉冗余的 gcc / openmpi 加载）

**CPL_BYPASS 强迫场读取器（`components/elm/src/cpl/lnd_import_export.F90`，
以及 `main/atm2lndType.F90`）** — 这是改动最集中的地方：

| 改动 | 说明 |
| --- | --- |
| HDM reader 分辨率与日历无关化 | 原实现假定固定分辨率 |
| Ndep reader 按日历年读 | 原实现用硬编码索引，post-2005 会冻结 |
| 0.5 度分支 | era5-daymet met reader 的 0.5 度路径 |
| future 分支 | 2024–2100 的 SSP 强迫，4km 与 0.5 度各一条 |
| restart 时间索引钳制（缺陷 A） | 重启时 forcing index 越界 |
| transient window 末端防护（缺陷 B） | 气象记录末尾的一元素越读 |

**mksurfdata_map 工具（`components/elm/tools/mksurfdata_map/`）**

`build_pathfinder.sh`、`namelist`、`run_mksurfdata_c0723.sbatch`。

**Slurm 脚本与文档**

`jobs/` 下 11 个构建与诊断脚本，`docs/` 下 10 份技术文档，外加一份 `.gitignore`
（忽略 Slurm 作业输出、mksurfdata_map 的就地编译产物、`.bak` 副本和 `fort.*`）。
每个修复都有对应的
文档，文件名带日期，是排查过程和验证证据的一手记录。

## 6. 日常用法

**提交并推送**（`git add` 写具名路径，不要 `-A` 或 `.`，这个目录里可能有别的
工作流留下的未跟踪文件）：

```bash
cd /projects/hpcl-cli185/proj-shared/zw5/E3SM
git add <改动的具体路径>
git commit -m "<说明>"
git push mygh master
```

**首次 push 或大批量 push 时限制线程。** 登录节点有 128 个核，`pack-objects`
默认按核数开线程，属于工作区规则禁止的登录节点重负载：

```bash
git -c pack.threads=2 push mygh master
```

日常几个提交的增量只有几百 KB，不需要这个参数。

**在别处克隆**（需要 GitHub 账号对该私有仓库有读权限）：

```bash
git clone --recursive git@github.com:zzw0034/E3SM-pathfinder.git
```

**核对两端是否一致**：

```bash
git ls-remote mygh && git rev-parse master
```

**取上游更新**（只 fetch，不要随便 merge）：

```bash
git fetch origin
git fetch https://github.com/E3SM-Project/E3SM.git fmyuan/ornl-pathfinder-machine-settings
```

上游那条分支**会被反复 rebase，SHA 不稳定**。要挑 commit 必须重新 fetch 再查，
不能照抄笔记或邮件里的 SHA。

## 7. 几个坑

- **不要在 GitHub 网页上点合并。** 网页合并只动远端，Pathfinder 上的分支不会
  跟着动，两边就分叉了。合并在 Pathfinder 上做完再 push。
- **推送后 GitHub 会挂一条 "had recent pushes / Compare & pull request" 黄条。**
  那只是建议按钮，不点什么都不会发生。本仓库不是 fork，PR 目标只能是自己仓库
  内部，不会误发到 ORNL。
- **`origin` 不要动。** 它没有写权限，但取上游更新还得靠它。
- **子模块不用推**，见 §2。
- **不要合并 `origin/master`**，见 §3。
