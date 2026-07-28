# HDM 修复版 normal spinup 与 historical case 设置记录

日期：2026-07-17

## 目标与结论

本次新建两个 case，不覆盖 2026-07-12 的三个旧 case，也不重新运行 AD spinup。
新的 normal spinup 从旧 AD spinup 的 `0201-01-01` ELM restart 开始，使用修复后的 ELM executable 和真实的 504×324、1850–2100 HDM 文件。normal spinup 跑 440 个模型年，预计在 `0441-01-01` 停止；随后 historical case 从 1850-01-01 启动，跑完 1850–2023 年。

本次只完成 case 配置、namelist 生成、输入检查与提交脚本准备，没有提交 Slurm 作业。

## Case 路径

Normal spinup：

`/projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260717_Southeast_hires_s7P_s8hdmfix_ICB1850CNPRDCTCBC`

Historical：

`/projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260717_Southeast_hires_s7P_s8hdmfix_ICB20TRCNPRDCTCBC`

对应的新运行目录分别为：

- `/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_Southeast_hires_s7P_s8hdmfix_ICB1850CNPRDCTCBC/run`
- `/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_Southeast_hires_s7P_s8hdmfix_ICB20TRCNPRDCTCBC/run`

## 共用的修复版 executable 与 HDM

两个 case 都复用已经编译和完成 HDM runtime smoke test 的 executable：

`/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup/bld/e3sm.exe`

该文件的核对时间戳为 2026-07-17 14:06，大小约 26 MB。

HDM 文件：

`/projects/hpcl-cli185/proj-shared/zw5/ELM_makeSurfdata/Make_surface_data/s8_update_hdm/elmforc.Li_hdm_1_24x1_24_bilinear_SEUS_simyr1850-2100.nc`

NetCDF 头部核对结果：`lon=504`、`lat=324`、`time=251`；`year(1)=1850`，`year(251)=2100`。

## Normal spinup 设置

- 源 case：`20260712_Southeast_hires_s7P_s8hdm_ICB1850CNPRDCTCBC`
- `RUN_TYPE=startup`
- `RUN_STARTDATE=0001-01-01`
- `STOP_OPTION=nyears`
- `STOP_N=440`
- `REST_OPTION=nyears`
- `REST_N=44`
- `CONTINUE_RUN=FALSE`
- `RESUBMIT=0`
- `spinup_state=0`
- ELM history：每 20 个 noleap 年写一次，每个文件一个时间点
- MPI 布局：18 nodes、2304 tasks、每节点 128 tasks、1 CPU/task

初始 restart：

`/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup/run/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup.elm.r.0201-01-01-00000.nc`

由于 normal spinup 的模型年份为 0001–0440，修复后的 HDM 读取代码对 `yr < 1850` 强制使用记录 1。`user_nl_elm` 同时显式设置：

```text
stream_year_first_popdens = 1850
stream_year_last_popdens = 1850
```

因此 normal spinup 全程固定使用 1850 HDM。440 年结束时，historical 所需的预计 restart 是：

`/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_Southeast_hires_s7P_s8hdmfix_ICB1850CNPRDCTCBC/run/20260717_Southeast_hires_s7P_s8hdmfix_ICB1850CNPRDCTCBC.elm.r.0441-01-01-00000.nc`

## Historical 设置

- 源 case：`20260712_Southeast_hires_s7P_s8hdm_ICB20TRCNPRDCTCBC`
- `RUN_TYPE=startup`
- `RUN_STARTDATE=1850-01-01`
- `STOP_OPTION=nyears`
- `STOP_N=174`，即模拟 1850–2023，停止时间为 2024-01-01
- `REST_OPTION=nyears`
- `REST_N=20`
- `CONTINUE_RUN=FALSE`
- `RESUBMIT=0`
- `spinup_state=0`
- ELM history：`hist_nhtfrq=0`、`hist_mfilt=12`、`hist_avgflag_pertape='A'`，即月平均，每个文件 12 个月
- MPI 布局：16 nodes、2048 tasks、1 CPU/task
- `stream_year_first_popdens=1850`
- `stream_year_last_popdens=2100`

