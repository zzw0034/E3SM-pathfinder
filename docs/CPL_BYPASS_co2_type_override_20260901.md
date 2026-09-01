# `CPL_BYPASS` 下 `co2_type`/`co2_ppmv` 是摆设——实际永远走 `co2_file`

日期：2026-09-01

## 结论先行

**只要编译时打开了 `CPL_BYPASS`（本项目所有生产 case 都是），`lnd_in` 里
`co2_type`/`co2_ppmv` 这两个 namelist 值就是摆设，跟实际运行时的 CO2 强迫
完全没关系。** 不管这两个值写的是 `constant`/`379.0` 还是 `diagnostic`，
模式实际读取的都是 `co2_file` 指向的文件里逐年时变的真实 CO2 浓度。

## 起因

对比 `20260901_seus_halfdeg_transient`（0.5°）和 4km 参照 case
（`20260723_Southeast_hires_s7P_s8hdmfix_harvfix_ICB20TRCNPRDCTCBC`）的
resolved `lnd_in`：

```text
# 0.5° transient / future_ssp119
co2_type = 'constant'
co2_ppmv = 379.0

# 4km 参照 case
co2_type = 'diagnostic'
```

两边 `use_case` 完全一样（都是 `20thC_transient`），却解析出不同的
`co2_type`。第一反应是：0.5° transient（已完成 1850-1995，job 504823 正在
续跑 1995-2024）全程被固定在 379 ppm（约等于2005年的真实浓度），跟真实
1850-2024 CO2 从 ~285 ppm 涨到 ~420 ppm 的轨迹完全不符——这会直接偏置
CN(P) 模型的光合作用和碳分配，且**没法靠从中间 restart 点切换来局部修复**，
因为偏差从 1850 年就开始累积进土壤碳氮库和植被碳储量里了。当时差点因此建议
把正在跑的 job 504823 停掉、整个 174 年重跑。

## 验证方法：不要信 namelist，去查真实模式输出

没有直接照着 namelist 下结论去动生产 job，而是先去查这次已经跑完/正在跑的
历史输出里 `PCO2`（大气CO2分压，Pa，在 `hist_fincl2` 里）逐年到底是多少：

```python
import netCDF4 as nc, numpy as np
for yr, fn in [('1850', ...), ('1900', ...), ('1950', ...), ('1994', ...), ('1999', ...)]:
    f = nc.Dataset(fn); f.set_auto_mask(False)
    v = f.variables['PCO2'][:]
    print(yr, np.nanmean(v[np.isfinite(v)]))
```

结果：

| 年份 | PCO2 (Pa) | 换算 ppm |
|---|---|---|
| 1850 | 28.43 | ~280 |
| 1900 | 29.53 | ~291 |
| 1950 | 31.03 | ~306 |
| 1994 | 35.76 | ~353 |
| 1999 | 36.67 | ~362 |

不是常数，是一条正常的历史 CO2 上升曲线，跟真实历史记录高度吻合——直接证明
`co2_type='constant', co2_ppmv=379.0` 这个 namelist 值没有反映实际运行行为。

## 源码根因

`components/elm/src/cpl/lnd_import_export.F90`，约 1547-1591 行：

```fortran
#ifdef CPL_BYPASS
       co2_type_idx = 2
#endif

       if (co2_type_idx == 1) then
          co2_ppmv_val = co2_ppmv_prog
       else if (co2_type_idx == 2) then
#ifdef CPL_BYPASS
        !atmospheric CO2 (to be used for transient simulations only)
        if (atm2lnd_vars%loaded_bypassdata .eq. 0) then
          ierr = nf90_open(trim(co2_file), nf90_nowrite, ncid)
          ierr = nf90_inq_varid(ncid, 'CO2', varid)
          ierr = nf90_get_var(ncid, varid, atm2lnd_vars%co2_input(:,:,1:thistimelen))
          ...
        end if
        !get weights/indices for interpolation (assume values represent annual averages)
        nindex(1) = min(max(yr,1850),2100)-1764
        ...
        co2_ppmv_val = atm2lnd_vars%co2_input(1,1,nindex(1))*wt1(1) + atm2lnd_vars%co2_input(1,1,nindex(2))*wt2(1)
        ...
        co2_type_idx = 1
#else
          co2_ppmv_val = co2_ppmv_diag
#endif
       else
          co2_ppmv_val = co2_ppmv
       end if
```

