# cpl_bypass 时间索引修复的验证记录

日期：2026-09-05

## 目的

记录缺陷 A（`3cf28db19f`）与缺陷 B（`fc2a4f2be1`）两个修复的验证过程，
**包含可复现所需的全部材料**：实际使用的诊断补丁、exe 校验值、编译 flag、
作业号。缺陷本身的分析见
[`cpl_bypass_restart_tindex_overrun_20260904.md`](cpl_bypass_restart_tindex_overrun_20260904.md)。

只写"加了两段打印"不足以复现，所以补丁全文附在下面。

---

## 验证矩阵

| # | 验证内容 | 作业 | 状态 |
|---|---|---|---|
| A-1 | 缺陷 A 治好必崩的 case（1937 重启，`mod==43`） | 511368 | ✅ |
| A-2 | 缺陷 A 不破坏原本正常的年份（1908 重启） | 511467 | ✅ |
| A-3 | 连续积分穿过 1937（因果机制） | 511164 | ✅ 补充观察 |
| B-1 | 缺陷 B 修复末端越界（0.5° 1995→2024 完整 29 年） | 511687 | ✅ |
| **1** | **危险年份重启 `mod==42`（1980），实测索引对** | **511754** | ✅ |
| **2a** | **连续 vs 中途重启一致性（0.5°）** | **511752 + 511762** | ✅ |
| **2b** | **future 衔接检查（用生成的 2024 存档启动 future 配置）** | **511773 + 511775** | ✅ |

---

## 测试 1：危险年份重启（`mod==42`）

### 为什么单独测这条路径

缺陷 A 的危险年份分两类：

- `mod(yr-1850,44) == 43`（1893/1937/1981）：`tindex(1)` 本身越界，修复后
  外层 `mod` 直接消除
- `mod(yr-1850,44) == 42`（1892/1936/1980）：`tindex(1) = 128480` 合法，但
  `tindex(2) = 128481` 越界

第二类修复后走的是 `mod(44,44)=0` → `tindex(1)=0` → 第 601 行先算出
`tindex(2)=1` → 第 602 行的 `tindex==0` 特判再把 `tindex(1)` 设为
`timelen_spinup`。**配对成功依赖那个特判，而不是一个真正的边界检查**
（见 `fc2a4f2be1` 提交说明的已知限制第 3 条），因此值得显式验证实测值。

### 配置

```
case      /projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260904_dbg_restart1937
分辨率    4km SEUS，NTASKS=512（4 节点）
重启点    1980-01-01（从 4km 生产 RUNDIR 借用，见下"重启借用"）
STOP      ndays / 1        REST_OPTION=never
DEBUG     TRUE
共享树    fc2a4f2be1（含缺陷 A + B）
```

### 实际使用的诊断补丁

相对共享树 `components/elm/src/cpl/lnd_import_export.F90` 的差异，
放在 case 的 `SourceMods/src.elm/`：

```diff
@@ -603,6 +603,12 @@
               atm2lnd_vars%tindex(g,v,1) = atm2lnd_vars%timelen(v)
               if (yr .le. atm2lnd_vars%endyear_met_spinup) atm2lnd_vars%tindex(g,v,1) = atm2lnd_vars%timelen_spinup(v)
              end if
+            if (masterproc .and. g .eq. bounds%begg .and. v .eq. 1) then
+              write(iulog,*) 'TINDEX_INIT yr=', yr, ' mon=', mon, ' day=', day, &
+                   ' t1=', atm2lnd_vars%tindex(g,v,1), ' t2=', atm2lnd_vars%tindex(g,v,2), &
+                   ' timelen=', atm2lnd_vars%timelen(v), &
+                   ' timelen_spinup=', atm2lnd_vars%timelen_spinup(v)
+            end if
           end do    !end variable loop
         else
           do v=1,met_nvars
@@ -661,6 +667,10 @@
                    atm2lnd_vars%tindex(g,v,2) = atm2lnd_vars%timelen(v)
             end if

+            if (masterproc .and. g .eq. bounds%begg .and. v .eq. 1) then
+              write(iulog,*) 'TINDEX_STEP nstep=', nstep, &
+                   ' t1=', atm2lnd_vars%tindex(g,v,1), ' t2=', atm2lnd_vars%tindex(g,v,2)
+            end if
             !if (yr .gt. atm2lnd_vars%startyear_met) then
```