Historical 的 `finidat` 已指向新 normal spinup 的 `0441` restart。该文件必须等 normal spinup 完成后才会存在，因此现在不能完整通过 historical 输入文件存在性检查，也不应提前提交 historical 作业。

Historical 仍使用原 20TR case 的 surface/domain/parameter 文件和 1850–2023 dynamic land-use 文件。HDM 年份由修复后的代码读取 NetCDF `year` 变量确定；若未来模拟年份超过 HDM 文件最大年份 2100，代码会固定使用最后一条记录，而不是固定在 2010。

## Slurm 提交方式

CIME 当前 Pathfinder batch 配置在 `case.setup` 时给出 “No queue ... falling back to defaults” 警告，而且生成的 `.case.run` 没有 account、partition、QoS、walltime 和 memory 指令。为避免 `case.submit` 选错队列，每个 case 根目录中放置了可直接由 `sbatch` 提交的 `run_condo.sh`，其结构参考旧 normal spinup case 的同名脚本。

脚本显式使用：

- account：`hpcl-cli185`
- partition：`hpcl-cli185`
- QoS：`hpcl-cli185`
- walltime：168 小时
- memory：每节点 400 GB
- `LD_LIBRARY_PATH`：与旧 `run_condo.sh` 及已成功执行 HDM runtime smoke test 的 NetCDF/HDF5/MPI 库一致

与旧脚本直接执行 `srun e3sm.exe` 不同，新脚本在计算节点内执行 CIME 的 `.case.run`。`.case.run` 会完成输入文件 staging、生成/复制 namelist，再通过 `srun` 启动同一个 `e3sm.exe`，更适合当前尚未创建的新 RUNDIR。

提交 normal spinup：

```bash
cd /projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260717_Southeast_hires_s7P_s8hdmfix_ICB1850CNPRDCTCBC
sbatch run_condo.sh
```

normal spinup 完成并确认 `0441` restart 存在后，提交 historical：

```bash
cd /projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260717_Southeast_hires_s7P_s8hdmfix_ICB20TRCNPRDCTCBC
sbatch run_condo.sh
```

`run_condo.sh` 会在计算启动前检查关键输入文件。另保留 `submit_hpcl_cli185.sh` 作为登录节点预检查包装；运行它会先检查输入，再执行 `sbatch run_condo.sh`。historical 包装脚本会在 `0441` restart 不存在或为空时退出，不会提交作业。

## 验证结果

- 两个 case 的 `case.setup --reset` 成功。
- 两个 case 的 `preview_namelists` 成功，退出码为 0。
- 两个 case 的 `BUILD_COMPLETE=TRUE`。
- 两个 case 的 `EXEROOT` 均指向修复版共享 executable。
- normal 生成的 `lnd_in` 指向旧 AD `0201` restart，并显示 HDM 年份 1850–1850。
- historical 生成的 `lnd_in` 指向新 normal `0441` restart，并显示 HDM 年份 1850–2100。
- executable、旧 AD restart、HDM、domain、surface data 和 historical land-use 文件均已确认存在且非空。

## 科学解释与注意事项

旧 AD spinup 的 HDM 实际为零，因此它的碳氮状态是在缺少正确 HDM 影响的条件下平衡得到的。从该 AD `0201` restart 开始新的 440 年 normal spinup 是一个合理的、节省成本的修复方案：正确的 1850 HDM 会在 normal spinup 的第一步开始生效，并有 440 年用于重新调整生态系统状态。

但这不等同于“整个 AD spinup 都使用正确 HDM”。如果 HDM 对区域火灾、植被、土壤慢碳库或氮循环的长期影响很强，深层慢库仍可能保留旧 AD spinup 的记忆。建议至少检查 normal spinup 前几十年和最后几个输出期的 `HDM`、火灾通量、植被/土壤碳库及其趋势；只有当末期趋势足够小且没有初始化跳变持续存在时，再把 `0441` restart 用作 historical 初始状态。
