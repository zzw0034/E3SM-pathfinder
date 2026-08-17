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

## 4. Runtime smoke test（2026-08-14/15）——完整排查过程和最终验证

编译验证通过之后，另开了一个独立的轻量 case 做真正的 runtime 验证（不影响任何
生产 case），过程中连续撞上好几个和 Ndep 代码本身无关、但下次做类似事情一定会
再遇到的坑。按遇到的顺序记录。

### 4.1 建测试 case：`create_clone --keepexe`

```bash
cd /projects/hpcl-cli185/proj-shared/zw5/E3SM/cime/scripts
./create_clone --case .../e3sm_cases/20260814_ndep_fix_smoke \
  --clone .../e3sm_cases/20260723_Southeast_hires_s7P_s8hdmfix_harvfix_ICB20TRCNPRDCTCBC \
  --keepexe
```

**坑 1：`--keepexe` 会把 `RUNDIR` 也指向被克隆的那个原 case 的运行目录，不只是
`EXEROOT`。** 如果直接跑起来会往生产历史 run 的运行目录里写文件（覆盖
`lnd_in`、日志等）。克隆完必须立刻手动 `xmlchange RUNDIR=` 指到一个独立目录，
再 `preview_namelists` 重新生成一遍。

### 4.2 挑 restart：只有稀疏的几个可用

历史 case 只保留了 6 个 restart：1850/1879/1908/1937/1966/1995/2024（间隔约 29
年，不是文档里写的 `REST_N=20`，可能中间的被清理过），**1995 到 2024 之间没有
任何一个**。想测 2016 年之后又要避免重新花时间从 1995 年往后跑，只能先接受用
2024-01-01 这份。

### 4.3 `BUILD_COMPLETE` 被 `case.setup --reset` 顺带重置成 FALSE

在诊断 §3 提到的那次失败的 `case.setup --reset` 之后，这个 flag 也被清空了，
新 case 继承过来后第一次 `.case.run` 直接报 `ERROR: BUILD_COMPLETE is not
true`。手动 `xmlchange BUILD_COMPLETE=TRUE` 修复（执行文件本身没问题，只是这
个状态位被误清）。

### 4.4 `-DCPL_BYPASS` 编译宏在重新编译后消失——最隐蔽的一个坑

修好 Lmod 之后重新编译，`case.build` 本身成功，但一提交真正的 run 就在耦合器
初始化阶段报错：

```
ERROR: (seq_mct_drv) ERROR: if prognostic surface model must also have atm present
```

查了这行报错的源码（`driver-mct/main/cime_comp_mod.F90:2001`）：

```fortran
#ifndef CPL_BYPASS
    if ((ice_prognostic .or. ocn_prognostic .or. lnd_prognostic) .and. .not. atm_present) then
       call shr_sys_abort(subname//' ERROR: if prognostic surface model must also have atm present')
    endif
#endif
```

这个检查被 `#ifndef CPL_BYPASS` 包住，**只有编译时没定义 `CPL_BYPASS` 才会存
在**。说明这次重新编译出来的可执行文件，driver 部分根本没有带 `-DCPL_BYPASS`。

排查这个宏到底应该从哪来，找了很久都找不到：

- `env_build.xml`（`ELM_CONFIG_OPTS`、`USER_CPPDEFS`）——没有
- `components/elm/cime_config/config_compsets.xml`（compset 定义本身）——没有
- 每个 case 自己的 `cmake_macros/*.cmake`、共享模板
  `cime_config/machines/cmake_macros/pathfinder_gnu.cmake`——都没有
- CIME 核心 `cime/CIME/build.py`、ELM/driver 各自的 `buildlib_cmake`——都没有
- 共享编译目录的 `CMakeCache.txt`——也没有（说明不是持久缓存的值，是每次编译
  重新拼出来的）

**真正来源是 `elm-olmt`（`/projects/hpcl-cli185/proj-shared/zw5/elm-olmt`）这个
外部 Python 封装工具，不是 CIME/E3SM 自身的机制。** 用户提示去看对应的 OLMT
`.cfg` 文件（`Southeast_hires_lndseries_s7P_s8hdm.cfg`）才发现 `[simulation]`
段里有 `use_cpl_bypass = True`；再查 `elm-olmt/model_ELM/main.py` 找到具体逻辑
（约 1011-1012 行）：

```python
if (os.path.isfile("./cmake_macros/universal.cmake")):
    os.system("echo 'string(APPEND CPPDEFS \" -DCPL_BYPASS\")' >> cmake_macros/universal.cmake")
```

