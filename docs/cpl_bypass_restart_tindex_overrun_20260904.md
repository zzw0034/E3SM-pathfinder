# CPL_BYPASS 重启时气象驱动时间索引越界修复

日期：2026-09-04

## 目的

修复 ELM `CPL_BYPASS` 路径中**重启初始化**计算气象驱动时间索引时缺少上界
保护的问题。该缺陷导致 4km transient 从特定年份 restart 时读取
`atm2lnd_vars%atm_input` 越界，把任意堆内存当作气象驱动喂给陆面模式。

这是 [`HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md`](HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md)
的同类问题——都是 `cpl_bypass` 时间索引的 clamp 缺失，那次修的是 HDM/Ndep
在 pre-1850 spinup 下的 clamp，这次是气象驱动在 restart 初始化路径上的 clamp。

修改文件：`components/elm/src/cpl/lnd_import_export.F90`（第 580、582 行）
提交：`3cf28db19f`，分支 `zw5/seus-halfdeg-metdata-type`

## 症状

case `20260902_Southeast_hires_s7P_s8hdmfix_harvfixsmooth_ICB20TRCNPRDCTCBC`
（4km SEUS transient，`metdata_type='era5-daymet'`）。

分段跑时前三段正常（1879、1908 的 restart 都能读），**从 1937 的 restart 起
必崩**，三次尝试、不同节点数、不同节点集合，全部复现：

| 节点数 | 表现 |
|---|---|
| 20 | `lnd_import` 里 SIGSEGV，6-7 个分散的 task，`lnd.log` 恰好停在 2700 行 |
| 10 | 走得更远：init 完成、驱动索引正确读出、进入第一个时间步后碳平衡爆炸 |

10 节点那次的错误信息（更有诊断价值）：

```text
column cbalance error =  2.42e+024    col 6793   31.73N -82.44W
  begcb      = 27888.4        <- restart 状态本身正常
  input      = 0.0
  output     = 1.46e+040
  er         = 1.46e+040      <- 生态系统呼吸，主导项
  hrv_to_atm = -1.48e+033
  totsomc    = -3.30e+018     <- 土壤有机碳也是垃圾
ENDRUN in EcosystemBalanceCheckMod.F90:320
```

关键特征：**多个互不相关的状态量（ER、totsomc、氮平衡、CH4）在同一个时间步
同时变成垃圾，量级从 1e-5 跨到 1e+208。**

## 排查过程

### 走过的弯路（记录下来避免重复）

以下假设**全部被直接测量排除**：

| 假设 | 排除依据 |
|---|---|
| 节点硬件降频 | 三次失败横跨不同节点集合，且已 `--exclude` 已知坏节点 |
| 偶发故障 | 可复现，停在完全相同的日志行 |
| restart 文件损坏 | 两次独立扫描（NaN/Inf、\|值\|>1e30）对比 1908 与 1937 的 restart：153 个变量含 1e36 填充值，计数完全一致，结构除时间戳外相同 |
| `xsmrpool` 异常 | 两份 restart 中范围均为 [-644.7, 0]，无填充值、无极端值 |
| `harvest_rates` 异常 | 源码确认：分配后立即 `= 0._r8`，每次更新前再清零 |
| 失败格点的 landuse 数据 | 两个失败列的 VH1、木本 PFT 占比、PFT 总和均正常，1935-1938 平滑 |
| 气象/CO2/Ndep 索引越界 | 1937 的索引均在范围内，日志中确认正确 |
| 内存、磁盘 | MaxRSS 14.8 GB vs 400 GB 上限；20 T 空闲 |
| 区域分解 | 2560 和 1280 任务下均失败 |

**一个被证伪的错误结论**：曾认为污染源是 `hrv_xsmrpool_to_atm`（它出现在报错
的表达式里）。反例决定性地推翻了它——列 113054 的 `hrv_to_atm = -9.0e-005`
（完全正常），却有 `cbalance error = -1.03e+208`。它只是下游症状。

### 真正定位的方法：bounds checking

上述逐个检查状态量的做法全部落空。改用 **`-fcheck=bounds` 的 DEBUG 编译**，
一次就给出确切位置：

```text
At line 660 of file components/elm/src/cpl/lnd_import_export.F90
Fortran runtime error: Index '131400' of dimension 4 of array
  'atm2lnd_vars%atm_input' above upper bound of 128480
#0  lnd_import   at lnd_import_export.F90:660
#1  lnd_run_mct  at lnd_comp_mct.F90:437
```

与最初 20 节点「SIGSEGV in `lnd_import`」的症状完全对上。

