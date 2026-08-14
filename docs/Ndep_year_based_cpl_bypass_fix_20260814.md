# CPL_BYPASS Ndep 按年份读取修复

日期：2026-08-14

## 目的

修复 ELM `CPL_BYPASS` 路径中 N 沉降（Ndep）输入的硬编码年份索引问题，使
2016 年之后的年份也能正确读取到对应年份的 Ndep 数据，而不是一直复用 2016
年的值。这是和 [`HDM_high_resolution_cpl_bypass_fix_20260717.md`](HDM_high_resolution_cpl_bypass_fix_20260717.md)
同一类问题的姊妹修复——那次修的是 HDM（人口密度）的时间索引，这次是 Ndep。

## 原问题

`components/elm/src/cpl/lnd_import_export.F90` 里 Nitrogen deposition 那段：

```fortran
!DMR note - ndep will NOT be correct if more than 1850 years of model
!spinup (model year > 1850)
nindex(1) = min(max(yr-1848,2), 168)
nindex(2) = min(nindex(1)+1, 168)
```

把模拟年份通过硬编码公式 `yr-1848` 换算成数组下标，并且 clamp 在 168——
对应 1849+168-1=2016 年。任何 `yr >= 2016` 的模拟年份都会一直复用 2016 年
那一条 Ndep 记录，不会读取文件里 2017 年及以后的真实数据，即使 Ndep 源文件
本身已经覆盖到更晚的年份（这次生产 case 用的
`fndep_elm_cbgc_exp_simyr1849-2101_1.9x2.5_ssp245_c240903.nc` 实际覆盖到
2101 年）。

已经用已完成的历史 run
（`20260723_Southeast_hires_s7P_s8hdmfix_harvfix_ICB20TRCNPRDCTCBC`，
1850-2023）的 h0 输出实测验证：`NDEP_TO_SMINN` 域平均值 2016-2023 连续 8 年
完全相同（0.782 gN/m²/yr，精确到小数点后 6 位），而同一 Ndep 源文件里 2017-
2023 年的真实值比 2016 年低 1%~13%（多数年份 6%~13%）——即被冻结的这 7 年
系统性高估了 N 沉降。

## 修改的源文件

```text
components/elm/src/cpl/lnd_import_export.F90
```

只改了一个文件。Ndep 的空间网格（144×96）本身和生产文件一致，没有改，改动
范围严格限定在时间索引这一段。

### 索引方式

不再用硬编码公式推断年份，而是读取 Ndep NetCDF 文件本身的 `YEAR` 变量（和
`NDEP_year` 数据变量的 `time` 维长度一起读出来），要求 `YEAR` 严格递增，按
以下规则选择记录：

1. 模型年份早于输入第一年：固定使用第一条记录。
2. 模型年份位于输入范围内：使用当年和下一年记录做原有的年内线性插值。
3. 模型年份大于或等于输入最后一年：两个索引都固定为最后一条记录。

这个模式和 HDM 那次修复完全一致（同一个 `check_netcdf_status`/
`check_mpi_status` 辅助函数直接复用，不重复定义）。对当前
`simyr1849-2101` 文件，映射为：

| 模型年份 | 第一记录 | 第二记录 | 含义 |
|---:|---:|---:|---|
| 1849 | 1 | 2 | 1849→1850（原代码这里错误地被 `max(...,2)` 挤到记录 2，本次修复顺带修正） |
| 2016 | 168 | 169 | 2016→2017（原代码这里是硬 clamp 的终点） |
| 2100 | 252 | 253 | 2100→2101 |
| 2101 | 253 | 253 | 固定 2101 |
| >2101 | 253 | 253 | 固定输入最后一年 |

### 没有改的部分（有意保持不变，避免范围蔓延）

- Ndep 空间网格仍然硬编码 144×96（`atm2lndType.F90` 里 `ndep1`/`ndep2` 仍
  是固定 `(144,96,1)`），因为生产文件本身就是这个网格，没有像 HDM 那次一样
  遇到网格不匹配的问题，不需要动。
- `ndepdyn_nml` 命名列表里的 `stream_year_first_ndep`/`stream_year_last_ndep`/
  `model_year_align_ndep` 三个变量在 CPL_BYPASS 这条代码路径里读了但从未
  真正使用（标准/非 bypass 的 `ndepStreamMod.F90` 才用得上），这次也没有
  把它们接进来，维持原状。

## 编译验证

### 第一次尝试：`case.build` 撞上无关的 Lmod bug

一开始按常规流程 `sbatch` 提交 `case.build`，在 `hpcl-cli185` 分区排队严重
（另一用户的作业占满全部 20 个节点近 10 小时）。改用公共 `parallel` 分区后，
`case.build` 反复在**加载 module 这一步**（不是编译本身）失败：

