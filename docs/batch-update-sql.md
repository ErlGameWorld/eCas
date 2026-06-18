# batchUpdate 批量 Patch 更新（`_set` + 值）

为 **eCas 脏数据落盘**设计：单表、多行、每行更新字段可不同，合并为一条 patch SQL。

主接口：

```erlang
eMysql:batchUpdate([{SetData, DirtyMaskOrFields, Where}, ...])
ePgdb:batchUpdate([{SetData, DirtyMaskOrFields, Where}, ...])

%% 外层已有连接/事务时：
eMysql:batchUpdate(Conn, [{SetData, DirtyMaskOrFields, Where}, ...])
ePgdb:batchUpdate(Conn, [{SetData, DirtyMaskOrFields, Where}, ...])
```

- **单表、单条 SQL**、单次往返（与 `batchInsert/1` 一样直接 `equery`，不包事务）
- `col_set = false` → 不更新该列
- `col_set = true` 且 `col = NULL` → 写入 NULL
- `col_set = true` 且 `col = 值` → 写入具体值

> **编码约定**：字段出现在该行的 `SetCols`（eCas 即 `DirtyFields`）中，则 `col_set = true`，并写入 `enCodecValue` 结果——编码为
`null` 也会覆盖更新；未出现在 `SetCols` 的列在本行 `col_set = false`。

## API（eCas）

```erlang
DbMod:batchUpdate([
  {RowMapWithTableName, DirtyMask, [{PkField, Key}]},
  ...
])
```

- `SetData`：行数据 map / record；map 必须包含 `table_name`
- `DirtyMaskOrFields`：本行要 patch 的字段位掩码或字段列表
- `Where`：主键过滤条件，例如 `[{id, 10001}]`

字段列表为空或掩码为 `0` 的行跳过。eCas 当前调用 `batchUpdate/1`，不会调用不存在的 `batchUpdate/3`。

---

## 核心 SQL 形态

对批次内出现过的所有字段 `a, b, c, ...`，派生表每行包含：

```text
id, a_set, a, b_set, b, c_set, c, ...
```

表级 `SET`（两库相同逻辑）：

```sql
t.a = CASE WHEN v.a_set THEN v.a ELSE t.a END,
t.b = CASE WHEN v.b_set THEN v.b ELSE t.b END,
...
```

---

## PostgreSQL（ePgdb）

实现：`pgdbQuery:buildBatchUpdate/3`

### 示例

表 `items`，主键 `id`，本批三行分别 patch 不同列：

```sql
UPDATE "items" AS t
SET
    t."count" = CASE WHEN v."count_set" THEN v."count" ELSE t."count" END,
    t."attrs" = CASE WHEN v."attrs_set" THEN v."attrs" ELSE t."attrs" END
FROM (
    VALUES
        ($1, $2,  $3,  $4,      $5),
        ($6, $7,  $8,  $9,      $10),
        ($11, $12, $13, $14,     $15)
) AS v(
    "id",
    "count_set", "count",
    "attrs_set", "attrs"
)
WHERE t."id" = v."id";
```

### 语义示例（与标准方案一致）

| id | count_set | count | attrs_set | attrs | 结果                  |
|----|-----------|-------|-----------|-------|---------------------|
| 1  | true      | 10    | false     | NULL  | 只改 count=10         |
| 2  | false     | NULL  | true      | 20    | 只改 attrs=20         |
| 3  | true      | NULL  | true      | 99    | count→NULL，attrs→99 |

### 参数顺序

每个 `VALUES` 元组：`id, field1_set, field1, field2_set, field2, ...`（字段顺序为本批所有行 `SetCols` 的并集，首次出现顺序）。

`field_set` 绑定 `true` / `false`；未 patch 的列值为 `null`（不会被 `CASE` 采用）。

---

## MySQL（eMysql）

实现：`mysqlQuery:buildBatchUpdate/3`  
（MySQL 无 `UPDATE ... FROM (VALUES ...)`，使用 `JOIN` + `UNION ALL` 派生表。）

### 示例

