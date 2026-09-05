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

逐变量数值比较（`cmp_nc.py`，遍历每个数值变量报 `max|A-B|`、最大相对差、
差异元素数；两边同为 NaN 视为相等）：

| 对象 | 结果 |
|---|---|
| **2024 restart（future 的初始场）** | **461 个数值变量逐比特一致** |
| 2023 全年 h1 | 115 个变量逐比特一致 |
| 2023 全年 h0 | 560/561 一致，唯一差异 `SEEDC_GRC` |

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

**这是 ELM 既有的 restart 完备性缺口，与缺陷 A/B 的修复无关**（两个修复只
动气象驱动的时间索引）。不影响结论的三条依据：

1. 底层状态 `seedc` 三份 restart 全为零且完全一致，最大差 0
2. 2024 restart 逐比特一致，说明它不回馈进保存状态
3. 量级 0.36 gC/m^2，约为典型碳库（10^3-10^4 gC/m^2）的 0.004%；
   且对一个 "pool" 取负值，本身说明它是动态地表覆盖的记账残差而非物理存量

**对 future 的直接含义**：既然它不在 restart 里，就不可能进入 future 的
初始条件。

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

测试 1、2a、2b 全部通过。A3（从 2020 重跑历史尾段）的前置条件满足。

仍未解除的三条已知限制见 `fc2a4f2be1` 提交说明：历史配置从 2024 初始化
未受保护、跨终点后索引配对被压平、初始化路径不经过守卫。