`#ifdef CPL_BYPASS` 这一行**无条件**把 `co2_type_idx` 覆盖成 `2`，完全不管
namelist 里 `co2_type` 原本是什么。紧接着 `co2_type_idx==2` 分支下,又是一层
`#ifdef CPL_BYPASS`,这次直接手动 `nf90_open`/`nf90_get_var` 打开 `co2_file`
读时变数据、按年份插值——**这条路径完全绕开了 `co2_type`/`co2_ppmv` 这两个
namelist 值**，`co2_ppmv` 只在最外层 `else`（`co2_type_idx==0`，即真正的
`constant`模式）分支里才会被用到，而 CPL_BYPASS 一开始就把 `co2_type_idx`
锁死成 2，那个 `else` 分支在 CPL_BYPASS 下永远不会被走到。

这跟本项目已经记录过的 HDM（[`HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md`](HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md)）、
Ndep（[`Ndep_year_based_cpl_bypass_fix_20260814.md`](Ndep_year_based_cpl_bypass_fix_20260814.md)、
[`Ndep_stream_year_last_stale_default_20260901.md`](Ndep_stream_year_last_stale_default_20260901.md)）
是同一套架构模式：**`CPL_BYPASS` 在 `lnd_import_export.F90` 里对 HDM、Ndep、
CO2 都有各自的 `#ifdef CPL_BYPASS` 硬编码分支，直接手动读对应的 bypass 数据
文件，绕开标准的 namelist/耦合器驱动路径**——区别是 HDM/Ndep 那两个问题是
数据本身或索引钳制有 bug，这次 CO2 这个是"namelist 值本身没有 bug，只是它
根本不是实际生效的那个值"。

## `ELM_CO2_TYPE=diagnostic` 从哪来的（附带查清楚，不是这次的根因，但容易混淆）

4km 参照 case 显示 `diagnostic` 不是因为它是"对的"、我们的 case 是"错的"
——两者在 CPL_BYPASS 下**跑出来的实际行为完全一样**（都读 `co2_file`）。
`diagnostic` 只是历史遗留：查了 `20260225`→`20260723` 这条
"Southeast_hires_...ICB20TRCNPRDCTCBC" case 血缘线里每一代的 `CaseStatus`，
`20260225`/`20260427`/`20260526`/`20260527`/`20260605`/`20260712` 各自都有
一行手动 `./xmlchange ELM_CO2_TYPE=diagnostic`；`20260717`/`20260723` 没有
这一行，是因为它们是从 `20260712` `create_clone` 出来的，`env_run.xml`
整份继承，不需要重新设。进一步查 `elm-olmt` 自己的源码
（`model_ELM/main.py:828`）：`self.xmlchange('ELM_CO2_TYPE',
value='diagnostic')` 是 OLMT **每次建 case 都会自动执行**的一步——这条
血缘线的源头大概率是用 OLMT 建的。0.5° 的几个 case 是用裸
`create_newcase`（长串 compset 字符串，走 null-grid trick）建的，不经过
OLMT，落到系统级泛用默认值 `constant`/`379.0`。两边 `COMPSET` 已经直接
`diff` 过 `env_case.xml` 确认完全一致（都是
`20TR_SATM_ELM%CNPRDCTCBC_SICE_SOCN_MOSART_SGLC_SWAV_SIAC_SESP`），排除了
"compset 不一样"这个可能性。

## 结论对生产 case 的影响

- `20260901_seus_halfdeg_transient`、`20260901_seus_halfdeg_future_ssp119`：
  **不需要任何改动**。`ELM_CO2_TYPE=constant`/`CCSM_CO2_PPMV=379.0` 保持
  原样即可，CPL_BYPASS 会照常覆盖成读 `co2_file`。
- 真正决定 CO2 强迫对不对的，**只有 `co2_file` 这一个变量**——把它指向
  正确的历史/情景文件（RCP4.5 用于 historical，ssp119/245/370/585 各自
  专属文件用于对应的 future 情景）才是实际生效的修复点，这一点在
  [[elm_cpl_bypass_forcing_constraints]] 里已有记录，此文档不重复。
- 如果哪天关掉 `CPL_BYPASS` 跑一个标准耦合 case，`co2_type`/`ELM_CO2_TYPE`
  才会真正生效，届时必须显式设成 `diagnostic`（或按需要设成其他值），不能
  假设裸 CIME 会自动给出跟 OLMT 建的 case 一样的默认值。
