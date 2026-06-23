# 新增 DbMod（数据库驱动）

本文档说明如何为 eCas 接入一个新的数据库驱动（DbMod）。DbMod 是 eCas 抽象出来的数据库访问接口，由 `eCas:start/7` 的第一个参数指定；所有缓存表进程的加载、落盘、reload、stats 都通过它与真实数据库交互。

要让一张表走 eCas 缓存，需要三个东西配合：

| 模块 | 作用 | 谁来读 |
|------|------|--------|
| `dbSchemaDef` | 表结构、字段、主键、SQL 模板、编解码信息 | DbMod 落盘/回源、csTabSrv 初始化 |
| `cacheTabDef` | 哪些表要缓存、缓存类型、saveType、flushLimit 等 | csTabSrv init/eCas API |
| DbMod | 真正的连接池与 SQL 执行 | eCas / csTabSrv 运行期调用 |

当前仓库内的参考实现：

- **eMysql**（MySQL 驱动，外部库）
- **ePgdb**（PostgreSQL 驱动，外部库）
- **fake_db**（`test/fake_db.erl`，纯 ETS 内存替身，用于单元测试）

新增一个 DbMod，本质上就是实现 DbMod 的 callback 接口，并补齐它依赖的 `dbSchemaDef` / `cacheTabDef`。下面以 `fake_db` 为对照逐条说明。

## 1. 接入流程概览

1. 在业务项目里准备三个模块：`dbSchemaDef`、`cacheTabDef`、`my_db`。
2. 写一个 schema 描述文件（参考 `test/schema/mysql/mysql_cache_schema.erl` 与 `test/schema/postgresql/pg_cache_schema.erl`），里面列出每张表的所有字段、类型、约束、codec 与 `#tbCache{}` 配置。
3. 跑 `genMSchema:gen/6` 或 `genPSchema:gen/6`（由 eMysql / ePgdb 提供），自动生成 `dbSchemaDef` 和 `cacheTabDef` 两个模块；或者手写这两个模块（见下文 §3 / §4）。
4. 实现 DbMod 的全部 callback（见下文 §2）。
5. `eCas:start(my_db, Host, Port, User, Password, DbName, PoolArgs)`。
6. 用 eunit 覆盖：start/stop、单行 get、批量 insert/update/delete、foreachRows 投影、flushSync 校验 Dirty ETS 清空。

## 2. DbMod callback 接口

下面所有函数都是 eCas 在运行期会同步/异步调用的契约。函数命名、参数顺序、返回格式必须严格匹配。

### 2.1 `start/6` 与 `stop/0`

```erlang
start(Host, Port, User, Password, DbName, PoolArgs) -> {ok, DbPid} | {error, Reason}.
stop() -> ok | {error, Reason}.
```

- `start/6` 由 `eCas:start/7` 同步调用：建立连接池并返回 `{ok, DbPid}`，`DbPid` 可以是监督进程 pid 或池管理器 pid，eCas 仅作展示用。
- `PoolArgs` 是用户透传的 proplist（如 `[{wFCnt, 8}, ...]`），DbMod 自行决定如何使用。eCas 自己也只取 `wFCnt` 作为缓存表启动并发度。
- `stop/0` 由 `eCas:stop/0` 调用：要求幂等，安全关闭连接池即可返回 `ok`。

实现要点：

- 启动失败必须返回 `{error, Reason}`，eCas 会包装为 `{error, {db_start_failed, DbMod, Reason}}`。
- 若 DbMod 内部用 `persistent_term` 缓存 schema，启动时务必加载完成再返回。

### 2.2 `get/2`（单行回源）

```erlang
get(Table, Filter) -> {ok, [Row | _]} | {ok, []} | {error, Reason}.
```

调用方：

- `eCas:loadFromDb/3`（hotData 缓存 miss 后回源）
- `csTabSrv:doReloadKey/4`（`reload(Table, Key)` 内部）

调用形式固定为 `DbMod:get(Table, [{PkField, Key}])`，其中 `PkField = cacheTabDef:tablePrimaryKey(Table)` 单元素列表的第一项。

返回：