也就是说：**OLMT 在最初建 case 时，如果 cfg 里 `use_cpl_bypass = True`，会自己
往 `cmake_macros/universal.cmake` 追加这一行**，把 `-DCPL_BYPASS` 一次性写死进
这个 case 的构建配置里，纯 CIME 侧完全查不到、也不会自动重新生成。这次因为
`case.setup --reset` 中途失败删空了 `cmake_macros/`，后来手动从姊妹 case 复制
文件补回来时，**姊妹 case 自己的 `universal.cmake` 里恰好也没有这一行**（可能
那个姊妹 case 建立时机或方式不同），于是这行关键设置就在"修复"过程中悄悄丢失
了。

**修复**：手动把这一行加回该 case 的 `cmake_macros/universal.cmake`：

```bash
echo 'string(APPEND CPPDEFS " -DCPL_BYPASS")' >> cmake_macros/universal.cmake
```

加完之后还踩了两个连环坑：

1. **仅仅改了 `.cmake` 文件内容，`make` 不会自动重新配置。** `cmake_macros`
   文件内容变了，但 `CMakeCache.txt` 还在，`cmake_check_build_system` 只检查
   顶层文件的时间戳，不会因为宏文件内容变化就触发完整重新 configure。必须手
   动删掉 `bld/cmake-bld/CMakeCache.txt` 强制下次 `make` 完整重新 configure。
2. **就算强制重新 configure 了，已经存在且比源码新的 `.o` 文件也不会自动重
   编。** 第一次强制重新 configure 后的编译日志里，`driver-mct` 的
   `cime_comp_mod.F90` 确实带上了 `-DCPL_BYPASS`（因为它这次真的被重新编译
   了），但我们改过的 `lnd_import_export.F90` 完全没出现在日志里——它的
   `.o` 时间戳比源码新，`make` 认为它"已经是最新的"，直接跳过，继续用几小
   时前**没有** `-DCPL_BYPASS` 编译出来的旧版本。必须手动
   `touch components/elm/src/cpl/lnd_import_export.F90` 才能强制它重编。

三步做完（补 `universal.cmake` → 删 `CMakeCache.txt` → `touch` 源文件 →
`case.build`）之后，编译日志里 `lnd_import_export.F90` 和 `cime_comp_mod.F90`
的编译命令都确认带上了 `-DCPL_BYPASS`，问题解决。

**How to apply**：以后任何时候如果 CPL_BYPASS 相关的运行时行为看起来不对（比
如耦合器报 `atm_present` 相关的错、或者 CPL_BYPASS 该有的分支没生效），第一
件事应该是去查编译日志（`bld/*.bldlog.*.gz`）里对应源文件的编译命令有没有
`-DCPL_BYPASS`，而不是去查 CIME 的 XML 配置——这个宏的来源在 OLMT 里，不在
CIME 里。

### 4.5 Runtime 找不到 `libpnetcdf.so.4`

`.case.run` 内部会按 `env_mach_specific.xml` 自己重新构建一遍运行环境，会把
提交脚本里手动 `export` 的 `LD_LIBRARY_PATH` 覆盖掉。改成绕开 `.case.run`，
参考用户之前一次手写成功的运行脚本（`20260619_..._ad_spinup` 的提交脚本），
直接：

```bash
./preview_namelists
mkdir -p "${RUNDIR}/timing/checkpoints"
srun --export=ALL --nodes=2 --ntasks=168 --ntasks-per-node=84 --cpu-bind=none -c 1 \
  "${EXEROOT}/e3sm.exe" > "${RUNDIR}/e3sm_log.txt" 2>&1
```

**光在提交脚本里 `export LD_LIBRARY_PATH=...` 还不够**——`srun` 默认不会把
调用它的批处理脚本的环境变量传给它在计算节点上启动的任务进程，必须显式加
`--export=ALL`，否则远程任务进程拿到的是一个干净环境，同样找不到
`libpnetcdf.so.4`。

用到的库路径（Spack 编译产物，和 OLMT/case 生成的 `LD_LIBRARY_PATH` 无关，是
手动硬编码的）：

```bash
export LD_LIBRARY_PATH=/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/parallel-netcdf-1.12.3-uxv6pfdmjakpoqesfehfvup4a6likqmv/lib:/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/netcdf-fortran-4.6.1-dpqjrikidtzwxfym4vsrrmobz77mlzwo/lib:/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/netcdf-cxx-4.2-v4pq7x4yk4cuwmiebhd2ffadlfkfkoyv/lib:/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/netcdf-c-4.9.2-tr7a3kauxhjzi6donei4k6a4cvrbpllp/lib:/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/netlib-lapack-3.11.0-eh4qxzswhku5draqpvzgzg5sdaj2iuio/lib64:/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/openmpi-5.0.5-ajpfcyc4knmqijf7z6bdiihugbld46zz/lib:/software/baseline/nsp/gcc/12.4.0/lib64:/software/baseline/nsp/spack-envs/base-25.05/opt/gcc-12.4.0/hdf5-1.14.5-62cn3btjtjtipyahzkw24m6m5k5obqxp/lib
```

