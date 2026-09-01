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

---

## 2026-09-01 更新：根因重新定位——不是 Fortran bug，是分辨率/掩码不匹配

上面整篇文档在 2026-08-31 写的时候，最终结论停留在"没能做到源码级 100% 定
位，但三种编译方式给出三种不同崩溃形态，是未初始化/未定义行为的典型指纹"。
这个结论**现在确认是错的**（或者说，方向错了）——真正原因更简单，也更明确。

**触发新排查的证据**：建 `20260901_seus_halfdeg_transient`（真实历史日历，
`RUN_STARTDATE=1850-01-01`）时，撞上了一模一样的 `ENDRUN:NaN encountered
at an ELM gridcell in HDM input data`——但这次 `lnd.log` 记录的是
`using records 1 and 2`，**不是**被 patch 过的那个钳制分支（`1 and 1`）！
`nindex(1)≠nindex(2)`，走的是正常的"读两条不同记录"路径，跟 smoke_hist 当
初读 1980/1981 年那次成功的路径结构完全一样。这说明问题**不可能**是"同一
条记录读两次"导致的控制流缺陷——因为这次根本没有读同一条记录两次。

**真正的根因**（跟一次独立的 Codex 排查交叉验证过，结论一致）：

1. `stream_fldfilename_popdens` 指向的是 **1/24°（4km 原生分辨率）** 的
   SEUS 区域 HDM 文件（`elmforc.Li_hdm_1_24x1_24_bilinear_SEUS_simyr1850-2100.nc`），
   不是 0.5° 专属版本——这个文件从一开始就该有个 0.5° 专属版本，但
   `DESIGN_DECISIONS.md` §2 那份"哪些输入需要 0.5° 版本"的清单里，HDM
   两边都没列，是一个真实的疏漏，不是经过论证的决定。
2. 直接用 `netCDF4.Dataset.set_auto_mask(False)` 关掉自动掩码重新检查这个
   1/24° 文件的 1850 年那一层（record 0），**真实 NaN 数量是 86714 个**
   （504×324=163296 总格点里）——不是 0！我 8 月 31 日最早做的那次检查用
   的是默认开着自动掩码的 `np.isnan(data).sum()`，而这个文件的 `hdm` 变量
   声明了 `_FillValue = NaN`；netCDF4-python 会把这类"原始值本身就是 NaN"
   的格点识别成掩码（masked），`MaskedArray.sum()` **默认跳过被掩码的元
   素**，导致那次统计结果虚假地显示"0 个 NaN"。这是我自己检查方法上的一
   个真实漏洞，不是文件内容有变化。
3. 崩溃格点（`g=3`）在 0.5° domain 里是一个**沿海分数陆地格点**
   （`frac=0.208`，只有 20.8% 是陆地）。它在 1/24° HDM 网格上找最近邻，
   命中的具体子格点，在**1/24° 产品自己的 `PFTDATA_MASK` 里被判定为海
   洋**——而这份 1/24° HDM 数据的生成脚本**只对陆地格点做缺测填补，海洋
   格点故意留着 NaN**（人口密度在海上没有意义，这是设计如此）。
4. `CPL_BYPASS` 的 HDM reader 只做最近邻取值，**不检查取到的点在源数据里
   是不是被标记为海洋**，于是精确地读到了这个"故意留白"的海洋 NaN。
5. **这个 bug 在 1/24° 原生分辨率下永远不会触发**：4km case 自己的格点本
   身就是 1/24° 分辨率，去同一个 1/24° 网格上找最近邻，基本就是找它自己
   （或紧邻的、同样是陆地判定的格点），不存在"粗格点横跨陆地和海洋、最
   近邻随机落到不相关海洋像元"这种歧义。只有**运行分辨率跟强迫数据分辨
   率不一致**时，这类沿海格点才会暴露这个漏洞——4km case 用这份文件用了
   很多次都没事，0.5° 是第一个真正触发这个组合的场景。