- `{ok, [Data]}`：命中一条数据，`Data` 已经是 Erlang 端表示（map 或 record tuple），`cacheTabDef:keyValue/2` 应当能从中取出主键。
- `{ok, []}`：DB 中不存在该 key，eCas 会清除 Keys ETS 中的僵尸 key 并返回 `{error, not_found}`。
- `{error, Reason}`：eCas 会包装为 `{error, {load_error, Reason}}` 并记日志。

实现要点：

- 字段名应匹配 `dbSchemaDef:tableSchema(Table)` 中的 `#schField.name`。
- codec（json / atom / term_str / term_binary）由 DbMod 在此处完成解码；上层 eCas 不会再做转换。

### 2.3 `foreachRows/4,5`（初始化扫描）

```erlang
foreachRows(Table, Filter, PageSize, Fun) -> ok | {error, Reason}.
foreachRows(Table, Filter, PageSize, Opts, Fun) -> ok | {error, Reason}.
```

调用方：

- `csTabSrv:doLoadWholeData/3` → `DbMod:foreachRows(Table, [], 500, [], Fun)`，**4 个参数**版本。
- `csTabSrv:doLoadAllKeys/3` → `DbMod:foreachRows(Table, [], 500, [{fields, PKeyFields}], Fun)`，**5 个参数**版本。

行为契约：

- 必须按 `PageSize` 分页拉取，**对每条数据同步调用 `Fun(Row)`**。
- `Filter` 启动加载时固定为 `[]`，全表扫描。
- `Opts` 启动加载时是 `[]` 或 `[{fields, [Field] | [Field, ...]}]`：
  - `[]`：原样返回整行（whole 加载）。
  - `[{fields, ...}]`：DbMod 必须按给出的字段投影，每行只返回这些字段（hotData 加载 keys 阶段）。
- 单行 `Fun` 内部抛出 `throw/1`（例如 eCas 的 `throw({load_error, ...})`）必须能正常传播；DbMod 不要把这种 `throw` 转成 `{error, ...}`。
- DB 整体错误（如分页失败）返回 `{error, Reason}`，csTabSrv 会中止加载并使表进程 crash。

实现要点：

- 投影实现可以是 `SELECT field1, field2, ...` 或在 DbMod 内部 map-filter；hotData 阶段不要求 `map:with/2` 这种应用层裁剪，因为大批量 key 走网络拉取会很慢。
- 任意一行 `Fun` 内 `ets:insert` 等异常会走 csTabSrv 的 try/catch 并 `throw({load_error, ...})`，DbMod 不需要关心。

### 2.4 `batchInsert/2`（脏数据落盘 — insert/upsert）

```erlang
batchInsert(DbRows, Overwrite) -> ok | {ok, Cnt} | {error, Reason}.
```

调用方：

- `csTabSrv:doSaveData/10`（whole 模式与 dirty 模式都用到）
  - whole 模式：`batchInsert([Data | ...], true)`，要求 `true` 表示 upsert。
  - dirty 模式：`batchInsert([Data | ...], true)`，`?cs_new` 的行也走 batchInsert。

契约：

- `DbRows` 是 Erlang 端数据列表，每项 `Data` 是 `cacheTabDef:keyValue/2` 可读主键的 map / tuple。
- `Overwrite = true` 时 DbMod 必须按主键做 upsert（`ON CONFLICT / ON DUPLICATE KEY UPDATE`）；`false` 时允许 `INSERT`。
- 当前 csTabSrv 固定传 `true`，DbMod 实现只接 `true` 即可。
- 成功返回 `ok` 或 `{ok, Cnt}`；失败返回 `{error, Reason}`，csTabSrv 会把所有本批 key 回写到 Dirty ETS 等待下轮重试。

实现要点：

- SQL 模板由 DbMod 内部按 `dbSchemaDef:tableInsert/1` / `tableReplace/1` 拼装（参考 `eMysql/ePgdb`）。
- codec 编码（json / atom / term_str / term_binary）在调用 SQL 前完成。

### 2.5 `batchUpdate/1`（脏数据落盘 — update）

```erlang
batchUpdate(Updates) -> ok | {ok, Cnt} | {error, Reason}.
```

调用方：

