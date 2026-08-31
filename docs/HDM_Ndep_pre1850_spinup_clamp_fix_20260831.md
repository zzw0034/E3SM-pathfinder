# HDM/Ndep pre-1850 spinup 钳制修复

日期：2026-08-31

## 背景

0.5° SEUS AD spinup case（`20260831_seus_halfdeg_ad_spinup`，
`RUN_STARTDATE=0001-01-01`）在第一个 timestep 就崩溃。这是第一次有 case
用"模式年从 1 开始"（标准 AD spinup 惯例）去实际跑 `lnd_import_export.F90`
里 HDM（[`HDM_high_resolution_cpl_bypass_fix_20260717.md`](HDM_high_resolution_cpl_bypass_fix_20260717.md)，
2026-07-28 又做了一次"分辨率/日历无关化"重写）和 Ndep
（[`Ndep_year_based_cpl_bypass_fix_20260814.md`](Ndep_year_based_cpl_bypass_fix_20260814.md)，
2026-08-14）这两段代码，此前所有验证过的 case 起始年份都 ≥ 1850 或在
transient 场景里用真实历史年份（如 1980），从没真正走到过"模式年 < 数据起始年
1850"这个分支。

## 排查过程（价值在于排除法，不止是最终结论）

崩溃现象很不稳定，三种不同编译方式给出三种不同的失败形态：

1. 正常（release）编译：`hdm_value1 /= hdm_value1` 比较为真，命中我们自己的
   `endrun(msg='NaN encountered at an ELM gridcell in HDM input data')`，体面报错
2. 加一行 `write` 诊断打印同样的变量：直接 `SIGSEGV`
3. `DEBUG=TRUE`（严格浮点异常陷阱）：还没打印出 `HDM input:` 这行日志就先炸了
   `SIGFPE: Floating-point exception`（且信号触发点早于日志缓冲区 flush，所以
   `lnd.log` 里完全没有内容，一开始误判为"没到 land 模块初始化阶段就崩了"，其实
   只是日志没来得及刷盘）

同一处代码在不同编译方式下崩溃形态完全不同，是未初始化/未定义行为的典型指纹，
而不是数据本身有确定的 NaN——这一点也被直接验证过：`stream_fldfilename_popdens`
指向的 SEUS 0.5° HDM 源文件（`elmforc.Li_hdm_1_24x1_24_bilinear_SEUS_simyr1850-2100.nc`）
逐条记录检查，所有 571 个 SEUS 0.5° 陆地格点、所有年份都没有 NaN；0.5° domain
文件（`domain.lnd.SEUS_0_5deg.nc`）的经纬度坐标（`xc`/`yc`）也没有 NaN；571
task 和 40 task 两种 PE layout 表现完全一致，排除了"任务数导致格点分配异常"的
猜测。

## 根因

`lnd_import_export.F90` 里判断"模式年早于数据起始年"时的钳制逻辑：

```fortran
! HDM，约 904 行
if (const_climate_hist .or. yr < hdm_years(1)) then
    nindex(1:2) = 1
...
! Ndep，约 1126 行
if (yr < ndep_years(1)) then
    nindex(1:2) = 1
```

两处结构完全一致：`nindex(1)` 和 `nindex(2)` 被设成同一个值 **1**。
[`Ndep_year_based_cpl_bypass_fix_20260814.md`](Ndep_year_based_cpl_bypass_fix_20260814.md)
里记录的 Ndep **原始**（2026-08-14 重写之前）硬编码公式是：

```fortran
nindex(1) = min(max(yr-1848,2), 168)
```

注意 `max(yr-1848,2)`——这个下界钳制保证 `nindex(1)` **永远不会小于 2**，
包括 `yr` 远小于 1850（比如我们这次的 `yr=1`）的情况。2026-08-14 那次"按年份
读取"重写把这个隐含的"下界钳在 2"的行为，简化成了显式的"钳到 1"，这是一次
（大概率无意的）行为回归。HDM 这边 2026-07-28 的重写引入的是同一套三分支结构
（早于第一年/在范围内/晚于最后一年），命中同一种"钳到 1"写法。

具体是哪一步真正产生 NaN/段错误/浮点异常，没有做到 100% 的源码级定位（花了
两轮诊断编译——加打印语句、开 `DEBUG=TRUE`——都没能拿到干净的 backtrace），
但钳制到 `nindex(1)=nindex(2)=1` 与钳制到 `nindex(1)=nindex(2)=2` 之间，
观测到的行为差异是确定的、可重复的：前者必现崩溃，后者跑通。

## 修复

```fortran
! HDM
nindex(1:2) = min(2, hdm_ntime)
! Ndep
nindex(1:2) = min(2, ndep_ntime)
```

`min(2, ntime)` 而不是硬编码的 `2`，是为了避免退化成单记录 stream 时的越界
下标（`hdm_ntime`/`ndep_ntime` 均为 251，正常情况下这个 `min` 恒等于 2）。

两处都作为 case-local `SourceMods/src.elm/lnd_import_export.F90` 修改，在
`20260831_seus_halfdeg_ad_spinup` 里验证：

| | HDM | Ndep |
|---|---|---|
| build job | 504032 | 504040 |
| 1 天 smoke run job | 504034 | 504042 |
| `lnd.log` 记录 | `HDM input: 504 x 324 grid, 251 records; using records 2 and 2.` | `Ndep input: 253 records; using records 2 and 2.` |
| `cpl.log` | — | `SUCCESSFUL TERMINATION OF CPL7-e3sm` |

正式记录为 SEUS_halfdeg 仓库的
`patches/e3sm/0003-Restore-legacy-HDM-pre-1850-clamp-for-spinup.patch` 和
`patches/e3sm/0004-Restore-legacy-Ndep-pre-1850-clamp-for-spinup.patch`
（见该仓库 `patches/e3sm/README.md`）。

## 和 Ndep-freeze 科学可比性问题的区别（避免混淆）

SEUS_halfdeg 项目的 `docs/PLAN.md`（"Ndep — the production science case hard
gate"一节）另外记录了一个**完全不同**的 Ndep 问题：已完成的 4km 历史 run
（job 410470）用的二进制在 2016 年之后把 Ndep 冻结在 2016 年的值，2017-2023
这 7 年跟当前代码（已修复冻结问题）不一致，影响的是"0.5° vs 4km 能不能严格
说成只有分辨率一个变量"这个科学可比性问题。

**本文档记录的是另一件事**：不管 Ndep-freeze 那个问题最终怎么解决，任何从
模式年 1 开始的 0.5° AD spinup，只要没有这两个 patch，第一个 timestep 就会
硬崩溃，根本没有机会讨论"数值对不对"。这是一个纯粹的、无条件的崩溃修复，跟
上面那个科学可比性问题相互独立、互不依赖。

## 为什么之前没暴露

Fortran 顺序执行，`call endrun(...)` 内部调用 `MPI_Abort` 立即终止整个进程。
`lnd_import_export.F90` 里 HDM 的读取代码在 Ndep 之前执行。修 HDM 之前，
每次都在 HDM 那步先崩溃退出，代码根本没有机会执行到后面的 Ndep 读取——不是
Ndep 那段代码之前是对的，而是它一直没被跑到过。修完 HDM 之后，程序第一次真正
走到 Ndep 那段代码，才让这个同款的、原本就存在的 bug 暴露出来。

## 修改的源文件

```text
components/elm/src/cpl/lnd_import_export.F90
```

只改了两行（HDM 一行、Ndep 一行），都在同一个文件里。
