# CPL_BYPASS 高分辨率 HDM 读取修复

日期：2026-07-17

## 目的

修复 ELM `CPL_BYPASS` 路径中 HDM（human population density）输入的硬编码问题，使下面的高分辨率文件能够被正确读取和用于火灾计算：

```text
/projects/hpcl-cli185/proj-shared/zw5/ELM_makeSurfdata/Make_surface_data/s8_update_hdm/elmforc.Li_hdm_1_24x1_24_bilinear_SEUS_simyr1850-2100.nc
```

该文件的实际维度为：

- longitude：504
- latitude：324
- time：251
- year：1850–2100

## 原问题

原代码假定所有 HDM 文件都是 `720 × 360`：

- `hdm1` 和 `hdm2` 固定分配为 `(720,360,1)`；
- `nf90_get_var` 的 `count` 固定为 `(720,360,1)`；
- MPI 广播数量固定为 `720*360`；
- 空间搜索循环固定为 720 和 360；
- NetCDF 返回码虽然写入 `ierr`，但没有检查。

读取 504 × 324 文件时，`nf90_get_var` 因目标形状和 `count` 不匹配而失败。错误被忽略后，初始化为零的 `hdm1/hdm2` 继续用于计算，导致 history 中 HDM 全零。

原年份索引还包含两个独立问题：

```fortran
nindex(1) = yr - 1848
...
if (yr .ge. 2010) nindex(1:2) = 161
```

因此 1850 被错误映射到记录 2，并且 2010 年以后始终固定使用 2010 年记录，文件中的 2011–2100 数据完全没有使用。

## 修改的源文件

```text
components/elm/src/cpl/lnd_import_export.F90
components/elm/src/main/atm2lndType.F90
```

### 动态维度和内存

- 初始化时仅为 `hdm1/hdm2` 分配 `(1,1,1)` 占位数组。
- 第一次读取以及每年更新 HDM 时，从 NetCDF 的 `lon`、`lat` 和 `time` 维度查询实际长度。
- 所有 MPI rank 收到实际维度后，按 `(hdm_nlon,hdm_nlat,1)` 重新分配数组。
- `nf90_get_var` 的 `count`、MPI 广播数量和坐标广播长度全部使用实际维度。

### 年份索引

年份不再由硬编码公式推断，而是读取 NetCDF 的 `year` 变量。代码要求 `year` 严格递增，并按以下规则选择记录：

1. `const_climate_hist=.true.`：固定使用第一条记录。
2. 模型年份早于输入第一年：固定使用第一条记录。
3. 模型年份位于输入范围内：使用当年和下一年记录进行原有的年内线性插值。
4. 模型年份大于或等于输入最后一年：两个索引都设为最后一条记录。

对当前 1850–2100 文件，映射为：

| 模型年份 | 第一记录 | 第二记录 | 含义 |
|---:|---:|---:|---|
| 1850 | 1 | 2 | 1850→1851 |
| 2010 | 161 | 162 | 2010→2011 |
| 2099 | 250 | 251 | 2099→2100 |
| 2100 | 251 | 251 | 固定 2100 |
| >2100 | 251 | 251 | 固定输入最后一年 |

### MPI

MPI root 首先读取文件维度和年份记录索引，然后广播：

- `hdm_nlon`、`hdm_nlat`、`hdm_ntime`；
- 两个时间记录索引；
- 两个 HDM 二维场；
- longitude 和 latitude 坐标。

每一次 `mpi_bcast` 都检查返回码。HDM 数据广播数量为 `hdm_nlon*hdm_nlat`，不再使用固定的 `720*360`。

### 空间索引

原代码对每个 ELM gridcell 遍历整个二维 HDM 网格，并在循环内修改 longitude 坐标。新代码改为：

- longitude 和 latitude 分别进行一维最近邻查找；
- longitude 距离使用 360° 周期距离；
- 不修改输入坐标数组；
- 循环长度使用实际 `hdm_nlon/hdm_nlat`。

当前 HDM 文件已经通过 bilinear 方法重网格到 504 × 324 的 SEUS 网格，因此在坐标匹配时，该最近邻查找返回同一网格点。`popdensmapalgo` 在这条旧的 CPL_BYPASS 路径中仍不执行在线 bilinear 插值；若以后输入文件没有预先重网格，需要另外实现在线插值。

### 错误和数据质量检查

现在会检查与 HDM 有关的所有 NetCDF 操作：

- 文件打开/关闭；
- dimension 和 variable 查询；
- longitude、latitude、year 和 hdm 读取；
- HDM variable rank。