- `csTabSrv:doSaveData/10` 的 dirty 模式：`batchUpdate(Updates)`，每项 `Updates = {Data, DirtyMask, Where}`。
  - `Data` 是当前 Erlang 端数据（map / tuple）。
  - `DirtyMask` 是字段位掩码；DbMod 必须能用 `eCas:dirtyMaskToFields/2`（测试 profile 导出）反解为字段名列表，并只更新这些字段。
  - `Where` 是 `[{PkField, Key}]`，单条 where 条件。

契约：

- 只写 DirtyMask 标记的字段，未变化字段不动。
- 成功 `ok` 或 `{ok, Cnt}`；失败 `{error, Reason}` 会导致本批所有 key 回到 Dirty ETS。

实现要点：

- 字段名顺序以 `dbSchemaDef:tableFields/1` 的位置为位（位 0 对应第 1 字段）。
- DbMod 应避免根据 `Data` 中不存在的字段生成 SQL（dirty 模式可能只携带部分字段）。

### 2.6 `batchDelByKey/3`（脏数据落盘 — delete）

```erlang
batchDelByKey(Table, PkField, Keys) -> {ok, DeletedCnt} | {error, Reason}.
```

调用方：

- `csTabSrv:doSaveData/10`（whole 与 dirty 都用到）。
- `Keys` 列表可能为空（empty list），DbMod 应当直接返回 `{ok, 0}` 而不是发 SQL。

契约：

- `PkField` 是字段名 atom；`Keys` 是主键值列表。
- 返回 `{ok, DeletedCnt}`；失败 `{error, Reason}` 时 csTabSrv 会把本批 delete key 回写到 Dirty ETS。

### 2.7 `schema/1`（stats 输出）

```erlang
schema(Table) -> #schema{...} | undefined.
```

调用方：

- `csTabSrv:collectStats/3`，结果作为 `stats/1` 返回的 `schema` 字段透出。

契约：

- 必须返回 `#schema{repr, comment, tbCache, fields}` record，与 `dbSchemaDef:tableSchema/1` 行为一致。
- 找不到的表可以返回 `undefined`（`fake_db` 即转发到 `dbSchemaDef:tableSchema/1`）。

### 2.8 `delete/2`（可选）

`fake_db` 实现了 `delete/2`，但当前 eCas 主流程中 csTabSrv 全部走 `batchDelByKey/3`，并没有直接调用 `DbMod:delete/2`。新驱动可以只实现 `batchDelByKey/3`，不需要 `delete/2`。

## 3. dbSchemaDef 接口契约

`dbSchemaDef` 给 DbMod 提供表结构、字段定义、SQL 模板、codec 等信息。它是 DbMod 与缓存层之间的 schema 单一来源。

### 3.1 必需函数

| 函数 | 说明 |
|------|------|
| `getTables() -> [Table]` | 当前 schema 描述的所有表名。`eCas:start/7` 通过 `cacheTabDef:getCaches/0` 间接读到；`dbSchemaDef:getTables/0` 主要给 DbMod 内部使用。 |
| `tableFields(Table) -> [{BinName, Pos, Codec, FieldAtom}]` | 字段列表，Pos 是 1-based 字段顺序，Codec 是 `undefined` / `json` / `atom` / `term_str` / `term_binary` 之一。`fake_db` 内部用 `eCas:dirtyMaskToFields/2` 反解 DirtyMask。 |
| `tableInsert(Table) -> iodata() \| undefined` | 纯 INSERT 模板（占位符由 DbMod 自行决定，eMysql 用 `?`，ePgdb 用 `$1, $2, ...`）。`undefined` 表示该表不可 insert。 |
| `tableReplace(Table) -> iodata() \| undefined` | upsert 模板（含 `ON CONFLICT` / `ON DUPLICATE KEY UPDATE` 子句）。`batchInsert/2` 走这条。 |
| `onReplace(Table) -> iodata() \| undefined` | 与 `tableReplace/1` 等价的「冲突时如何更新」子句片段，方便 DbMod 在自定义拼接时复用。 |
| `tableSchema(Table) -> #schema{} \| undefined` | 完整 schema 描述。`csTabSrv:collectStats/3` 与 `fake_db:schema/1` 都通过它输出调试信息。 |
| `tablePrimaryKey(Table) -> [FieldAtom]` | 主键字段名列表。`csTabSrv` 当前只取第一元素；`DbMod:get/2` 接收 `[{PkField, Key}]`。 |
| `fieldSchema(Table, Field) -> #schField{} \| undefined` | 单字段描述（类型、默认、codec、注释）。DbMod 在拼 SQL 和解码时使用。 |
| `fieldCodec(Table, Field) -> Codec` | 字段编解码策略，等价于 `fieldSchema/2` 的 `codec` 字段。 |
| `fieldDefault(Table, Field) -> Default` | 字段默认值，等价于 `fieldSchema/2` 的 `default` 字段。 |