```sql
UPDATE `items` AS t
INNER JOIN (
    SELECT ? AS `id`, ? AS `count_set`, ? AS `count`, ? AS `attrs_set`, ? AS `attrs`
    UNION ALL
    SELECT ?, ?, ?, ?, ?
    UNION ALL
    SELECT ?, ?, ?, ?, ?
) AS v ON t.`id` = v.`id`
SET
    t.`count` = CASE WHEN v.`count_set` THEN v.`count` ELSE t.`count` END,
    t.`attrs` = CASE WHEN v.`attrs_set` THEN v.`attrs` ELSE t.`attrs` END;
```

`count_set` / `attrs_set` 绑定 `1` / `0`（`CASE WHEN` 按布尔语义处理）。

### 参数顺序

每个 `SELECT` 行：`id, count_set, count, attrs_set, attrs, ...`，多行按 `UNION ALL` 顺序拼接。

---

## 与 eCas 脏落盘的关系

| 场景                     | 行为                               |
|------------------------|----------------------------------|
| 同表、每行 `DirtyFields` 不同 | 仍 **一条** `batchUpdate` SQL（按表合并） |
| 字段在 `DirtyFields` 中    | `col_set = true`，编码值写入（含 NULL）   |
| 字段不在本行 `DirtyFields`   | 本行 `col_set = false`，保留库中原值      |
| `flushLimit` 几十～几百行    | 适合当前实现；更大规模见下节                   |

---

## 何时升级到临时表

若出现：单次 **上千～上万行**、SQL 过长、解析变慢，可升级为：

| 库          | 方案                                   |
|------------|--------------------------------------|
| PostgreSQL | `COPY` → 临时表 → `UPDATE ... FROM tmp` |
| MySQL      | 批量 `INSERT` 临时表 → `JOIN UPDATE`      |

当前 **几十～几百行、列组合分散** 的 flush，patch + `VALUES`/`UNION ALL` 为推荐工程解。

---

## 源码位置

| 库       | 构建函数                                              | 文件                                                   |
|---------|---------------------------------------------------|------------------------------------------------------|
| eMysql  | `mysqlQuery:buildBatchUpdate/3`                   | `_build/default/lib/eMysql/src/mysql/mysqlQuery.erl` |
| ePgdb   | `pgdbQuery:buildBatchUpdate/3`                    | `_build/default/lib/ePgdb/src/pgdb/pgdbQuery.erl`    |
| 分组 / 编码 | `encodeBatchPatchFields/2`, `groupBatchUpdates/1` | 各库 `eMysql.erl` / `ePgdb.erl`                        |

> 修改依赖源码后需在 **eMysql / ePgdb 仓库** 提交；仅改 `_build` 会在 `rebar3 compile` 拉 git 时被覆盖。

每批几十～几百行、同一张表但是每条 更改的字段不相同 pg/mysql 最好的批量更新sql语句 如果更新的值本身就为null
也能正确更新，并且不更新的字段可以完全不出现在SQL里，
最终给你一套“可直接落地”的标准方案。

目标：

- 批量更新
- 每行更新字段不同
- NULL 可以真正写入
- 字段缺失表示“不更新”
- 单 SQL
- 高性能
- PG / MySQL 都支持

核心思想统一：

每个字段传：

- `xxx_set`
- `xxx`

即：

```text
是否更新 + 更新值
```

因为只有这样才能同时表达：

```text
1. 不更新
2. 更新成 NULL
3. 更新成具体值
```

===================================
PostgreSQL 最终方案
===================================

表：

```sql
CREATE TABLE my_table (
    id bigint primary key,
    a int,
    b int,
    c int
);
```

批量更新：

```sql
UPDATE my_table AS t
SET
    a = CASE WHEN v.a_set THEN v.a ELSE t.a END,
    b = CASE WHEN v.b_set THEN v.b ELSE t.b END,
    c = CASE WHEN v.c_set THEN v.c ELSE t.c END
FROM (
    VALUES
        (1, true,  10,   false, NULL, true,  NULL),
        (2, false, NULL, true,  20,   false, NULL),
        (3, true,  NULL, true,  30,   true,  99)
) AS v(
    id,

    a_set, a,
    b_set, b,
    c_set, c
)
WHERE t.id = v.id;
```

语义：

第一行：