任何 NetCDF 或 MPI 错误都会立即 `endrun`，并给出具体操作和 NetCDF 错误字符串，不再静默继续使用零数组。

输入文件在非陆地位置允许含 NaN。完成空间索引后，每个实际 ELM gridcell 选中的两个 HDM 值必须：

- 不是 NaN；
- 不小于零。

这样可以容许海洋缺测值，同时阻止无效陆地值进入 `FireMod`。

## 编译与运行验证

### 最终增量编译

- Slurm Job ID：`403245`
- 资源：1 node，32 CPU，120 GB，30 min limit
- 状态：`COMPLETED`
- ExitCode：`0:0`
- Elapsed：48 s
- 结果：`MODEL BUILD HAS FINISHED SUCCESSFULLY`

构建使用的脚本：

```text
/projects/hpcl-cli185/proj-shared/zw5/E3SM/jobs/build_hdm_fix.slurm
```

### 真实 1850–2100 文件 smoke test

独立测试 case：

```text
/projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260717_hdm_highres_smoke
```

运行目录：

```text
/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_hdm_highres_smoke/run
```

配置：1850-01-01 启动、2048 MPI tasks、16 nodes、1 个模型步长、history 仅包含 HDM。

- Slurm Job ID：`403250`
- 状态：`COMPLETED`
- ExitCode：`0:0`
- Elapsed：2 min 01 s
- E3SM model step：1 min 57 s

land 日志确认：

```text
Successfully initialized the land model
HDM input: 504 x 324 grid, 251 records; using records 1 and 2.
```

history 中 HDM 的 NCO 统计（Job `403305`）为：

| 时间 | HDM_min | HDM_avg | HDM_max |
|---|---:|---:|---:|
| 1850-01-01 00:00 | 0.004666142 | 5.128139 | 39.53164 |
| 1850-01-01 01:00 | 0.004666142 | 5.128139 | 39.53164 |

因此 HDM 已正确进入 ELM history，不再全零。

### 超过输入最大年份的隔离测试

直接把完整模型启动到 2101 年会在 HDM 调用前受到其他 forcing/restart 时间设置影响，因此采用隔离测试：从真实文件提取最后一条 2100 HDM 空间场，并把测试文件的唯一 `year` 标记为 1849；模型仍从已验证可运行的 1850 年启动。此时模型年份严格大于测试文件最大年份。

测试文件仅用于验证，不得用于生产：

```text
/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_hdm_highres_smoke/run/hdm_last_record_year1849_test.nc
```

- Slurm Job ID：`403310`
- 状态：`COMPLETED`
- ExitCode：`0:0`
- Elapsed：2 min 19 s

land 日志确认：

```text
HDM input: 504 x 324 grid, 1 records; using records 1 and 1.
```

这验证了“模型年份超过输入最大年份时固定使用最后记录”的运行时分支。

测试结束后，smoke case 已恢复为真实 1850–2100 HDM 文件和 `RUN_STARTDATE=1850-01-01`。

## Pathfinder 运行环境注意事项

当前 Pathfinder CIME machine 配置在 clean Slurm 环境中没有完整加入 Parallel-NetCDF、NetCDF-C/Fortran 和 HDF5 的运行时 library path。使用 `sbatch --export=NONE` 直接运行现有 `.case.run` 时，可能出现：

```text
libpnetcdf.so.4: cannot open shared object file
```

本次 smoke test 显式传入了构建时的运行时库目录。正式生产作业应通过可复现的 module/CIME machine 配置加载这些库，而不是依赖登录 shell 的隐式环境。不要只导出 `LD_LIBRARY_PATH` 而丢失 `HOME`；OpenMPI 初始化需要基本用户环境变量。

## 科学解释限制

该代码修复保证以后能够正确读取 HDM，但不会修复已经完成的零-HDM spinup 状态。当前 20TR 的 `finidat` 来自此前 HDM 为零的 normal spinup，因此：

- 从 20TR 开始启用正确 HDM 在技术上可以运行；
- 但火灾、植被和碳库初态仍与正确 HDM forcing 不完全一致。

最严格的方案仍是用修复后的代码重新进行 AD spinup 和 normal spinup。若成本不允许，至少应先做固定 1850 forcing 的调整模拟，检查碳库、植被和火灾通量收敛后，再开始 transient。

## 仓库状态

本次修改直接写入：

```text
/projects/hpcl-cli185/proj-shared/zw5/E3SM
```

修改尚未提交到 Git。仓库在本次工作前已经包含用户自己的未提交修改和未跟踪文件；本次操作没有清理、覆盖或提交这些无关内容。