### 3.2 record 定义

`dbSchemaDef` 模块顶部必须包含这两个 record 定义（genMSchema / genPSchema 自动生成时就直接带上）：

```erlang
-record(schema, {
    repr = map,          %% record | map - Erlang 端数据表示方式
    comment = "",        %% string()|binary() - 表注释
    tbCache = undefined, %% undefined | #tbCache{}  缓存配置
    fields = []          %% [#schField{}]
}).

-record(schField, {
    name,                %% atom()     - 字段名
    dbType,              %% term()     - 数据库类型
    default = undefined, %% term()     - 默认值
    opts = [],           %% [term()]   - 约束
    codec = undefined,   %% undefined | json | term_str | term_binary | atom
    erlType = "",        %% string()   - Erlang 类型声明字符串
    comment = ""         %% string()|binary() - 字段注释
}).
```

`#tbCache{}` 见 §4.2。

### 3.3 写法

通常不手写 `dbSchemaDef`，而是：

1. 写一个 `*_cache_schema.erl`（参考 `test/schema/mysql/mysql_cache_schema.erl`），里面用 `#schema{}` 描述所有表。
2. 调用 `eCas:genM()` / `eCas:genP()`（即 `genMSchema:gen/6` / `genPSchema:gen/6`），传入：
   - 描述文件所在目录
   - 目标 schema 模块名（生成 `dbSchemaDef`）
   - 目标 cache 模块名（生成 `cacheTabDef`）
   - 输出目录
   - include 目录
3. 生成的 `dbSchemaDef` 直接被 DbMod 引用；DbMod 的内部函数（如 SQL 拼装、codec 编解码）应当完全基于 `dbSchemaDef:tableFields/1` 等接口，而不是硬编码字段名。

如果不想用生成器，必须手写一个模块，导出上面列出的全部函数，并在模块顶部 include `eCas.hrl` 拿到 `#schema{}` 与 `#schField{}` record 定义。

### 3.4 DbMod 如何使用 dbSchemaDef

DbMod 的常见用法：

- `tableReplace(Table)` / `tableInsert(Table)`：拼装批量写入的 SQL 模板。
- `tableFields(Table)`：得到字段顺序与 codec，决定参数数组与占位符数量。
- `fieldCodec/2` + `fieldDefault/2`：在 row 与 SQL 参数互转时做编解码。
- `tableSchema/1`：在 `schema/1` 回调里直接转发。
- `tablePrimaryKey/1`：实现 `batchDelByKey/3` 时定位主键名。

## 4. cacheTabDef 接口契约

`cacheTabDef` 告诉 csTabSrv 每张表「要不要缓存」「怎么缓存」。它是 eCas 启动期间唯一读 `tbCache` 的来源。

### 4.1 必需函数