> **注意**：DEBUG 编译时通用 `cmake_macros/gnu.cmake` 带的
> `-ffpe-trap=invalid,zero,overflow` 会在 `mpi_init`（`cime_comp_mod.F90:765`）
> 里就 SIGFPE，18 秒挂掉，根本到不了模式代码。E3SM 上游其它机器配置
> （`craygnu.cmake` 等）的 Fortran 那行都特意去掉了 `invalid`。
> 本次是直接去掉 `-ffpe-trap`、只保留 `-fcheck=bounds,pointer`。
> 详见 `pathfinder/elm_setup_and_run_guide.md` §18。

## 根因

`lnd_import_export.F90` 中，**重启初始化路径（579-594 行）缺少上界保护，
而每步递增路径（623-633 行）有**。

### 精确算术（era5-daymet，1937 重启）

```text
metdata_type='era5-daymet' -> metsource 6, use_daymet
  第 381 行  startyear_met      = 1980
  第 399 行  endyear_met_spinup = endyear_met_trans = 2023
  第 402 行  nyears_spinup      = 2023-1980+1 = 44
  第 517 行  timelen_spinup     = 44 × 2920 = 128480   <- 数组上界
             (2920 = 365 × nint(24/3)，3 小时分辨率)

对齐循环（573-576 行）：
  mystart = 1980 -> 1936 -> 1892 -> 1848
  (1850 - mystart) = 2

1937 走第 582 行（因为 1937 <= endyear_met_spinup = 2023）：
  tindex = (mod(1937-1850, 44) + 2) × 2920
         = (mod(87, 44)      + 2) × 2920
         = (43               + 2) × 2920
         = 45 × 2920
         = 131400                                     <- 越界
```

`mod()` 给出 0..43 本身是对的，**但加上对齐偏移 `+2` 之后没有再取一次模**，
取值范围变成 2..45。

### 受影响的年份

只有 `mod(yr-1850,44) == 43` 才真正越界（`== 42` 得到 44×2920 = 128480，
恰好等于上界，合法但语义错误——指向最后一条记录而非绕回开头）。

```text
崩溃年份：yr ≡ 1893 (mod 44)  ->  1893, 1937, 1981, 2025, 2069, ...
```

**1908-2024 范围内是 1937 和 1981。** 将来从 1981 重启会以完全相同的方式崩溃。

### 为什么连续跑从不触发

```fortran
! 每步递增（623-625 行）—— 有 clamp
if (const_climate_hist .or. yr <= startyear_met) then
   if (tindex > timelen_spinup) tindex = 1

! 重启初始化（579-594 行）—— 只有第 591 行一个 `== 0` 的特判，无上界保护
```

1937 <= `startyear_met`(1980)，所以连续积分时索引到 128480 就绕回 1，
永远不会越界。**只有 restart 之后的第一次调用**才按日期直接算出索引并原样使用。

这也解释了历史：

```text
旧 4km run (20260723)  STOP_N=174, RESUBMIT=0  一个作业跑完 174 年，
                       写过 1937 的 restart 但从未读过
0.5 度 transient       格点数少，未触及
本次 run (20260902)    第一次使用自动 resubmit，于是第一次读 1937 的 restart
```

### 越界读的后果

越界读返回的是任意堆内存，**被当作气象驱动喂给陆面模式**。所以第一个时间步
ER、totsomc、氮平衡、CH4 会同时变成垃圾，量级跨度极大。

- 20 节点：读到未映射内存 -> SIGSEGV
- 10 节点：读到堆内 -> 垃圾数值 -> 碳平衡检查报错

**最危险的情形**：如果垃圾值恰好落在合理范围内，模式会跑完并给出一个错误的
科学结果，且不报任何错。

## 修复

```fortran
- atm2lnd_vars%tindex(g,v,1) = (mod(yr-1850,nyears_spinup) + (1850-mystart)) * 365 * nint(24./atm2lnd_vars%timeres(v))
+ atm2lnd_vars%tindex(g,v,1) = mod(mod(yr-1850,nyears_spinup) + (1850-mystart), nyears_spinup) * &
+                              365 * nint(24./atm2lnd_vars%timeres(v))
```

第 580 行（`yr < 1850` 分支）写法相同，同样修改。

**对原本正常的年份是数学上的空操作**：外层 `mod` 只在内层和达到
`nyears_spinup` 时才改变结果。