**纯观测，无计算逻辑改动。** 守卫用 `masterproc .and. g==bounds%begg .and. v==1`
把输出限制在一个 task 的一个格点一个变量——`tindex` 的公式不含 `g`，所以
一个格点即可代表全部。`masterproc`、`iulog` 由第 44 行、第 12 行导入，
`nstep`、`bounds` 在作用域内（第 611 行已在用 `nstep`）。

### 编译与运行记录

```
编译作业    511753   COMPLETED 0:0   00:01:51   (-p serial -N1 -c32)
运行作业    511754   COMPLETED 0:0   00:12:26   (4 节点, --mem=200g)
exe md5     4d3cf79e1352e3387f2cfcb731b6cdf8
exe 大小    78 MB
exe 时间    2026-09-05 00:06:40
实际 flag   -DCPL_BYPASS   -fcheck=bounds,pointer   （无 -ffpe-trap）
```

`-ffpe-trap` 必须去掉，否则在 OpenMPI 的 `mpi_init` 里就 SIGFPE，
到不了模式代码（见 `pathfinder/elm_setup_and_run_guide.md` §18.1）。

### 结果

```
TINDEX_INIT yr=1980 mon=1 day=1  t1=128480  t2=1  timelen=128480  timelen_spinup=128480
```

实测索引对为 **`(128480, 1)`**，与预期一致。

后续递增（23 条，覆盖完整一天）：

```
nstep=1138802..804   t1=1  t2=2      ← 3 小时驱动 / 1 小时时间步，每条记录用满 3 步
nstep=1138805..807   t1=2  t2=3
...
nstep=1138823..824   t1=8  t2=9
```

- 单调推进，**配对偏移 `t2-t1` 全程恒为 1，未被压平**
- 24 个时间步消耗 8 条记录（24 小时 ÷ 3 小时），自洽
- 第一次递增的行为正确：`(128480,1)` 各加 1 得 `(128481,2)`，
  因 `yr=1980 <= startyear_met=1980` 触发第一分支 clamp，`t1` 归 1，得 `(1,2)`

错误检查：越界 0、Fortran runtime error 0、SIGSEGV/SIGFPE 0、ENDRUN 0、
碳平衡错误 0。模式时间 `1980-01-01_01:00` → `1980-01-02_00:00`。

### 一个观察日志时的教训

运行前 11 分钟 `lnd.log` 停在 2700 行不动，一度像挂住。实际是**正常的**：
`lnd_import` 由运行循环（`lnd_run_mct` → `component_run` → `cime_run`）调用，
**不在 init 里**，所以诊断打印要等第一个时间步才出现。

判活应该看 CPU 占用而不是日志：

```bash
srun --jobid=<id> --overlap -N<n> -n<n> --ntasks-per-node=1 bash -c '...读 /proc/stat...'
# 实测 util 88-94%、MHz 2528-2608、e3sm RSS 98 GB/节点 → 在算，不是挂住
```

另外一个自己踩的坑：`iulog` 写的是 `lnd.log`，第一次检查只 grep 了
`e3sm.log`，误以为 `TINDEX_STEP` 一条都没有。

---

## 重启借用：四个必须同时满足的条件

从别的 case 借 restart 做 debug，缺任何一条都会报一个看不出关联的错：

1. **`-ffpe-trap` 必须从 `cmake_macros/gnu.cmake` 去掉**，否则 `mpi_init`
   里 SIGFPE（backtrace 指向 `cime_comp_mod.F90:765`）