**这也解释了为什么之前三种编译方式给出三种不同崩溃形态**：一个**真实存在
的 NaN 数值**（不是内存corruption）流经 `hdm_value1 /= hdm_value1` 比较、
`write` 打印、严格浮点异常检测（`DEBUG=TRUE` 的 `-ffpe-trap`）这几种不同
场景，IEEE754 对 NaN 的处理在不同编译选项/优化级别下本来就不一样——"体面
报错→段错误→SIGFPE"这个现象序列，用"真实数据里有 NaN，只是触发路径和编译
设置不同导致表现形式不同"就能完全解释，不需要更复杂的"未初始化内存"这个
假设。奥卡姆剃刀。

**HDM（0003）的实际情况**：`min(2, hdm_ntime)` 这个补丁之所以"有效"，纯粹
是因为 1851 年（record 2）这个具体的沿海坐标恰好没有缺口，不是修复了控制
流逻辑。已经用完整年份检查确认：这份 1/24° 源文件的 1850 年这一层，关掉自
动掩码后，`netCDF4` 会显示 86714 个真实 NaN。

**Ndep（0004）的情况没有被同等力度验证过**：Ndep 自己的强迫网格是硬编码
的 144×96 全球粗网格（约 2.5°×1.9°，比 0.5° 还粗很多），根据
`DESIGN_DECISIONS.md` §2 的说明，这个网格的最近邻映射设计上就跟陆地分辨率
无关——不像 HDM 的源数据本身就是陆地分辨率（1/24°）匹配的。所以"Ndep 的
钳制 bug 也是同一种数据缺口"目前只是一个**看起来合理但没有独立验证过**的
推测：这次 `20260901_seus_halfdeg_transient` 的真实日历跑到 1850 年时，
Ndep 解析出来的是 `using records 2 and 3`，根本没有实际读取 record 1，所
以 Ndep record 1 到底干不干净，至今没有被真正测试过。

**实际修复**：给 `20260901_seus_halfdeg_transient` 换成了**标准全球
0.5°×0.5° HDM 产品**（E3SM inputdata 自带的现成文件，不是自己写聚合脚本
新建的 SEUS 专属版本）：

```text
/projects/hpcl-cli185/world-shared/e3sm/inputdata/lnd/clm2/firedata/elmforc.Li_20181205_mod_hist_SSP2_CMIP6_hdm_0.5x0.5_AVHRR_simyr1850-2100_c240906.nc
```

验证过：720×360 全球网格，1850 年这一层关掉自动掩码后**真实 0 个 NaN**；
崩溃坐标 `lon=-80.25, lat=25.25` 在这份文件里精确命中格点中心（不是"凑巧
接近"，两者都是标准 0.5° 规则网格），`LANDMASK=1`，1850 年数值
`0.2498114`，跟 Codex 独立查到的"source 0.5° HDM"数值完全吻合。换上这份
文件后，重新编译提交（job 504445），`lnd.log` 记录
`HDM input: 720 x 360 grid, 251 records; using records 1 and 2.`——**第一
次真正成功读取了 record 1**，随后年份（1851、1852……）也正常逐年推进，
不再崩溃。

**`20260831_seus_halfdeg_ad_spinup`/`20260901_seus_halfdeg_final_spinup`
保持现状，不重跑**：两个 case 都已经用旧的 1/24° 文件 + `min(2, ntime)`
补丁跑完（分别 200 年、440 年）。这个补丁的实际效果是把它们"冻结在
1850 年"的人口密度强迫，实际变成了"冻结在 1851 年"——数值差异极小（人口
密度在这两年之间几乎不变），科学上可以忽略，不值得为了这一年之差重跑
~640 个已完成的 spinup 年份。这个差异已经记录进 SEUS_halfdeg 的
`docs/PLAN.md` 和 `docs/DESIGN_DECISIONS.md` §2。
