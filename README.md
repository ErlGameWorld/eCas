# eCas

eCas 是面向 Erlang 游戏服的数据缓存与持久化中间件：业务只操作内存（ETS），脏数据由后台进程批量落盘到 MySQL/PostgreSQL。

**一句话**：定义好 schema → `eCas:start/7` → 用 `get/create/insert/txn` 读写，不用手写 SQL。

| 我想… | 看这里 |
|--------|--------|
| 5 分钟跑起来 | [快速上手](#快速上手) |
| `create` 和 `insert` 啥区别 | [create 与 insert（必读）](#create-与-insert-必读) |
| 多 key 事务怎么写 | [txn 事务](#txn-事务) |
| 原理和流程图 | [docs/设计说明.md](docs/设计说明.md) |
| 新增数据库驱动（DbMod） | [docs/新增DbMod.md](docs/新增DbMod.md) |

本文档以当前代码为准，主要参考 `src/eCas.erl`、`src/csTabSrv.erl`、`include/eCas.hrl`、`test/cacheTabDef.erl` 和测试用例。

## 目录

- [快速上手](#快速上手)
- [create 与 insert（必读）](#create-与-insert-必读)
- [项目结构](#项目结构)
- [核心概念](#核心概念)
- [Schema 定义](#schema-定义)
- [缓存参数与推荐](#缓存参数与推荐)
- [API 参考](#api-参考)
- [txn 事务](#txn-事务)
- [设计文档](#设计文档)
- [测试与性能测试](#测试与性能测试)
- [方案优缺点](#方案优缺点)
- [待完善功能](#待完善功能)

## 快速上手

### 1. 编译项目

```bash
rebar3 compile
```

### 2. 准备 schema 与生成模块

eCas 运行期依赖两个模块：

- `dbSchemaDef`：表字段、主键、DB schema 信息。
- `cacheTabDef`：哪些表需要缓存、缓存类型、落盘策略、字段索引等。

当前测试环境中这两个模块放在 `test/` 下，由 test profile 编译进来。实际项目中通常由 `eMysql/ePgdb` 的 schema
生成器生成到业务项目代码路径中。

本仓库保留了两个便捷生成函数，主要用于测试 schema 示例：

```erlang
eCas:genM(). %% 使用 test/schema/mysql
eCas:genP(). %% 使用 test/schema/postgresql
```

### 3. 启动缓存层

当前公开启动入口是 `start/7`：

```erlang
ok = eCas:start(
eMysql,
"127.0.0.1",
3306,
"root",
"password",
"game_db",
[{wFCnt, 8}]
).
```

`PoolArgs` 中的 `wFCnt` 为数据库连接池数量；未配置时默认使用 `max(1, erlang:system_info(schedulers) - 1)`。

### 4. 使用缓存 API

```erlang
Player = #{id => 10001, account => <<"hero">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},

ok = eCas:create(players, Player),
{ok, Player1} = eCas:get(players, 10001),
ok = eCas:insert(players, 10001, Player1#{level => 2}),
ok = eCas:flushSync(players),
ok = eCas:stop().
```

`create/2,3` 表示“插入全新业务数据”，不是创建 ETS 表。普通 ETS 表的生命周期由调用方负责。

## create 与 insert（必读）

eCas 的命名和常见 ORM **相反**，第一次用务必记住：

| API | 语义 | 何时用 |
|-----|------|--------|
| `create/2,3` | **新建**一行，`DirtyState = new` | 主键尚不存在 |
| `insert/2,3` | **更新**已有行，`DirtyState = update` | 主键已存在（或 whole 表覆盖写） |

```erlang
%% 第一次写入玩家 — 用 create
ok = eCas:create(players, Player),

%% 改等级 — 用 insert（不是 create）
ok = eCas:insert(players, 10001, Player#{level => 2}).
```

多 key、需要回滚时用 `txn/3,4`，见 [txn 事务](#txn-事务)。

## 项目结构

```text
eCas/
├── include/
│   └── eCas.hrl              # #tbCache{}、缓存状态、ETS tag、缓存行宏
├── src/
│   ├── eCas.app.src          # OTP application 描述
│   ├── eCas_app.erl          # application callback，启动 supervisor
│   ├── eCas_sup.erl          # 动态 supervisor，每张缓存表一个 csTabSrv
│   ├── csTabSrv.erl             # 缓存表进程：建 ETS、加载、flush、TTL、reload、stats
│   └── eCas.erl              # 对外 API：CRUD、批量、txn、flush、reload、stats
├── docs/
│   ├── 设计说明.md           # 架构图、数据流、txn 语义
│   └── 新增DbMod.md          # 新增数据库驱动的接口契约与步骤
├── test/
│   ├── cacheTabDef.erl          # 测试用缓存配置模块
│   ├── dbSchemaDef.erl          # 测试用 DB schema 模块
│   ├── fake_db.erl              # ETS 内存 DB 测试替身
│   ├── eCas_eunit.erl           # 基础 API 测试
│   ├── eCas_txn_eunit.erl       # txn 专项测试
│   ├── csTabSrv_eunit.erl       # 落盘/reload/stats 测试
│   ├── schema_codegen_eunit.erl # schema 生成测试
│   ├── eCas_perf_eunit.erl      # 轻量性能烟测（CI）
│   ├── eCas_bench.erl           # 路径吞吐 benchmark
│   ├── tcCas.erl                # txn 锁维度性能测试（2~128 key × 2~512 进程）
│   ├── utTc.erl                 # 性能计时工具（tc/tm/tmc）
│   └── field_diff_bench.erl     # diffDirtyMask 基准对比
└── rebar.config
```

## 核心概念

### 表类型

`cacheTabDef:tableCache(Table)` 决定表如何被 eCas 处理：

| 类型     | 判定                         | 说明                                     |
|--------|----------------------------|----------------------------------------|
| 普通 ETS | `undefined`                | eCas 只提供加锁读写；数据按调用方传入的 `Data` 原样写入 ETS |
| 全量缓存   | `#tbCache{type = whole}`   | 启动时从 DB 全量加载到主 ETS，适合小表或高频访问表          |
| 热数据缓存  | `#tbCache{type = hotData}` | 启动时只加载全量 key 到 Keys ETS，数据按需回源，适合大表    |

### 缓存行格式

缓存表主 ETS 中每行统一存储为：

```erlang
{Key, Data, DirtyState, DirtyMask, AccessTime}
```

| 字段           | 说明                           |
|--------------|------------------------------|
| `Key`        | 主键值，ETS keypos 为 1           |
| `Data`       | 业务数据，通常是 map 或 record tuple  |
| `DirtyState` | `clean` / `new` / `update`，表示当前行持久化状态 |
| `DirtyMask`  | dirty 模式的字段位掩码；whole 模式固定为 0 |
| `AccessTime` | 最近访问时间，hotData + TTL 淘汰时使用   |

### 状态表

| ETS        | 格式                                               | 作用                           |
|------------|--------------------------------------------------|------------------------------|
| 主表 `Table` | `{Key, Data, DirtyState, DirtyMask, AccessTime}` | 缓存业务数据                       |
| Dirty ETS  | `{Key, DirtyType}`                               | 记录需要落盘的 key，`DirtyType = new | update | del` |
| Keys ETS   | `{Key}`                                          | hotData 专用，表示 DB/逻辑上存在该 key  |

Dirty ETS 是 flush 的扫描入口；Keys ETS 不保存脏状态，只表示 key 是否存在。

## Schema 定义

schema 定义来自 `eMysql/ePgdb` 的 schema record，缓存配置放在 `tbCache` 字段中。下面示例以当前测试 schema 的写法为准。

```erlang
-module(game_schema).

-include_lib("eMysql/include/mysqlSchema.hrl").

-export([players/0, items/0]).

players() ->
    #schema{
        repr = map,
        comment = "玩家主表，全量缓存 + 整行落盘",
        tbCache = #tbCache{
            type = whole,
            saveMode = 300000,
            saveType = whole,
            loadFun = undefined,
            flushLimit = 200
        },
        fields = [
            #schField{name = id, dbType = ?my_bigint, opts = [?my_primary_key, ?my_not_null]},
            #schField{name = account, dbType = ?my_varchar(64), opts = [?my_not_null]},
            #schField{name = level, dbType = ?my_integer, default = 1, opts = [?my_default(1)]},
            #schField{name = gold, dbType = ?my_bigint, default = 0, opts = [?my_default(0)]},
            #schField{name = profile, dbType = ?my_json, default = #{}, codec = ?codec_json},
            #schField{name = created_at, dbType = ?my_datetime}
        ]
    }.

items() ->
    #schema{
        repr = map,
        comment = "道具表，热数据缓存 + dirty 字段落盘",
        tbCache = #tbCache{
            type = hotData,
            ttl = 1800,
            saveMode = 1000,
            saveType = dirty,
            loadFun = undefined,
            flushLimit = 100
        },
        fields = [
            #schField{name = id, dbType = ?my_bigint, opts = [?my_primary_key, ?my_not_null]},
            #schField{name = player_id, dbType = ?my_bigint, opts = [?my_not_null]},
            #schField{name = item_type, dbType = ?my_varchar(32), codec = ?codec_atom},
            #schField{name = count, dbType = ?my_integer, default = 1, opts = [?my_default(1)]},
            #schField{name = attrs, dbType = ?my_json, default = #{}, codec = ?codec_json},
            #schField{name = updated_at, dbType = ?my_datetime}
        ]
    }.
```

注意：当前 `#tbCache{}` 没有 `readOnly` 字段。如果需要只读表语义，需要在业务层约束，或后续扩展 record 和 API。

## 缓存参数与推荐

`#tbCache{}` 当前字段：

| 参数           | 类型/取值           | 当前代码语义                       | 推荐                                |
|--------------|-----------------|------------------------------|-----------------------------------|
| `type`       | `whole          | hotData`                     | 缓存类型                              | 小表、配置表用 `whole`；大表、玩家私有数据用 `hotData` |
| `ttl`        | 秒，非负整数          | 只对 `hotData` 主缓存生效，`0` 表示不淘汰 | 在线玩家数据可设置 600-3600 秒              |
| `saveMode`   | 毫秒              | 直接传给 `erlang:start_timer/3`  | 高频写表建议 1000-10000；低频表可更长          |
| `saveType`   | `whole          | dirty`                       | `whole` 整行 upsert；`dirty` 只更新变化字段 | 字段少用 `whole`；字段多且局部更新多用 `dirty` |
| `loadFun`    | `undefined      | {M,F,A}`                     | 初始化加载时回调                          | 只有需要额外索引/派生数据时再用 |
| `flushLimit` | 正整数或 `infinity` | 单轮 flush 最多处理 dirty key 数    | 避免单轮过大，建议 100-1000                |
| `isOrder`    | boolean         | 主表/Keys ETS 是否使用 ordered_set | 需要顺序遍历时开启，否则保持 `false`            |

### 缓存类型选择

| 维度    | `whole`           | `hotData`                            |
|-------|-------------------|--------------------------------------|
| 启动加载  | 全量数据加载到主 ETS      | 只加载所有 key                            |
| 首次读取  | 直接查主 ETS          | 主 ETS miss 时查 Keys ETS，有 key 再 DB 回源 |
| 内存占用  | 高                 | 低，随访问增长                              |
| 遍历完整性 | 主表可完整遍历           | 需要通过 Keys ETS 才能覆盖逻辑全量               |
| 适合场景  | 配置表、小型玩家主表、热点全量数据 | 背包、邮件、日志、历史记录等大表                     |

### 落盘类型选择

| 维度   | `whole` saveType                   | `dirty` saveType                                       |
|------|------------------------------------|--------------------------------------------------------|
| 落盘方式 | 整行 `batchInsert(..., true)` upsert | `batchUpdate([{DataWithTableName, DirtyMask, Where}])` |
| 脏字段  | `DirtyMask = 0`                    | `DirtyMask` 位掩码传给 DB 模块生成 patch SQL                    |
| 新数据  | `new` 状态整行写入                       | `new` 状态 insert/upsert                                 |
| 更新数据 | 整行写入                               | 只写变化字段                                                 |
| 适合场景 | 字段少、写频低、逻辑简单                       | 字段多、局部更新频繁                                             |

## API 参考

### 启停

```erlang
start(DbMod, Host, Port, User, Password, DbName, PoolArgs) -> ok | {error, Reason}.
stop() -> ok | {error, Reason}.
```

`DbMod` 需要提供 `start/6` 和 `stop/0`。`start/7` 会启动 application、启动 DB、按批启动所有缓存表进程并等待初始化加载完成。

当前实现没有 `start/0`、`start/1`，也没有读取 `sys.config` 自动启动 DB 的入口。

### 基础读写

```erlang
get(Table, Key) -> {ok, Data} | {error, not_found} | {error, Reason}.
get(Table, Key, IsLock) -> {ok, Data} | {error, not_found} | {error, Reason}.
exists(Table, Key) -> boolean().

create(Table, Data) -> ok | {error, Reason}.
create(Table, Key, Data) -> ok | {error, Reason}.
insert(Table, Data) -> ok | {error, Reason}.
insert(Table, Key, Data) -> ok | {error, Reason}.
delete(Table, Key) -> ok | {error, Reason}.
take(Table, Key) -> {ok, Data} | {error, Reason}.
keysDelete(Table, Key) -> ok.
```

`create` 表示插入全新业务数据，不负责创建 ETS 表。`insert` 表示更新或覆盖已有数据。缓存表写入时会校验 `Key` 与 `Data` 中主键一致；普通 ETS 表则由调用方负责创建表和设置
`keypos`。`keysDelete/2` 仅对 hotData 表生效，删除 Keys ETS 中的 key。

普通 ETS 示例：

```erlang
ets:new(session_cache, [named_table, set, public, {keypos, 2}]),
ok = eCas:insert(session_cache, 10001, {session, 10001, online}),
{ok, {session, 10001, online}} = eCas:get(session_cache, 10001).
```

### 批量接口

```erlang
mget(Table, Keys) -> [{Key, {ok, Data} | {error, Reason}}].
mput(Table, [{Key, Data}]) -> ok | {error, Reason}.
minsert(Table, [Data]) -> ok | {error, [{Key, Reason}]} | {error, Reason}.
mupdate(Table, [{Key, Changes}]) -> ok | {error, [{Key, Reason}]}.
mdelete(Table, Keys) -> ok | {error, Reason}.
```

当前批量写接口走 `txn/3,4` 的缓存感知提交流程，不再直接复用 `eGLock:txn/4`。`minsert/2` 仅用于缓存表，
普通 ETS 表必须使用带 `Key` 的 `create/3`、`insert/3` 或 `mput/2`。

`mupdate/2` 用于局部字段更新，同样仅用于缓存表（普通 ETS 表会返回 `{error, not_cache_table}`）：

```erlang
ok = eCas:mupdate(items, [
{20001, #{count => 5}},
{20002, [{count, 8}, {updated_at, <<"2026-06-07 23:00:00">>}]}
]).
```

### 遍历

```erlang
foldTable(Table, Acc0, Fun2) -> Acc.
foldrTable(Table, Acc0, Fun2) -> Acc.
foldKey(Table, Acc0, Fun2) -> Acc.
foldrKey(Table, Acc0, Fun2) -> Acc.
```

`whole` 表走主 ETS 遍历；`hotData` 表 `foldTable/3` 会遍历 Keys ETS 并调用 `get/3` 按需回源加载数据。

### flush / reload / stats

```erlang
flush() -> ok.
flush(Table) -> ok | {error, not_cache_table}.
flushSync() -> ok | {error, [{Table, Reason}]}.
flushSync(Table) -> ok | {error, Reason}.
reload(Table) -> term().
reload(Table, Key) -> term().
stats(Table) -> map().
```

`flush/0,1` 是异步 cast。`flushSync/0,1` 是同步 call，会返回落盘错误或 `flushLimit`，不会静默吞掉失败。

`reload(Table, Key)` 遇到 Dirty ETS 中存在未落盘状态时返回 `{error, dirty_conflict}`，避免 DB 旧值覆盖本地脏数据。

`stats/1` 同时返回 camelCase 和 snake_case 字段：

```erlang
Stats = eCas:stats(items),
CacheSize = maps:get(cache_size, Stats),
DirtyCnt = maps:get(dirtyCnt, Stats).
```

测试 profile 下还导出 `dirtyMaskToFields/2`、`diffDirtyMask/5`，供 `field_diff_bench` 和 dirty 路径验证使用。

## txn 事务

`txn` 用于一次锁定多个 key，读取缓存感知快照，并按固定顺序提交变更。接口形态与 `eGLock:txn/4` 对齐。

```erlang
txn(TxnKey | [TxnKey], Fun, Args) -> term().
txn(TxnKey | [TxnKey], Fun, Args, Timeout) -> term().

TxnKey =
    {Table, Key}
  | {Table, Key, Default}
  | {noneTab, Key}
  | {noneTab, Key, Default}.
```

### 读取语义

| 表类型       | 读取规则                                                                       |
|-----------|----------------------------------------------------------------------------|
| 普通 ETS    | `ets:lookup(Table, Key)`，无值使用默认值或 `undefined`                              |
| whole     | 主缓存命中返回 `Data`，未命中使用默认值或 `undefined`                                      |
| hotData   | 主缓存命中直接返回；未命中时如果 Keys ETS 有 key，则从 DB 回源；Keys ETS 无 key 使用默认值或 `undefined` |
| `noneTab` | 不读 ETS，只用于锁定某个逻辑 key                                                       |

### 返回值语义

```erlang
Fun(Args, TxnValues) -> Ret.
Fun(Args, TxnValues) -> {alterTab, AlterTab}.
Fun(Args, TxnValues) -> {alterTab, Ret, AlterTab}.
```

`AlterTab` 格式：

```erlang
Alter =
    {{Table, Key}, Data}       %% put/update，要求 key 已在 TxnKeys 中锁定
  | {{Table, Key}, new, Data}  %% create/insert_new，不要求 key 已存在
  | {{Table, Key}, del}.       %% delete，要求 key 已在 TxnKeys 中锁定
```

示例：

```erlang
Ret = eCas:txn([{players, 10001}, {items, 20001}], fun(AddGold, Values) ->
    {{players, 10001}, Player} = lists:keyfind({players, 10001}, 1, Values),
    NewPlayer = Player#{gold => maps:get(gold, Player) + AddGold},
    {alterTab, ok, [
        {{players, 10001}, NewPlayer},
        {{items, 20001}, del}
    ]}
end, 100).
```

### 提交顺序

`txn` 不直接调用 `eGLock:txn/4`，而是自己控制提交计划：

```text
主表 Table -> Keys ETS -> Dirty ETS -> DB plan
```

当前 txn 中 whole/hotData 删除都会优先写 ETS 和 Dirty ETS；whole 表删除不在 txn 内立即执行不可回滚的 DB delete，而是交给后续
flush 幂等落盘。提交中途失败会按快照回退本次事务的所有 ETS 修改（包括新增和删除）。

### 校验与错误

`txn` 会拒绝：

- 非法 TxnKey。
- 非法 timeout。
- `put/delete` 类 alter 使用了未在 `TxnKeys` 中锁定的 key。
- 缓存表写入时 `Key` 与 `Data` 主键不一致。

允许的行为：

- 同一个 key 在 `AlterTab` 中出现多次，按顺序执行，后者覆盖前者。
- `new` 不要求 key 预先存在于 `TxnKeys` 读取结果中。

错误返回：

- 加锁超时：`{error, {lock_timeout, TxnKeys}}`。
- 提交阶段失败：`{error, Reason}`，并回滚本次事务已执行的 ETS 修改。
- `Fun` 中 `throw` 的值会原样返回给调用方；此时尚未进入提交阶段，不会修改缓存。
- 其他异常：`{error, {txn_error, {Class, Reason, Stack}}}`。

## 设计文档

原理、流程图、删除语义差异等详见：

- [docs/设计说明.md](docs/设计说明.md) — 架构图、读/写/落盘/txn 流程
- [docs/新增DbMod.md](docs/新增DbMod.md) — 新增数据库驱动的接口契约与步骤

以下内容在 README 中保留简要版；细节以设计说明为准。

### 启动与落盘（摘要）

```text
eCas:start/7 → 每张缓存表一个 csTabSrv → 定时/主动 flush → DbMod 批量写库
```

- `saveMode` 单位是**毫秒**。
- `flush/1` 异步；关键数据用 `flushSync/1` 并检查返回值。若 flush 过程中出现加锁失败或主缓存行消失等非 DB 异常，对应脏 key 会被从 Dirty ETS 移除且不再恢复。
- 停服前建议 `flushSync/0`。

## 测试与性能测试

### 默认验证

```bash
rebar3 as test compile
rebar3 eunit
```

当前测试覆盖：

- 基础 CRUD、plain ETS、`take`。
- whole/hotData 读写、DB 回源、dirty mask。
- txn 参数、默认值、`noneTab`、提交、删除、回滚、错误校验。
- `csTabSrv` 初始化、flush、失败恢复、`flushLimit`、reload dirty 冲突。
- schema 生成与 `_tmp_test/` 自动清理。
- 轻量性能烟测（`eCas_perf_eunit`）。

### 手动 benchmark

手动性能测试需要先编译 test profile：

```bash
rebar3 as test compile
```

也可使用项目启动脚本，会自动编译并加载 `src` / `test` 目录：

```bash
# Linux / macOS
chmod +x start.sh
./start.sh

# Windows
start.bat
```

#### 1. 路径吞吐：`eCas_bench`

适合粗看 put/get/txn/flush 等完整路径吞吐，**不适合**作为锁维度结论：

```erlang
eCas_bench:run().
eCas_bench:run(#{iterations => 1000, flush_rows => 500}).
```

注意：hotData 用例里 `iterations` 同时决定预置 key 数量，默认 `10000` 偏大；日常手跑建议 `500~1000`。

输出包含 `elapsed_us`、`ops_per_sec`、ETS 行数、dirty 数量、fake DB ops 数量。

#### 2. 事务锁压测：`tcCas`（推荐）

按 `eGLock/tcGL` 的方式，固定测试锁 `2/4/8/16/32/64/128` 个 key，以及 `2~512` 个并发进程：

```erlang
tcCas:tcall(false).   %% 单进程 + 全套多进程，输出到 shell
tcCas:tcall(true).    %% 输出到文件
tcCas:tlock().        %% 仅单进程
tcCas:tlock(256).     %% 仅 256 进程并发
```

内部使用 `utTc:tc/4`（单进程）和 `utTc:tc/5`（多进程）。并发结果中：

- `PAvgTime qps`：平均每个进程的吞吐。
- `PSumTime ... (gqps)`：全局并发吞吐，约等于 `success * LoopTime / PMaxTime`。

#### 3. dirty 字段 diff：`field_diff_bench`

```erlang
field_diff_bench:run().       %% baseline + eCas diffDirtyMask
field_diff_bench:run_ecas().  %% 仅 eCas 实现
field_diff_bench:run(#{iterations => 100000, change_count => 4}).
```

## 方案优缺点

### 优点

| 方面     | 说明                                              |
|--------|-------------------------------------------------|
| 应用层简单  | 业务代码主要操作 `get/insert/create/delete/txn`，无需到处写 DB 逻辑 |
| 读性能高   | whole 表常驻 ETS；hotData 命中后也只读 ETS                |
| 写合并    | 多次写入可合并到后续批量 flush，降低 DB 压力                     |
| 支持局部落盘 | dirty 模式只写变化字段，适合大 record/map                   |
| 并发粒度细  | 以 `{Table, Key}` 为锁粒度，减少不同 key 之间的阻塞            |
| 大表友好   | hotData 只启动加载 key，数据按需加载                        |
| 可观测性   | `stats/1` 提供缓存大小、dirty 数、内存占用、配置和样本             |

### 缺点与风险

| 风险            | 说明                                 | 建议                             |
|---------------|------------------------------------|--------------------------------|
| 崩溃丢脏数据        | Dirty ETS 和主缓存都是内存态，未落盘时 VM 崩溃会丢数据 | 关键表增加 WAL/dirty journal 或同步写策略 |
| flush 异常丢脏 key | 加锁失败、主缓存行消失等非 DB 异常会导致脏 key 从 Dirty ETS 移除且不恢复 | 关键数据用 `flushSync/1` 并检查返回值；异常时人工介入 |
| whole 大表内存高   | 全量加载可能导致启动慢或内存压力大                  | 大表优先用 hotData                  |
| 单表落盘串行        | 每张缓存表一个 `csTabSrv`，flush 在单进程内组织批次 | 合理设置 `flushLimit`，必要时按业务拆表     |
| 多节点不一致        | 当前无跨节点缓存失效/同步                      | 使用单写节点、广播失效或外部 L2 缓存           |
| 无复合主键         | 当前多处匹配 `[PkField]`                 | 需要扩展 key 规范和 DB where 条件       |
| terminate 不可靠 | `terminate/2` flush 只能 best effort | 停服前显式 `flushSync/0,1` 并检查返回    |

## 待完善功能

### P0：一致性与可靠性

- WAL / dirty journal：写缓存时记录持久化日志，重启后 replay 未完成变更。
- 强同步写模式：关键表或关键操作可配置为写缓存后立即写 DB。
- flush 失败告警：记录失败次数、最后失败原因、连续失败时触发告警。
- 停服策略：`stop/0` 可配置先 `flushSync`，失败时拒绝停服或返回详细错误。

### P1：性能与运维

- telemetry 指标：flush 次数、耗时、失败数、dirty 数、TTL 淘汰数、DB 回源次数。
- 启动加载超时：表加载卡住时返回明确错误，而不是无限等待。
- DB 影响行数校验：批量 update/delete 返回数量低于预期时记录告警。
- 空值缓存 / 防击穿：hotData 对不存在 key 可短 TTL 缓存空结果。

### P2：功能扩展

- 复合主键支持：Key 改为 tuple 或规范化 map。
- 二级索引：为常见查询字段维护辅助 ETS。
- 只读表：在 `#tbCache{}` 中增加 `readOnly` 并在写入口拒绝。
- schema 热重载：动态更新 `cacheTabDef/dbSchemaDef` 并迁移内存数据。
- 多节点缓存失效：通过 pg/gproc/消息总线广播 `{invalidate, Table, Key}`。

## 依赖

| 依赖         | 用途                              |
|------------|---------------------------------|
| `eGLock`   | key 级并发锁                        |
| `eMysql`   | MySQL schema/DB 操作              |
| `ePgdb`    | PostgreSQL schema/DB 操作         |
| `ePtDirty` | 脏字段相关依赖，当前核心路径主要手动计算 dirty mask |

## 当前边界声明

- 当前实现以单主键为前提。
- 当前没有持久化 dirty log。
- 当前没有 `start/0` 或从 `sys.config` 自动启动的入口。
- 当前 `saveMode` 按毫秒处理，不是秒。
- 普通 ETS 表不由 eCas 创建，调用方必须自己建表并设置正确 `keypos`。