补充确认：OLMT 自己正常提交任务走的是标准的 `./case.submit`（进而调用
`.case.run`），不是绕开它——查了 `elm-olmt/model_ELM/main.py` 的
`submit_case()`，也查了 git 历史，这条路径一直都是标准 CIME 流程。这次
`.case.run` 报错更可能是这个测试 case 的 `env_mach_specific.xml`（从姊妹 case
复制来的）细节没有完全对上，不是 `.case.run` 机制本身有问题；OLMT 平时跑得动
是因为它走的是完整、正确生成的 case 状态。手写 `srun` 只是这次绕过验证问题的
手段，不代表以后都应该抛弃 `case.submit`。

### 4.6 测试起始日期不能超出气象强迫文件覆盖范围

一开始用 `RUN_STARTDATE=2024-01-01`（配合 2024-01-01 restart），但历史气象
bypass 文件只到 2023 年底（`endyear_met_trans=2023`），而且这段代码对"年份超
出气象文件覆盖范围"**完全没有边界检查**，会直接算出越界的数组下标。

解决办法：**`finidat`（初始状态用哪份 restart）和 `RUN_STARTDATE`（模拟时钟从
哪天开始）在 CIME 里是两个独立设置**，这个 case 的命名列表本来就关掉了年份一
致性检查（`check_finidat_year_consistency = .false.`）。于是继续用 2024-01-01
restart 的状态，但把 `RUN_STARTDATE` 单独改成 `2020-01-01`——落在气象数据覆盖
范围内，又晚于旧代码冻结的 2016 年，两头都不耽误。

### 4.7 墙钟时间

20 分钟不够用（超时被杀，但日志显示只是卡在同一处没往前走，不是明确报错）；
中间提交过 1 小时的但还没排上就被换成 5 小时；**最终真正跑起来只用了 7 分钟**
就完成。最早 20 分钟超时的具体原因没有查清（怀疑是集群负载波动或者节点本地
缓存冷启动的一次性开销），不完全确定，以后如果又出现"跑很久卡在同一行不动"
的情况，先怀疑是排队/节点分配问题，不一定是代码卡死。

### 4.8 最终验证结果

`lnd.log.260814-182200`：

```text
Successfully initialized the land model
HDM input: 504 x 324 grid, 251 records; using records 171 and 172.
Ndep input: 253 records; using records 172 and 173.
Beginning timestep : 2020-01-01_00:00:00
Beginning timestep : 2020-01-01_01:00:00
```

`srun` 退出码 0，干净结束。手算核对：`RUN_STARTDATE=2020-01-01`，Ndep 文件
第 1 条记录对应 1849 年，新代码算出的下标 `2020-1849+1=172`，**和日志里
"using records 172" 精确吻合**。用旧代码同样的年份会算出
`min(max(2020-1848,2),168)=168`（卡死复用 2016 年那条），和 172 明显不同——
这就是新旧代码在这个具体年份上的真实差异，用实际运行日志实锤，不是纸面推导。

日志里两处 `ERROR` 字样核对过，只是变量名 `CMASS_BALANCE_ERROR`（一个诊断量
的名字，出现在 history 变量定义表里），不是真正的运行时错误。

**结论：Ndep 按年份读取的修复，代码编译正确、运行时行为也验证正确。**

## 尚未做的验证

- **history 输出（`NDEP_TO_SMINN` 之类）还没有核对。** 这次 smoke test 只跑了
  2 个 3600 秒的短时间步（`STOP_N=1` 加上耦合频率导致的一点误差），没有触发
  任何 history 写盘（`hist_htapes_wrapup` 显示"no open file to close"），只
  确认了 land 日志里 `Ndep input:` 这行诊断信息，没有从 history 文件里独立核
  对 `NDEP_TO_SMINN` 数值本身是不是也变了（原理上应该会，因为 `forc_ndep_grc`
  就是直接从这两条记录插值算出来的，但没有像之前查 2016-2023 冻结问题那样再
  单独跑一遍时间序列去交叉验证）。
- 尚未决定是否要重跑 2016-2023 这段历史（用修复后的代码，从 2015/2016 年
  附近的 restart 分支，只重跑这几年，不需要整段 1850-2023 重来）——这是
  用户自己的决定，取决于下游分析是否具体用到这几年的结果。