2. **RUNDIR 里新旧两套文件名都要在**：新名给 CIME 的提交校验和 rpointer；
   旧名是因为 `elm.r` 内部的 `locfnh`/`locfnhr` 记录了自己的 `h0`/`h1`/`rh0`/`rh1` 文件名
3. **case 名写在 `cpl.r` 内部的 `seq_infodata_case_name`**，必须复制该文件
   并改写该变量，否则驱动的 `seq_infodata_Check` 拒绝
4. **`case.submit` 曾把 `env_run.xml` 截断成 61 字节**（表现为
   `case_run.py:478` 的 `data_assimilation_cycles` TypeError），提交前留份备份

另外 `h0`/`h1` 必须**复制**而不是符号链接——ELM 会以写方式重新打开它们继续
累积，符号链接会污染被借用 case 的生产文件。

---

## 测试 2：重启一致性与 future 衔接

两个目的必须分清：

- **一致性比较**：两边使用同一套历史驱动，在终点之前的**零点**中断
  （初始化代码第 597 行注释明确 `currently MUST begin at hour 0`）
- **future 衔接检查**：用生成的 2024 存档启动 future 配置。这是衔接检查，
  **不与继续使用历史驱动的结果比较**——历史配置从 2024 初始化仍未受保护
  （`fc2a4f2be1` 已知限制第 1 条）

设计：0.5° case `20260904_dbg_halfdeg_2023end`，`REST_OPTION=nyears REST_N=1`

- 运行 A（511752）：1995→2024 连续，逐年写 restart
- 运行 B：从 A 生成的 **2023-01-01** checkpoint 恢复，跑 1 年到 2024
- 比较：2024 restart 与 2023 全年 h0/h1，**逐变量数值比对**，
  不能只看 NaN/Inf 计数或作业退出码

**启动 B 的前置条件**：A 成功结束 → 基准复制完成 → 校验通过。
仅仅启动了自动保存程序不等于基准已保住。基准清单必须包含 **A 的 2023 年
history 输出和运行日志**，因为 B 会重新生成同名文件并覆盖它们。

### 结果

**测试 2a：连续 vs 中途重启一致性 —— 通过**

```
运行A  511752  COMPLETED 0:0  54:55   1995->2024 连续，逐年写 restart
运行B  511762  COMPLETED 0:0  02:48   从 A 的 2023-01-01 checkpoint 恢复，跑 1 年
       同一 exe（md5 9dfcf9dfd3ef4c42fae0f32d520ade4f）、571 任务、同一套输入
```

基准保存前做了**来源校验**（文件计数与 md5 只能证明复制完整，不能证明来源）：
2023 h0/h1 的 mtime 为 00:56:10/11，落在运行 A 的时间窗
`[00:01:20, 00:56:15]` 内，排除了误存前一次运行（511687，前晚 19:48 结束）
遗留文件的可能。随后 10 个 `.nc` 逐一 md5 与源一致。

比较用 `cmp_nc_strict.py`（本 case 目录下）。第一版 `cmp_nc.py` 不合验收
标准，已弃用——它把所有值统一转成 `float64`（不是严格逐比特）、读取异常被
静默归入"非数值跳过"、缺失变量只打印提示不影响判定、发现差异仍以 0 退出。
严格版：读**原始存储值**（关闭自动掩码与 scale/offset）、比对 dtype/维度名/
形状/原始字节、**任何读不了的变量算失败**、只在一侧出现的变量算失败、
有未解释差异则**非零退出**，外层脚本传播该退出码。已记录并调查过的差异用
`--expect` 显式豁免，仍会打印，不隐藏。

严格重比以**归档作业**执行，可追溯复现：