```text
ERROR: module command ... load miniforge3/24.11.3-0 DefApps cmake/3.30.5
gcc/12.4.0 openmpi/5.0.5 ... failed with message:
Lmod has detected the following error: A load storm (possibly an infinite
loop) detected for module: "gcc/12.4.0" ... loaded more than 500 times.
While processing ... openmpi/openmpi-4.1.7-test ...
```

排查过程（详见本次会话记录，此处只记结论）：

- 一度怀疑是 `parallel` 分区混了 `blc*`（128 核）和 `pfc*`（84 核）两种
  节点，`--constraint=BL` 限定只用 `blc` 型号后**依然失败**，排除了硬件
  差异这个假设。
- 一度怀疑是 `config_machines.xml` 里 `DefApps` 之后又重复显式
  `load gcc/12.4.0`/`load openmpi/5.0.5` 触发的，删掉这两行重复加载、跑
  `case.setup --reset` 验证时**表面上依然失败**——但这是判断过早：
  `case.setup --reset` 的报错信息里出现 `gcc/12.4.0`，只是因为 Lmod 的错误
  追踪会把 `DefApps` 级联加载到的模块也列出来，**不代表 CIME 还在重复显式
  请求它**。当时把这次改动撤销了，判断错误，第 3 节里已经纠正并重新验证过。
- 用户提示核对 `.bashrc` 之后，注意到 `.bashrc` 从来不显式 `load
  gcc/12.4.0`/`openmpi/5.0.5`（`DefApps` 自己就会带出这两个默认值），而且
  是逐个 `module load`，不是一条命令里塞一大串。专门做了隔离测试：完全照
  `.bashrc` 的方式（跳过显式 gcc/openmpi、逐个加载）连续跑两遍，**九步全部
  返回码 0，一次"load storm"都没有触发**——不是"容错扛过去"，是压根不
  发生。
- 最终确认真正的触发条件：**在同一条 `module load` 命令里，如果 `gcc/12.4.0`
  被处理两次**（一次是 `DefApps` 自己的级联加载，一次是紧接着又显式写一遍
  `load gcc/12.4.0`），Lmod 的依赖解析就会在这次重复处理里触发"load storm"
  误判（>500 次重复加载，牵出一个不相关的 `openmpi/openmpi-4.1.7-test`
  模块）。走 shell 的 `module` 命令时，这个报错是非致命的（返回非 0，但
  Lmod 最终还是算出了正确结果，脚本没写 `set -e` 就继续跑下去了）；走 CIME
  用的 Lmod Python 接口（`lmod python load ...`）时，这个报错被当成致命错误
  直接中止 `case.build`。**去掉这两行冗余的显式加载，让 `DefApps` 只被处理
  一次，两条路径都不会再触发这个问题**——第 3 节里用真正的 `case.build`
  重新验证过，问题已经解决，不再需要绕过。

  真正让我们最先注意到"或许不需要 module load"这条线索的，是用户之前一次
  在 `parallel` 分区跑成功的运行脚本（`20260619_..._ad_spinup` 的提交
  脚本）——它完全不走 `module load`，直接把 `LD_LIBRARY_PATH` 硬编码指向
  Spack 编译好的库路径后 `srun e3sm.exe`。这个脚本本身不需要改，但它提示了
  "或许根本不需要重复显式加载 gcc/openmpi"这个方向。

**注意**：`case.setup --reset` 在诊断过程中失败了一次，连带清空了
`20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup` 这个 case
自己的 `env_mach_specific.xml`、`.case.run`、`Macros.cmake`、`cmake_macros/`
（`Macros.make` 这次构建流程本来就不需要，不受影响）。已经从配置完全相同
的姊妹 case（`20260717_Southeast_hires_s7P_s8hdmfix_ICB1850CNPRDCTCBC`）
复制对应文件、替换 case 名后补回，`e3sm.exe` 本身全程未受影响（时间戳在
整个诊断过程中一直是修复前的 2026-07-17 14:06，直到最终编译成功才更新）。

### 第二次尝试：绕过 `case.build`，直接在共享的 `cmake-bld` 里手动 `make` —— 成功

鉴于 Python Lmod 接口的问题一时半会解决不了，改为绕开 `case.build`：在共享
的 `bld/cmake-bld/` 目录里，用能正常工作的 shell 方式加载好 module 之后，
直接 `make -j32 e3sm.exe`。

第一次尝试因为绕过了 `case.build`，没有走 `env_mach_specific.xml` 里
`$ENV{OLCF_NETCDF_C_ROOT}` 这类间接引用到 `NETCDF_C_PATH` 等变量的转换，
CMake 报 `NETCDF not found`；补上这几个环境变量的显式 `export` 后，构建
从 `[  0%]` 一路推进到 `[100%] Built target e3sm.exe`，退出码 0。