## 科学解释限制

和 HDM 那次修复一样：这个代码修复只保证**以后**能正确读取 2017 年及以后
的 Ndep，不会修复**已经完成**的历史 run 里 2017-2023 那 7 年被冻结在 2016
年值的状态。是否需要用新代码重跑这段历史，见上一节。

## 5. `pfc*` 节点 MPI_Init 系统性失败（2026-08-17，与 Ndep 代码无关，记录备查）

在做一次不相关的 `/projects` vs `/scratch` I/O 对比测试时（8 节点、672 任务、
84 任务/节点，对应 `pfc*` 机型的核数），`e3sm.exe` 在 **MPI_Init 阶段**直接
失败：

```text
It looks like MPI_INIT failed for some reason...
  ompi_mpi_init: ompi_mpi_instance_init failed
  --> Returned "Out of resource" (-2) instead of "Success" (0)
```

### 排查过程

- 一度怀疑是任务规模太大触发资源耗尽，但用一个方法论有问题的"按规模二分"
  脚本（没有 `cd` 进正确的 RUNDIR，任务数也没和 case 实际配置的 NTASKS 对
  上）得到的结果不可信，不能作为证据。
- 排除了常见嫌疑：
  - `ulimit -l`（锁定内存）：登录节点和计算节点上都确认 `unlimited`
  - 共享内存：`/dev/shm` 378G，`shmmax`/`shmall` 内核默认上限（巨大），远
    没有用满
  - 文件描述符：`ulimit -n` 131072，足够
  - module 环境：确认 `Currently Loaded Modules` 里 12 个模块都正确加载
  - 环境变量传递：`srun --export=ALL` 已经在用
- **真正有效的对照实验**：直接复用已经在 `blc` 节点上跑成功过的 smoke test
  case（168 任务、2 节点，`RUNDIR`/命名列表都是对的、`NTASKS` 完全匹配），
  **只把 `--constraint` 从 `BL` 换成 `PF`，其他一个字节都不改**，同样的
  `"Out of resource"` MPI_Init 失败照样出现。这是唯一严格控制变量、只换硬件
  类型的测试，结论可信。
- 失败是**部分任务级别的**（比如 84 个任务里只有十几个报错崩溃），不是全部
  同时死掉——这会导致存活的任务卡在等待崩溃任务响应的 MPI 集合通信操作上，
  整个作业**假死**（Slurm 里显示 `RUNNING`，但日志文件几分钟没有任何新内容
  写入，需要靠对比日志的修改时间戳和当前时间来判断，不能只看 `squeue` 的
  状态字段）。

### 结论

**`pfc*` 节点本身的 InfiniBand/MPI 初始化有系统性问题，和 Ndep 代码、
CPL_BYPASS 修复、任务规模、我们的 Slurm 脚本写法都无关。** `blc*` 节点
（128 核，`--constraint=BL`）在同样的场景下一直工作正常。`pfc*` 节点还有另
一个代际差异（部分是 `IB,HDR,PF`、部分是 `IB,NDR,PF`，网络代际不统一，见
本文档更早关于 `sinfo -N -o '%N %f'` 的记录），可能和这个 MPI 初始化问题有
关联，但没有确认因果关系——这需要系统管理员权限才能进一步排查（查 IB HCA
固件/驱动版本、PMIx 配置等），不是应用层能解决的。

**How to apply**：以后任何需要多节点 MPI 并行的作业，`--constraint=BL` 是
唯一验证过可靠工作的选择；`pfc*`（`--constraint=PF`）目前应该避免用于任何
真正需要跑完的生产作业，除非先联系管理员确认这个 MPI 初始化问题已经解决。
判断一个"看起来在跑"的作业是不是真的假死，别只看 `squeue` 的 `ST` 列，要
去对比它实际输出文件的最后修改时间和当前时间。

## 仓库状态

两处改动都已提交到本地 Git：

- `components/elm/src/cpl/lnd_import_export.F90`——Ndep 按年份读取的主要
  修复
- `cime_config/machines/config_machines.xml`——顺带修复的 `case.build`
  Lmod load-storm 问题

分支为本地 `master`，领先 `origin/master`（尚未 push，按仓库惯例不主动
push 到远程）。

`elm-olmt` 里 `cmake_macros/universal.cmake` 追加 `-DCPL_BYPASS` 这个机制、以
及 `20260712_..._ad_spinup` 这个 case 自己的 `cmake_macros/universal.cmake`
现在已经补回这一行，都不在这个 E3SM git 仓库的管辖范围内（`elm-olmt` 是独立
仓库，case 目录不是 git 追踪的），本文档是目前唯一记录这件事的地方。