```
作业        511791   COMPLETED 0:0   4 秒
脚本        cmp_runAB_strict.sbatch （取代旧的 cmp_runAB.sbatch，后者调用
            旧 cmp_nc.py 且不传播退出码）
归档输出    <case>/cmp_runAB_strict.511791.out
环境        python 3.9.25  netCDF4 1.7.2  numpy 2.0.2
```

结果（**逐文件列出，不合并计数**）：

| 对象 | 变量数 | 逐比特一致 | 已记录豁免 | 未解释 | 判定 |
|---|---|---|---|---|---|
| 2024 `elm.r` | 464 | 464 | 0 | 0 | PASS |
| 2024 `cpl.r` | 15 | 15 | 0 | 0 | PASS |
| 2024 `elm.rh0` | 23 | 23 | 0 | 0 | PASS |
| 2024 `elm.rh1` | 23 | 23 | 0 | 0 | PASS |
| 2023 `h1` | 117 | 116 | 1（`time_written`） | 0 | PASS |
| 2023 `h0` | 563 共有 | 561 | 10 | 0 | PASS |

**`464` 是 2024 `elm.r` 单个文件的变量数，不是 restart 四件套的总数。**
四个 restart 文件合计 525 个变量，全部零豁免逐比特一致。（第一版工具只比了
`elm.r`，且把 3 个字符型变量当作"非数值"跳过，报成"461 个数值变量"。）

### 文件级 sha256 不能用作 NetCDF 等价性判据

同一次比较中：

```
cpl.r   85c39ce0… == 85c39ce0…     文件字节相同
elm.r   7529622b… != 2b273771…     文件字节不同
rh0     68011133… != 74af090c…     文件字节不同
rh1     33dbfd57… != de5fe66f…     文件字节不同
```

但这三个文件的**每一个变量都逐比特一致**。差异在 NetCDF 头部元数据里
（创建时戳、内部布局/填充）。**用 sha256 判等会得出"不同"的错误结论**，
必须逐变量比对。

### 工具本身的有效性对照

同一份归档输出里带两个对照，防止"恒返回通过"：

```
对照1  同一文件自比            -> PASS（exit 0）
对照2  2023 vs 2024 restart 自比 -> FAIL（exit 1，242 项未解释）
       例：xsmrpool max|A-B|=195.654  tsai_z 7.35059  wf 0.423866
```

对照 2 证明工具确实能检出真实差异。

`time_written` 是每条 history 记录**写盘时的墙钟时间**（A: 00:54:26/33/44，
B: 00:59:12/19/26，对应两次运行的写盘时刻；同文件的 `date_written` 两边同为
`09/05/26`）。不是模式数据。第一版工具把它静默跳过了，严格版才暴露出来。

#### 唯一差异 `SEEDC_GRC` 的解释（与本次修复无关）

```
运行A 各年最小值  1995 -0.0173 -> 2000 -0.0714 -> 2010 -0.239
                 -> 2020 -0.356 -> 2022 -0.360
运行B（2023）     恒为 0

restart 中的 seed 变量：seedc/seedn/seedp，维度全为 ('column',)
restart 中含 grc/gridcell 的变量：无
```

`SEEDC_GRC`（`pool for seeding new PFTs via dynamic landcover`，gC/m^2）
背后的**格点级**累加量根本不在 restart 里——restart 只存 column 级的
`seedc`，一个格点级变量都没有。重启时它从零重新开始，运行 B 显示的正是
这个；运行 A 那个值是自 1995 年起 28 年的缓慢累积残余。

源码侧佐证：它对应 `grc_cs%seedc`，初始化为零，随动态植被变化累计更新。
**这是 ELM 既有的 restart 完备性缺口，与缺陷 A/B 的修复无关**（两个修复只
动气象驱动的时间索引）。

**本次验收的准确表述**：*保存的数值状态一致（2024 restart 464/464 逐比特
一致，零豁免），history 中存在 `SEEDC_GRC` 差异。* 支撑：