| 函数 | 说明 |
|------|------|
| `getCaches() -> [Table]` | 需要走缓存层的全部表名。`eCas:start/7` 用它创建 csTabSrv 进程。 |
| `tableCache(Table) -> #tbCache{} \| undefined` | 表的缓存配置；返回 `undefined` 时该表被当成普通 ETS。csTabSrv 启动加载、定时落盘、TTL 淘汰都依赖它。 |
| `tableFields(Table) -> [{BitPos, BitMask, Field}]` | dirty 位掩码辅助函数：`BitPos` 是 0-based 字段位，`BitMask` 是该位对应的 2^N，`Field` 是字段名 atom。`eCas:diffDirtyMask/5` 通过这张表决定哪个字段被修改。 |
| `tablePrimaryKey(Table) -> [FieldAtom]` | 与 `dbSchemaDef:tablePrimaryKey/1` 内容一致。`csTabSrv` 用它做 where 条件与 `ets:lookup`。 |
| `cacheType(Table) -> whole \| hotData \| undefined` | `tableCache(Table)#tbCache.type` 的快捷访问。 |
| `saveType(Table) -> whole \| dirty \| undefined` | `tableCache(Table)#tbCache.saveType` 的快捷访问。 |
| `keyValue(Table, Data) -> Key` | 从一行 Erlang 数据中提取主键值。`repr = map` 时通常 `maps:get(id, Data)`，`repr = record` 时是 `element(2, Data)`。`csTabSrv` 初始化加载、`eCas` 写入都用它。 |
| `dirtyIndex(Table) -> Offset` | dirty 模式下「数据」在 cache tuple 中的位置（`repr=map` 时是 2，`repr=record` 时通常是 record 字段 2 的位置）。`eCas:diffDirtyMask/5` 内部用。 |

### 4.2 `#tbCache{}` 字段

由 `eCas.hrl` / `dbSchemaDef` 共同定义；两者必须保持完全一致：

```erlang
-record(tbCache, {
    type = whole,         %% whole | hotData
    ttl = 0,              %% non_neg_integer() 秒，hotData 缓存 TTL，0 = 永不淘汰
    saveMode = 300,       %% pos_integer() 落盘定时器周期，毫秒
    saveType = whole,     %% whole | dirty
    loadFun = undefined,  %% undefined | {M, F, A}
    flushLimit = 500,     %% non_neg_integer() 单轮 flush 最多处理的脏 key 数；infinity = 一次刷完
    isOrder = false       %% boolean() true 则主表 / Keys 表用 ordered_set
}).
```

详细语义参见 [设计说明.md](./设计说明.md)。

### 4.3 写法

强烈建议通过 `genMSchema:gen/6` / `genPSchema:gen/6` 一并生成 `cacheTabDef`，因为 dirty 位掩码的 `BitPos` / `BitMask` 手算容易出错。

如果手写：

- 顶部 `-include("eCas.hrl").` 拿到 `#tbCache{}`。
- `tableFields/1` 返回的 `BitMask` 顺序必须与 `dbSchemaDef:tableFields/1` 的 `Pos` 严格一致：第 1 个字段 `BitPos=0, BitMask=1`、第 2 个字段 `BitPos=1, BitMask=2`……
- `keyValue/2` 必须能从 `repr` 指定的 Erlang 表示中取到主键。
- `dirtyIndex/1` 当前 `repr=map` 的表统一返回 `0`（即从 cache tuple 第二个元素开始计），`repr=record` 的表按 record 字段位置调整。

### 4.4 eCas 启动时如何用到

- `eCas:start/7` 调 `cacheTabDef:getCaches/0` 拿到全部缓存表名。
- 每个表启动一个 `csTabSrv`，`init/1` 调 `cacheTabDef:tableCache/1` 读取 `#tbCache{}`。
- 写入路径 `eCas:doCacheInsert/3` 调 `cacheTabDef:saveType/1`、`keyValue/2`、`dirtyIndex/1`。
- 落盘路径 `csTabSrv:doSaveData/10` 调 `cacheTabDef:tablePrimaryKey/1`、`saveType/1`。
- TTL 路径 `csTabSrv:evictExpired/3` 读 `type` 与 `ttl`。
- 重新加载 `csTabSrv:doReloadKey/4` 同样读 `#tbCache.type` 决定要不要维护 Keys ETS。

## 5. 错误处理约定

- 业务可恢复错误（如连接断开、约束冲突）一律返回 `{error, Reason}`，eCas 会回退到 Dirty ETS 等待下轮重试。
- 进程级致命错误（连接池彻底不可用）建议在 `start/6` 阶段就返回 `{error, ...}`；运行期崩溃时 eCas 不会捕获连接池的 `EXIT`，依赖业务层 supervision。
- 行级异常（如 `eCas:doLoadWholeData` 中的 `tryLock` 冲突、调用方 throw）由 csTabSrv 自己捕获，DbMod 不需要做任何转换。