```text
id=1

a_set=true  -> a=10
b_set=false -> b 不更新
c_set=true  -> c=NULL
```

这是 PostgreSQL 里非常推荐的批量 patch update 写法。

===================================
MySQL 最终方案
===================================

MySQL 没有：

```sql
UPDATE ... FROM (VALUES ...)
```

所以改成 JOIN derived table：

```sql
UPDATE my_table t
JOIN (
    SELECT
        1 AS id,
        TRUE  AS a_set, 10   AS a,
        FALSE AS b_set, NULL AS b,
        TRUE  AS c_set, NULL AS c

    UNION ALL

    SELECT
        2,
        FALSE, NULL,
        TRUE,  20,
        FALSE, NULL

    UNION ALL

    SELECT
        3,
        TRUE,  NULL,
        TRUE,  30,
        TRUE,  99
) v
ON t.id = v.id

SET
    t.a = CASE WHEN v.a_set THEN v.a ELSE t.a END,
    t.b = CASE WHEN v.b_set THEN v.b ELSE t.b END,
    t.c = CASE WHEN v.c_set THEN v.c ELSE t.c END;
```

===================================
为什么这是最终工程解
===================================

因为它同时满足：

✅ 单 SQL

✅ 单事务

✅ 单网络往返

✅ 支持真正 NULL 更新

✅ 支持“不更新字段”

✅ 不需要循环 UPDATE

✅ 性能适合几十～几百行

✅ 不依赖存储过程

✅ ORM 也容易生成

===================================
什么时候再升级
===================================

如果未来：

- 上千～上万行
- 高频批量写
- SQL 太长

那就升级成：

PG：

- temp table + COPY + UPDATE JOIN

MySQL：

- temp table + batch insert + JOIN UPDATE

但你现在：

- 几十～几百行

上面这个方案已经非常合适。

---

## 实战示例：`players` 表（含 NULL 写入）

以项目实际 `players` 表为例，主键 `id`，字段：

| 字段         | 类型                      |
|------------|-------------------------|
| id         | BIGSERIAL / BIGINT (PK) |
| account    | VARCHAR(64)             |
| level      | INTEGER                 |
| gold       | BIGINT                  |
| profile    | JSONB / JSON            |
| created_at | TIMESTAMPTZ / DATETIME  |

### 场景

3 个玩家同时 flush，各自脏字段不同（含 NULL 写入）：

```erlang
[
    {#{table_name => players, id => 1001, level => 50,   gold => 99999, profile => null},
     [level, gold, profile],
     [{id, 1001}]},

    {#{table_name => players, id => 1002, gold => 0,     created_at => <<"2026-05-23 10:00:00">>},
     [gold, created_at],
     [{id, 1002}]},

    {#{table_name => players, id => 1003, level => null, profile => #{vip => true, title => <<"GM">>}},
     [level, profile],
     [{id, 1003}]}
]
```

> `patch_union_fields` 遍历三行的 `SetCols`，得到全字段并集：`[level, gold, profile, created_at]`。
> 每行 1 + 2×4 = **9** 个参数：`id, level_set, level, gold_set, gold, profile_set, profile, created_at_set, created_at`。

### 每行参数绑定

| id   | level_set | level | gold_set | gold  | profile_set | profile                     | created_at_set | created_at            |
|------|-----------|-------|----------|-------|-------------|-----------------------------|----------------|-----------------------|
| 1001 | true      | 50    | true     | 99999 | true        | null                        | false          | null                  |
| 1002 | false     | null  | true     | 0     | false       | null                        | true           | "2026-05-23 10:00:00" |
| 1003 | true      | null  | false    | null  | true        | `{"vip":true,"title":"GM"}` | false          | null                  |

> PG 参数：`true`/`false` 为 Erlang atom（epgsql 支持 boolean 绑定）。
> MySQL 参数：`1`/`0` 整数代替 `true`/`false`。

---

### PostgreSQL（ePgdb）

