# Ndep `stream_year_last_ndep` 过期默认值导致的 post-2005 冻结

日期：2026-09-01

## 这是第三个、独立的 Ndep 问题——不要跟前两个混

到目前为止这个项目已经记录了两个不同的 Ndep 相关问题，这是第三个，机制上
和前两个都不一样：

1. **2016 年硬冻结**（`docs/PLAN.md` "Ndep — the production science case hard
   gate"）——已完成的 4km 历史 run（job 410470，2026-07-23）用的是
   **旧二进制**（早于 2026-08-14 的 `3de0e0d735`），Ndep 索引是硬编码公式
   `nindex(1) = min(max(yr-1848,2), 168)`，168 条记录对应到 1850+168-1=2017
   年封顶，导致 2017-2023 这 7 年被冻结在 2016 年的值。这是**旧代码**的行为，
   已知、已接受，是"settled condition"。
2. **pre-1850 钳制崩溃**（`HDM_Ndep_pre1850_spinup_clamp_fix_20260831.md`）——
   **新代码**（2026-08-14 年份重写之后）里，模式年早于数据起始年 1850 时，
   `nindex(1:2)` 被钳到同一个值，AD spinup 用模式年 1 起跑时触发这个分支导致
   崩溃。跟"读到了错误的年份值"无关，是"根本读不下去、直接 endrun/段错误"。
3. **本文档记录的这个**——**新代码**里，`stream_year_last_ndep` 这个
   **namelist 变量的默认值**是过期的 `2005`，不是硬编码在 Fortran 里，是
   `namelist_defaults_elm.xml`（或等效的 use_case 解析）给出的一个字面
   过时的值。跟问题1不同：这不是旧二进制的行为，当前（已修复过 pre-1850
   崩溃的）代码一样会踩这个坑，只要没有在 `user_nl_elm` 里显式覆盖。跟问题2
   也不同：不会崩溃，模式正常运行、正常输出，只是 2005 年之后每一年读到的
   都是被钳在 2005 年那条记录的**同一份**Ndep 值——安静地把年际变化抹掉，
   没有任何报错或日志异常提示这件事发生了。

## 发现过程

排查 `20260901_seus_halfdeg_transient`（0.5°，真实历史日历 1850-2023）时，
用户直接贴出了这个 case 已跑完的 `lnd_in` 内容，注意到：

```text
model_year_align_ndep = 1850
ndepmapalgo = 'bilinear'
stream_fldfilename_ndep = '.../fndep_elm_cbgc_exp_simyr1849-2101_1.9x2.5_ssp245_c240903.nc'
stream_year_first_ndep = 1850
stream_year_last_ndep = 2005
```

文件本身（`stream_fldfilename_ndep`）覆盖 1849-2101，物理上完全有
2005 年之后的数据；但 `stream_year_last_ndep=2005` 这个**读取窗口**参数
从未被 `user_nl_elm` 显式覆盖过，一直是某个 use_case/namelist 默认值，
导致 2005-2023 这 19 年被钳制读取同一条 2005 年记录。

## 影响范围核查

逐个 case 直接 `grep` 各自已构建的 `Buildconf/elmconf/lnd_in`
（或 `run/lnd_in`）：

| Case | `stream_fldfilename_ndep` | `stream_year_last_ndep` | 受影响？ |
|---|---|---|---|
| `20260831_seus_halfdeg_ad_spinup` | 同一份 ssp245 全球 1.9x2.5 文件 | 1850 | 否——虚构日历模式年始终 < 1850，从未接近这个边界，这个变量的值对它无意义 |
| `20260901_seus_halfdeg_final_spinup` | 同上 | 1850 | 否，理由同上 |
| `20260901_seus_halfdeg_transient`（修复前） | 同上 | 2005 | **是**——2005-2023 共 19 年冻结 |
| `20260901_seus_halfdeg_transient`（修复后，2026-09-01） | 同上 | **2101**（显式加进 `user_nl_elm`） | 已修复，见下 |
| `20260901_seus_halfdeg_future_ssp119`（构建中，未提交） | 已改为 ssp119 专属文件 | **2101**（显式加进 `user_nl_elm`） | 建 case 时就直接按正确值配置，未曾受影响 |
| `20260723_Southeast_hires_s7P_s8hdmfix_harvfix_ICB20TRCNPRDCTCBC`（4km 参照 historical/transient case，本项目全程用作 0.5° 配置的参照） | 同上 | **2005** | **是，且从未修复过** |