1. 底层状态 `seedc` 三份 restart 全为零且完全一致，最大差 0
2. 2024 restart 零豁免逐比特一致，说明在**本实验的配置下**它未回馈进保存状态
3. 量级 0.36 gC/m^2，约为典型碳库（10^3-10^4 gC/m^2）的 0.004%

**两条不能由本次实验推出的结论，明确不主张**：

- 不能推广成"`SEEDC_GRC` 在任何配置下都不影响状态"。本次只测了一个
  0.5° 配置、一个重启点。动态地表覆盖活跃的配置未测。
- **不能因为它取负值就断定它没有物理意义。** 之前的记录里用过这个论证，
  是无效的——符号推不出语义。此处撤回。

**对 future 的直接含义（限于本次配置）**：它不在 restart 里，所以不会
通过 restart 进入 future 的初始条件。

另有 8 个变量只出现在运行 B 的 h0 中：`BSW`、`DZLAKE`、`DZSOI`、`HKSAT`、
`SUCSAT`、`WATSAT`、`ZLAKE`、`ZSOI`——全是时不变的土壤/湖泊参数，ELM 只写进
一次运行的**首个** history 文件。运行 A 写进了 1995 那个，运行 B 的首个就是
2023。同样不是物理差异。

**测试 2b：future 衔接检查 —— 通过**

case `20260905_dbg_halfdeg_futhandoff`（克隆自
`20260901_seus_halfdeg_future_ssp245`，未用 `--keepexe`），
`finidat` 指向运行 B 生成的 2024 存档。

```
511773  COMPLETED 0:0  31 秒   2 天 97 步（半小时步长）
511775  COMPLETED 0:0  22 秒   加诊断重跑 1 天，实测索引

越界 / runtime / SIGSEGV / ENDRUN / 平衡错误   全部 0（bounds checking 开启）
initial data = .../20260904_dbg_halfdeg_2023end...elm.r.2024-01-01-00000.nc
metdata_type = 'era5-daymet-fut-halfdeg'   （future 驱动，非历史驱动）
HDM 175/176   Ndep 176/177                （2024 的正确索引）
```

衔接是通过 **`finidat`**（`RUN_TYPE=startup`，`CONTINUE_RUN=FALSE`）完成的，
不是 `CONTINUE_RUN` + rpointer。因此不涉及"重启借用"的四个坑。

实测气象索引（补验，不接受推导）：

```
TINDEX_INIT yr=2024 mon=1 day=1  t1=2920  t2=2921
                                 timelen=227760  timelen_spinup=2920
递增 (2920,2921) -> (2921,2922) -> ... -> (2928,2929)，偏移恒为 1
一天 8 次推进（24h / 3h），47 条记录 = 48 个半小时步减去初始化那次
```

与推导一致：`use_daymet_fut` 下 `startyear_met=2023`，`yr=2024 > 2023` 走
线性分支得 `(2024-2023)*2920 = 2920`；`timelen=227760` = 78 年 × 2920
（2023 dummy + 2024-2100）。

`era5-daymet-fut-halfdeg` 会**同时**设 `use_daymet_fut`（源码第 272-286 行，
有注释说明是为继承 2023-dummy / 2024-2100 的年份范围，且必须排在
`daymet-fut` 之前判断，因为字符串包含它），所以 future 配置不受缺陷 A 影响。

### 验收结论

测试 1、2a、2b 全部通过（严格工具，退出码传播）。A3 的前置条件满足。

---

## A3 执行前必须保存的范围

4km 的 history 是**每年 h0 = 12 GB、h1 = 6.9 GB**。从 2020 回退重跑会
重新生成 2020-2023 的 history，并**重新以写方式打开** 2020 checkpoint 的
`locfnh` 所指的 2019-02-01 那对文件（restart 在 `YYYY-01-01`，其 `locfnh`
指向 `(YYYY-1)-02-01`，已由 1980→1979-02、1908→1907-02 两例验证）。