```sql
UPDATE "players" AS t
SET
    t."level"      = CASE WHEN v."level_set"      THEN v."level"      ELSE t."level"      END,
    t."gold"       = CASE WHEN v."gold_set"       THEN v."gold"       ELSE t."gold"       END,
    t."profile"    = CASE WHEN v."profile_set"    THEN v."profile"    ELSE t."profile"    END,
    t."created_at" = CASE WHEN v."created_at_set" THEN v."created_at" ELSE t."created_at" END
FROM (
    VALUES
        ($1,  $2,  $3,  $4,  $5,     $6,  $7,     $8,  $9     ),
        ($10, $11, $12, $13, $14,    $15, $16,    $17, $18    ),
        ($19, $20, $21, $22, $23,    $24, $25,    $26, $27    )
) AS v(
    "id",
    "level_set",      "level",
    "gold_set",       "gold",
    "profile_set",    "profile",
    "created_at_set", "created_at"
)
WHERE t."id" = v."id";
```

参数绑定：

| 占位符 | 值     | 占位符 | 值                     | 占位符 | 值                           |
|-----|-------|-----|-----------------------|-----|-----------------------------|
| $1  | 1001  | $10 | 1002                  | $19 | 1003                        |
| $2  | true  | $11 | false                 | $20 | true                        |
| $3  | 50    | $12 | null                  | $21 | null                        |
| $4  | true  | $13 | true                  | $22 | false                       |
| $5  | 99999 | $14 | 0                     | $23 | null                        |
| $6  | true  | $15 | false                 | $24 | true                        |
| $7  | null  | $16 | null                  | $25 | `{"vip":true,"title":"GM"}` |
| $8  | false | $17 | true                  | $26 | false                       |
| $9  | null  | $18 | "2026-05-23 10:00:00" | $27 | null                        |

**更新结果：**

| id   | level    | gold      | profile                         | created_at                |
|------|----------|-----------|---------------------------------|---------------------------|
| 1001 | **50**   | **99999** | **null**                        | *(不变)*                    |
| 1002 | *(不变)*   | **0**     | *(不变)*                          | **"2026-05-23 10:00:00"** |
| 1003 | **null** | *(不变)*    | **`{"vip":true,"title":"GM"}`** | *(不变)*                    |

---

### MySQL（eMysql）

```sql
UPDATE `players` AS t
INNER JOIN (
    SELECT
        ? AS `id`,
        ? AS `level_set`,      ? AS `level`,
        ? AS `gold_set`,       ? AS `gold`,
        ? AS `profile_set`,    ? AS `profile`,
        ? AS `created_at_set`, ? AS `created_at`
    UNION ALL
    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
    UNION ALL
    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
) AS v ON t.`id` = v.`id`
SET
    t.`level`      = CASE WHEN v.`level_set`      THEN v.`level`      ELSE t.`level`      END,
    t.`gold`       = CASE WHEN v.`gold_set`       THEN v.`gold`       ELSE t.`gold`       END,
    t.`profile`    = CASE WHEN v.`profile_set`    THEN v.`profile`    ELSE t.`profile`    END,
    t.`created_at` = CASE WHEN v.`created_at_set` THEN v.`created_at` ELSE t.`created_at` END;
```

参数绑定（按 `SELECT` / `UNION ALL` 顺序）：

| 行  | id   | level_set | level | gold_set | gold  | profile_set | profile                     | created_at_set | created_at            |
|----|------|-----------|-------|----------|-------|-------------|-----------------------------|----------------|-----------------------|
| R1 | 1001 | 1         | 50    | 1        | 99999 | 1           | null                        | 0              | null                  |
| R2 | 1002 | 0         | null  | 1        | 0     | 0           | null                        | 1              | "2026-05-23 10:00:00" |
| R3 | 1003 | 1         | null  | 0        | null  | 1           | `{"vip":true,"title":"GM"}` | 0              | null                  |

> `_set` 列用 `1`/`0`，MySQL 的 `CASE WHEN` 将非零值视为真。

**更新结果：** 同上表。

---

### 代码调用路径回顾

```
csTabSrv: DbMod:batchUpdate([{LDataWithTableName, DirtyMask, [{PkField, Key}]}, ...])
  → buildTableBatchItems / encodeBatchPatchFields / encodeBatchKey
  → pgdbQuery:buildBatchUpdate / mysqlQuery:buildBatchUpdate
  → equery(SQL, Params)   -- 单条 patch SQL
```