构建脚本：`jobs/manual_build_ndep_fix.slurm`（同目录下 `build_ndep_fix.slurm`
是走标准 `case.build` 路径但会撞上面那个 Lmod bug，留作以后 Lmod 问题解决
后的备用）。

- Slurm Job ID：`460455`
- 资源：`parallel` 分区 / `normal` QOS / `--constraint=BL`，1 node，32 cpus，
  120G mem
- Elapsed：1 分 17 秒
- 状态：`COMPLETED`，ExitCode `0:0`

构建日志确认 `lnd_import_export.F90` 被重新编译（无报错）：

```text
[ 88%] Building Fortran object cmake/lnd/CMakeFiles/lnd.dir/__/__/elm/src/cpl/lnd_import_export.F90.o
...
[100%] Linking CXX executable .../bld/e3sm.exe
[100%] Built target e3sm.exe
```

构建前已备份原可执行文件为 `bld/e3sm.exe.bak.20260814_prendep`（27149184
字节，2026-07-17 14:06）。构建后 `bld/e3sm.exe` 更新为 27083600 字节，
2026-08-14 16:29。

### 第三次：真正修复 `case.build` 的 Lmod 问题，不再需要绕过

在用户提示核对 `.bashrc` 之后，按上面"排查过程"最后确认的根因，重新在
`cime_config/machines/config_machines.xml` 的 `pathfinder` 机器、
`compiler="gnu" mpilib="openmpi"` 那个 `<modules>` 块里删掉两行冗余的显式
加载：

```diff
        <command name="load">DefApps</command>
-       <command name="load">gcc/12.4.0</command>
-       <command name="load">openmpi/5.0.5</command>
        <command name="load">cmake/3.30.5</command>
```

（保留了一段注释解释原因，方便以后维护这个文件的人不会又加回去。）

这次没有再跑 `case.setup --reset`（上次跑这个命令中途失败，删空了 case
自己的配置文件，见下面"注意"），而是直接手动把同样两行从这个 case 自己
缓存的 `env_mach_specific.xml` 里删掉，然后跑 `./case.build`：

- Slurm Job ID：`460471`（第一次 `460469` 因为 `cmake_macros/CMakeLists.txt`
  缺失失败，是诊断过程中意外删掉、当时没补全的另一个文件，补上后重跑）
- 资源：同上（`parallel` / `normal` QOS / `--constraint=BL`，1 node，32
  cpus，120G mem）
- Elapsed：1 分 14 秒
- 结果：`MODEL BUILD HAS FINISHED SUCCESSFULLY`，退出码 0，**全程没有任何
  Lmod 报错**

`config_machines.xml` 这处改动是**独立于 Ndep 年份修复的另一个 bug**，只是
在验证 Ndep 修复的过程中顺带发现并修好的。以后任何 `case.build`/
`case.setup --reset`/新建 case，都应该不会再撞上这个问题——但**只有走过
`case.setup --reset`（或新建 case）、重新生成过 `env_mach_specific.xml` 的
case 才会吃到这个修复**；已经存在、`env_mach_specific.xml` 是旧版本的其他
case（比如这次涉及到的两个姊妹 case），如果以后要对它们跑 `case.build`，
第一次大概率还是会撞上同样的报错，需要手动删掉这两行，或者干脆跑一次
`case.setup --reset`（现在 module 加载这步已经不会失败了，可以放心跑）。

## 尚未做的验证（重要，不要当作已完成）

- **没有做 runtime smoke test。** 这次只验证了"代码改动能正确编译并链接
  成新的 `e3sm.exe`"，**没有**像 HDM 那次修复一样，另开一个独立 case 实际
  跑几步、检查 land 日志里 `Ndep input: ... records; using records ... and
  ...` 这行输出、核对 history 里 `NDEP_TO_SMINN` 是否真的按年份变化了。
  在把这份新 `e3sm.exe` 用到任何生产 case 之前，应该先做这一步。
- 尚未决定是否要重跑 2016-2023 这段历史（用修复后的代码，从 2015/2016 年
  附近的 restart 分支，只重跑这几年，不需要整段 1850-2023 重来）——这是
  用户自己的决定，取决于下游分析是否具体用到这几年的结果。

## 科学解释限制

和 HDM 那次修复一样：这个代码修复只保证**以后**能正确读取 2017 年及以后
的 Ndep，不会修复**已经完成**的历史 run 里 2017-2023 那 7 年被冻结在 2016
年值的状态。是否需要用新代码重跑这段历史，见上一节。

## 仓库状态

两处改动都已提交到本地 Git：

- `components/elm/src/cpl/lnd_import_export.F90`——Ndep 按年份读取的主要
  修复
- `cime_config/machines/config_machines.xml`——顺带修复的 `case.build`
  Lmod load-storm 问题

分支为本地 `master`，领先 `origin/master`（尚未 push，按仓库惯例不主动
push 到远程）。