只备份"2024 restart 四件套"不够——那样事后无法区分**"修复造成的变化"**和
**"原结果被覆盖后无从比较"**。

| 类别 | 内容 | 约计 |
|---|---|---|
| 原 2024 restart | `elm.r`(14G) + `rh0` + `rh1` + `cpl.r` | 14 GB |
| 将被覆盖的 history | 2020/2021/2022/2023 各 h0+h1 | 76 GB |
| 2020 checkpoint 引用的可写 history | 2019-02-01 h0+h1 | 19 GB |
| 指针 | `rpointer.lnd`、`rpointer.drv` | - |
| 配置 | `env_*.xml`、`user_nl_*`、`lnd_in`、`drv_in` | - |
| 原 exe 身份 | `e3sm.exe`(25MB) + md5 + `e3sm.bldlog.*` | 25 MB |
| 原运行日志 | `lnd.log` / `e3sm.log` / `cpl.log` | - |

合计约 110 GB。

> **清单必须由实际引用确定，不能按规律外推。** 上表的 2019-02 是依 1980、
> 1908 两例的规律推的，**执行时必须直接读 2020 checkpoint 的 `locfnh`/
> `locfnhr`** 取实际文件名。规律只作佐证——万一那次 restart 指向别处，
> 按规律推就会漏备份，而漏掉的正是会被改写的那份。

原 exe 必须留**副本**而不只是 md5：A3 要重建 exe 才能拿到修复，重建会覆盖
`EXEROOT/e3sm.exe`；留副本才能在结果有差异时区分"代码改动"与"其他因素"。

### 来源校验必须按文件类别分开

测试 2a 用的是"mtime 落在运行时间窗内"这一条，但**不能对所有文件套同一个
门槛**：

| 类别 | 来源校验方式 |
|---|---|
| 生产新写的 history / restart | mtime 落在生产作业 511164 的时间窗内 |
| **原 exe** | **md5 + 编译日志比对。** 它编译于 2026-09-02 16:54，**本来就早于
生产起跑（09-04 11:42）**，套 mtime 门槛必然误判为"疑为遗留" |
| 配置 / 指针 | 与 case 目录当前内容逐字节比对 |

### A3 的验收标准与测试 2a 不同

**A3 的新旧 2024 restart 允许出现差异，而且预期会有。** 修复改变的正是 2023
年最后约 3 小时的驱动，那必然传播到最终状态。

- 测试 2a 的"必须逐比特一致"标准**只适用于**同一份代码下的"连续 vs 重启"比较
- A3 是"修复前 vs 修复后"，属于不同代码，**照搬逐比特标准是错的**
- 届时要**量化并解释**：哪些变量变了、量级多大、空间分布是否与"仅末端 3 小时
  驱动改变"相符、是否存在无法由该机制解释的变化

用 `cmp_nc_strict.py` 输出差异清单作为量化依据，但判定由人做，不是看它的
退出码。

### A3 操作要点

- 只 `./case.build`，**绝不 `case.setup --reset`**（会抹掉 `-DCPL_BYPASS`
  并还原 `-ffpe-trap`）
- `rpointer.lnd`/`rpointer.drv` 改指 2020；`STOP_N` 116 -> 4
- 提交前备份 `env_run.xml`（曾被 `case.submit` 截断成 61 字节）
- 2020 不是缺陷 A 的危险年份：`mod(2020-1850,44)=38`，`38+2=40 < 44`，
  修复前后同值，所以 A3 的起点本身不受修复影响
- 跑完用 `cmp_nc_strict.py` 逐变量比较新旧 2024 restart，**四个文件都要比**
  （`elm.r`/`cpl.r`/`rh0`/`rh1`），并按上一节的标准解释差异而非要求一致

仍未解除的三条已知限制见 `fc2a4f2be1` 提交说明：历史配置从 2024 初始化
未受保护、跨终点后索引配对被压平、初始化路径不经过守卫。
