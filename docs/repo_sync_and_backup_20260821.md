# 仓库同步与备份现状（2026-08-21）

记录这个 E3SM checkout 与 GitHub 的实际关系，以及为什么目前的异地备份靠一个
git bundle 而不是 push。这两件事都不是从代码或 git 历史里能看出来的，所以写在
这里。

## 两条要点

1. **我们对 `ORNL-Ecosystem-Projects/E3SM` 没有写权限。**读通、写被拒。
2. **因此这 19 个 commit 的异地备份目前靠一个 git bundle**，不是 GitHub。

---

## 1. push 权限被拒（2026-08-21 验证）

```bash
cd /projects/hpcl-cli185/proj-shared/zw5/E3SM
git push --dry-run origin HEAD:refs/heads/zw5/pathfinder-cpl-bypass
```

```text
ERROR: Permission to ORNL-Ecosystem-Projects/E3SM.git denied to zzw0034.
fatal: Could not read from remote repository.
```

`--dry-run` 会真正触发服务器端的 `git-receive-pack`，所以这是有效的权限探测，
不是网络问题。同一天多次 `git fetch origin` 都成功，**说明是读通、写被拒**，
不是认证整体失败。

**影响**：工作区 `AGENTS.md` 里「GitHub 是权威版本历史」这条规则，对这个仓库
**暂时不成立**。在拿到写权限之前，Pathfinder 上的工作树就是唯一的主副本。

**待办**：找 ORNL-Ecosystem-Projects 的管理员开写权限。从 fork 上的分支名看，
可能的联系人是 `dmricciuto`、`fmyuan`，或者发 Pathfinder 上手邮件的 Nick。

## 2. git bundle 备份

在拿到写权限之前的兜底办法。bundle 只装 `origin/master..HEAD` 的差异，不含
E3SM 全部历史，所以很小。

```bash
# Pathfinder 上生成
cd /projects/hpcl-cli185/proj-shared/zw5/E3SM
git bundle create /tmp/zw5_e3sm_20260821.bundle origin/master..HEAD
git bundle verify /tmp/zw5_e3sm_20260821.bundle
```

```text
bundle 包含: 9dfc3c27dcd08c7b77a4e16fe83ab256eac8bdb7 (HEAD)
bundle 需要: c181c41b1ab96aa5488f65eee302bc3cd6bf26c2
大小: 55K
```

`remote -> local` 拉回 Mac，存放于：

```text
/Users/zw5/ORNL_workplace/pathfinder/E3SM_docs/bundles/zw5_e3sm_20260821.bundle
md5 = b7f32bfd91bfd4eee91604ad847035ef（两端一致）
```

### 怎么恢复

bundle 依赖的 `c181c41b1a` 在**公开的** `E3SM-Project/E3SM` 历史里，所以恢复
不依赖 ORNL 那个 fork，也不依赖任何账号权限：

```bash
git clone https://github.com/E3SM-Project/E3SM.git && cd E3SM
git fetch /path/to/zw5_e3sm_20260821.bundle HEAD:recovered
```

19 个 commit 会落到本地分支 `recovered` 上。

### 局限

**这是快照，不是持续同步。**每次有新 commit 都要重新打一次 bundle。真正的解法
仍然是拿到写权限往 GitHub 推。截至 2026-08-21，bundle 覆盖到 `9dfc3c27dc`。

---

## 3. 背景：三个仓库，别搞混

排查 Lmod 问题时在这上面绕了很久，记下来免得重复。

| 仓库 / 分支 | 角色 |
| --- | --- |
| `E3SM-Project/E3SM` : `fmyuan/ornl-pathfinder-machine-settings` | **真正的上游**。Pathfinder 机器修复全在这条分支上。我们没有 remote 指向它 |
| `ORNL-Ecosystem-Projects/E3SM` : `master` | 我们的 `origin`。尖端停在 2026-06-25 |
| `ORNL-Ecosystem-Projects/E3SM` : `fmyuan/`**`machines/`**`ornl-pathfinder-machine-settings` | 名字只差一个 `machines/`，在另一个仓库里，**不是**我们的来源 |
| Pathfinder 本地 `master` | `c181c41b1a` + 5 个 cherry-pick + 14 个自己的 commit |

三者的共同祖先都是 `c181c41b1a`（2026-03-19），**是兄弟关系，不是父子**。

本地这份是 2026-05-18 按 Nick 邮件的 recipe 建的：clone ORNL fork，然后用
`git fetch <URL> <branch>` 从**上游**临时取来 5 个 fmyuan 的 commit 再
cherry-pick。这种临时 fetch 只写 `FETCH_HEAD`、不建 remote-tracking ref ——
所以 `git branch -r --contains <sha>` 查不到它们，会误以为是本地独有。

那条上游分支**会被反复 rebase，SHA 不稳定**。以后要挑 commit 必须重新 fetch
再查，不能照抄笔记或邮件里的 SHA。

## 4. 为什么不合并 `origin/master`

落后 1131 个 commit。2026-08-21 逐个组件核过：

| 组件 | 文件数 | 相关性 |
| --- | --- | --- |
| `components/eamxx` | 483 | SCREAM 大气，land-only 跑不到，零相关 |
| `components/homme` | 108 | 大气 dycore，零相关 |
| `components/elm` | 38 | 唯一可能相关的 |

ELM 那 38 个文件全部落在四类里，没有一类进入我们的代码路径：FATES 相关（我们
用 CN(P)/CTC，不用 FATES）、EHC/GCAM 使用场景、`t_start_lnd` → `t_startf` 的
timer 机械改名、以及 `units=''` → `units='1'` 之类的 metadata 修正。特意验过
`SoilFluxesMod` / `SurfaceAlbedoType` 只有 timer 和 units 改动，`subgridRestMod`
的 20+/20− 只改属性文字、**restart 结构没变**。

**冲突代价其实很小**：我们改过的 `lnd_import_export.F90` 和 `atm2lndType.F90`
上游一次都没动过；`origin/master` 里甚至没有 pathfinder 机器条目，所以那几个
XML 是纯新增。不合并的理由是**收益为零 + 打断生产链**（全量重编译会让现有
`e3sm.exe` 作废，波及 1850→2024 的 restart 链和 TESSFA2 的 future run），
不是冲突。

**重新考虑的触发条件**：需要 FATES / GCAM / EAMxx 的功能；或者需要 fmyuan
2026-06 之后那批 pathfinder commit（它们假设新 master，比如 MOAB 成为默认
coupler driver 那个）；或者要把这些工作 PR 回上游。