`stream_year_first_popdens=1850`/`stream_year_last_popdens=2100`、
`pdep`（固定单年 2000）、`lightng`（固定单年 0001）三个流都检查过，没有
类似的过期窗口问题——**这个 bug 目前只确认存在于 `_ndep` 这一个流**。

## 0.5° transient 的修复（已执行）

`20260901_seus_halfdeg_transient` 当时已经用 REST_N=29 跑完到 1995-01-01
这个 restart 点（1995 早于 2005，不受影响）。没有整个重跑 174 年，而是：

1. `scancel` 掉正在跑的 job（504564，此时已经算到 ~2003 年，中间已经产生了
   被污染的 1995-2003 输出）
2. 清理 RUNDIR：删除 1995-02 到 2003-02 之间会被重新生成的 monthly
   history（h0+h1），顺带删掉了几个更早的、REST_N=44 时代遗留的边界文件
   （1894/1938/1982 各一套 restart+history，跟这次修复无关，是旧周期的
   debris）
3. `xmlchange CONTINUE_RUN=TRUE`、`STOP_N` 从 174 改成 **29**（1995 到
   2024 还剩 29 年——`CONTINUE_RUN=TRUE` 续跑时 `STOP_N` 是"这一段还要跑
   多少"，不是"总共减去已跑的"，这一点被 AD/final spinup 自己的
   RESUBMIT 段验证过：每段都用同一个固定 `STOP_N`）
4. `user_nl_elm` 里显式加两行：
   ```text
   stream_year_first_ndep = 1850
   stream_year_last_ndep = 2101
   ```
5. `./preview_namelists` 确认 `Buildconf/elmconf/lnd_in` 里
   `stream_year_last_ndep` 确实变成 2101，`BUILD_COMPLETE`/`EXEROOT`
   未受影响（没跑 `case.setup --reset`，不需要重新编译）
6. `case.submit`，job **504823**（2026-09-01 提交，从 1995-01-01 restart
   续跑到 2024-01-01）

## 4km 参照 case 的决定（记录，尚未执行）

**用户决定：这个坑需要在下一次重跑 4km 参照 case（transient/historical）
时一并修掉**——到那时候要在它的 `user_nl_elm` 里显式加上
`stream_year_first_ndep=1850`、`stream_year_last_ndep=2101`（或者这份 ssp245
文件实际覆盖到的年份上限，重跑前应该再确认一次文件本身的时间范围没有变）。

**这件事本身还没有开始**。`docs/PLAN.md` 里已经记录了一个"重跑 4km 历史
case"的计划（2026-08-28 更新，主要动机是 `smoothHARV` 历史采伐场重新聚合，
不是这个 Ndep 问题；这个 stream_year_last_ndep 修复只是那次重跑该顺带做的
事，不是重跑的理由），生活在 `e3sm_run` 目录、这个仓库之外，**截至这份文档
写的时候还没有开始跑**。这份文档只是补充记录：不管那次重跑最终由什么理由
触发，**必须**同时带上这个 `stream_year_last_ndep` 修复，否则重跑完还是会
在 2005 年之后继续冻结——2026-08-28 那次 PLAN.md 更新本身并没有意识到这个
具体的 namelist-默认值问题（那次讨论的是旧二进制 2016 冻结，跟这个是两回
事），所以不能假设"重跑到当前代码"就自动带上了这个修复，需要显式检查。