| 年份 | 修改前 | 修改后 |
|---|---|---|
| 1908（原本正常） | 14+2 = 16 -> 46720 | mod(16,44) = 16 -> 46720，**不变** |
| 1937（原本崩溃） | 43+2 = 45 -> 131400 | mod(45,44) = 1 -> 2920，正确指向 1981 气象年 |
| 1936 | 42+2 = 44 -> 128480 | mod(44,44) = 0 -> 经第 591 行特判绕到 `timelen_spinup` |

## 验证

三项独立验证，全部通过：

| # | 验证内容 | 作业 | 结果 |
|---|---|---|---|
| 1 | 修复能治好必崩的 case（1937 重启） | 511368 | COMPLETED 0:0，越界 0，两个时间步跑完，干净收尾 |
| 2 | 修复不破坏原本正常的 case（1908 重启） | 511467 | COMPLETED 0:0，越界 0，两个时间步跑完 |
| 3 | 生产作业连续跑过 1936-1937 | 511164 | 1936-03-26 -> 1937-05-10 -> 1938-05-19，零异常 |

第 1、2 项都在 **`-fcheck=bounds` 开启**下运行，所以是「证明没有越界」，
而不是「碰巧没崩」。

第 3 项验证的是因果机制本身：生产作业从 1908 重启（初始索引 46720 在界内），
之后靠**递增**撞上 128480 的 clamp 绕回 1——递增路径有保护，所以它从不受
此 bug 影响。若它在 1937 崩溃，则整个根因分析都需推翻。

判定证据（作业 511368）：

```text
lnd.log 行数: 2718            <- 三次崩溃都恰好停在 2710
Beginning timestep : 1937-01-01_01:00:00    <- 原崩溃点
Beginning timestep : 1937-01-01_02:00:00    <- 已越过
Get data for variable HARVEST_SH1 for year 1938
hist_htapes_wrapup : history tape 1 : no open file to close
```

两次验证的驱动索引不同（1937 为 HDM 88/89、Ndep 89/90；1908 为 HDM 59/60、
Ndep 60/61），确认确实在跑不同年份，不是读到旧日志。

## 经验教训

### 1. 多个不相关状态量同时变垃圾 -> 优先怀疑内存，不要逐个查状态量

当 ER、totsomc、氮平衡、CH4 在同一步同时出错，且量级跨度达 1e-5 到 1e+208
时，这是**读到未初始化/越界内存**的特征。逐个检查这些状态量本身（本次花了
数轮）注定落空，直接上 bounds checking 一次即可定位。

### 2. 选 FP trap 还是 bounds check，取决于坏值长什么样

- 坏值是 NaN/Inf -> FP trap 有用
- 坏值是**很大但有限**的数（如 1e+208、-1.5e+33）-> **overflow trap 不会触发**，
  必须用 `-fcheck=bounds,pointer`

本次属于后者。

### 3. CIME 成功结束时会 gzip 日志——`grep` 会给出假的「全绿」

```bash
grep -c "ERROR" e3sm.log.511368.260904-143331.gz   # 永远返回 0
wc -l  lnd.log.511368.260904-143331.gz             # 数的是二进制里的换行字节
```

**在 `.gz` 上跑 `grep`，对任何模式都返回 0，看起来和「干净通过」完全一样。**
本次差点据此误报一次全绿。判定脚本一律用：

```bash
zc() { case "$1" in *.gz) zcat "$1";; *) cat "$1";; esac; }
echo "越界: $(zc "$E" | grep -c 'above upper bound')"
```

### 4. `case.setup --reset` 会同时抹掉两样东西

切换 PE 布局时踩到，都已在本次流程中确认：

- `cmake_macros/universal.cmake` 里的 `-DCPL_BYPASS` 被抹掉
- `cmake_macros/gnu.cmake` 里手工去掉的 `-ffpe-trap` 被还原

生产 case 曾因此**丢失过 `-DCPL_BYPASS`**（正在跑的 exe 不受影响，因为它在
reset 之前编译；但任何一次重编译都会静默产出错误的二进制）。已修复并留备份。

## 相关文档

- [`HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md`](HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md) — 同类的 cpl_bypass 时间索引 clamp 问题
- [`Ndep_year_based_cpl_bypass_fix_20260814.md`](Ndep_year_based_cpl_bypass_fix_20260814.md) — Ndep 按年份读取
- [`HDM_high_resolution_cpl_bypass_fix_20260717.md`](HDM_high_resolution_cpl_bypass_fix_20260717.md) — HDM 时间索引
- `pathfinder/elm_setup_and_run_guide.md` §18（DEBUG build 的坑）、§19（本问题的速查版）