## 6. 一个最简实现长什么样

下面是一份最简骨架，覆盖 eCas 运行期会调到的全部函数；真实实现里把 `ets` 替换为对应的连接池/SQL 即可。

```erlang
-module(my_db).
-export([
    start/6, stop/0,
    get/2,
    batchInsert/2, batchUpdate/1, batchDelByKey/3,
    foreachRows/4, foreachRows/5,
    schema/1
]).

start(_Host, _Port, _User, _Password, _DbName, _PoolArgs) ->
    %% 初始化连接池、加载 schema 等
    {ok, self()}.

stop() ->
    ok.

get(Table, [{_PkField, _Key}]) ->
    %% 从 DB 读取一行并按 dbSchemaDef 上的 codec 解码
    {ok, []}.

batchInsert(_Rows, _Overwrite) -> ok.
batchUpdate(_Updates) -> ok.
batchDelByKey(_Table, _PkField, []) -> {ok, 0};
batchDelByKey(_Table, _PkField, _Keys) -> {ok, length(_Keys)}.

foreachRows(_Table, _Filter, _PageSize, Fun) ->
    Fun(#{...}),
    ok.

foreachRows(_Table, _Filter, _PageSize, Opts, Fun) ->
    Fields = proplists:get_value(fields, Opts, undefined),
    Row = case Fields of
              undefined -> #{...};
              _         -> maps:with(Fields, #{...})
          end,
    Fun(Row),
    ok.

schema(Table) ->
    dbSchemaDef:tableSchema(Table).
```

完整真实参考请看 `test/fake_db.erl`（DbMod 视角）和 `test/dbSchemaDef.erl` / `test/cacheTabDef.erl`（生成产物视角）。

## 7. 与 eCas 启动的衔接

- `eCas:start/7` 第一参数就是 DbMod 模块名。
- `eCas` 内部通过 `persistent_term:put(?csDbMod, DbMod)` 保存当前驱动；后续 `loadFromDb`、`stats/1` 等都从 `persistent_term` 取。
- 业务层启动脚本无需感知 DbMod 细节，只需保证 DbMod、dbSchemaDef、cacheTabDef 在 eCas 启动前可用（一般通过 rebar3 deps 引入 + 编译进代码路径）。

## 8. 单元测试建议

- 用 `eCas_eunit:setup/0,1` 跑基础 CRUD。
- 用 `fake_db:set_fail/2`、`fake_db:clear_fail/1` 模拟批量落盘失败，覆盖 `restoreSaveErrors` 路径。
- DbMod 自身需要单测覆盖：`start/stop`、`get` 命中/未命中、`foreachRows` 分页、批量 insert/update/delete 的 SQL 拼接与失败回执。
- 写一个 eunit 把 `eCas:start(my_db, ...)` 跑起来，再 `flushSync/1` 验证 Dirty ETS 清空；这是验证契约最直接的方法。
- 启动后用 `eCas:stats/1` 校验返回的 `schema` 字段与 `dbSchemaDef:tableSchema/1` 一致。
- 启动前在 `_tmp_test/` 下用 `schema_codegen_eunit` 的方式跑一次 `genMSchema:gen/6` 或 `genPSchema:gen/6`，确认 codegen 路径能产出可被 DbMod 读入的 schema 模块。

## 9. 已知约束

- 单一主键：`cacheTabDef:tablePrimaryKey/1` 当前 `csTabSrv` 内部用 `lists:nth(1, PkFields)` 取主键，DbMod 应当按单主键实现。
- `schema/1` 的 fields 顺序与 dirty mask 位一致：从位 0 开始，第 N+1 字段对应位 N。
- `batchInsert` 与 `batchUpdate` 的批大小受 csTabSrv 的 `flushLimit` 限制；DbMod 内部可以再分批执行，但失败要整体回退。
- eCas 不会主动重启 DbMod 内部连接池，DbMod 需要自管重连。
- 如果 schema 里有 `loadFun`，DbMod 不必感知；`loadFun` 由 csTabSrv 同步调用，DbMod 只在 `foreachRows` 阶段透出行数据。
