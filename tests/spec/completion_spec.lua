-- tests/spec/completion_spec.lua: unit tests for completion.lua
-- TDD: written before the implementation. All tests start RED.
dofile("tests/minimal_init.lua")

local completion = require("dadbod-grip.completion")
local db = require("dadbod-grip.db")

local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg or "eq", tostring(b), tostring(a)))
  end
end

local function ok(v, msg)
  if v then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. (msg or "expected truthy, got nil/false"))
  end
end

local function not_nil(v, msg)
  if v ~= nil then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. (msg or "expected non-nil, got nil"))
  end
end

-- ── parse_context (pure function, no mocks needed) ────────────────────────────

-- Helper: parse_context receives the text before the cursor.
-- Returns { type, word, qualifier?, alias?, table? } or nil.
local pc = completion.parse_context

-- Table context: after FROM / JOIN / UPDATE / INSERT INTO
eq(pc("SELECT * FROM "), "table",  "FROM: table context type")
eq(pc("SELECT * FROM use"), "table", "FROM partial word: table context")
eq(pc("select * from "), "table",  "FROM lowercase: table context")
eq(pc("JOIN "), "table",           "JOIN: table context")
eq(pc("LEFT JOIN "), "table",      "LEFT JOIN: table context")
eq(pc("INNER JOIN "), "table",     "INNER JOIN: table context")
eq(pc("UPDATE "), "table",         "UPDATE: table context")
eq(pc("INSERT INTO "), "table",    "INSERT INTO: table context")

-- Column context: after SELECT / WHERE / ORDER BY / GROUP BY / HAVING
eq(pc("SELECT "), "column",        "SELECT: column context")
eq(pc("SELECT id, "), "column",    "SELECT after comma: column context")
eq(pc("WHERE "), "column",         "WHERE: column context")
eq(pc("ORDER BY "), "column",      "ORDER BY: column context")
eq(pc("GROUP BY "), "column",      "GROUP BY: column context")
eq(pc("HAVING "), "column",        "HAVING: column context")
eq(pc("select "), "column",        "select lowercase: column context")

-- Dotted context: after qualifier. (table or attachment)
local ctx = completion.parse_context_full("SELECT s.")
not_nil(ctx, "dotted SELECT s.: non-nil")
eq(ctx and ctx.type, "dotted",           "dotted: type")
eq(ctx and ctx.qualifier, "s",           "dotted: qualifier")
eq(ctx and ctx.word, "",                 "dotted: empty word")

ctx = completion.parse_context_full("FROM supplier.")
not_nil(ctx, "dotted FROM supplier.: non-nil")
eq(ctx and ctx.type, "dotted",           "dotted FROM: type")
eq(ctx and ctx.qualifier, "supplier",    "dotted FROM: qualifier")

ctx = completion.parse_context_full("FROM supplier.shi")
not_nil(ctx, "dotted partial word: non-nil")
eq(ctx and ctx.type, "dotted",           "dotted partial: type")
eq(ctx and ctx.qualifier, "supplier",    "dotted partial: qualifier")
eq(ctx and ctx.word, "shi",              "dotted partial: word")

ctx = completion.parse_context_full("JOIN main.")
eq(ctx and ctx.type, "dotted",           "dotted JOIN main.: type")
eq(ctx and ctx.qualifier, "main",        "dotted JOIN main.: qualifier")

-- Federation column context: after alias.table. (three-part)
ctx = completion.parse_context_full("WHERE supplier.shipments.")
not_nil(ctx, "fed_column WHERE supplier.shipments.: non-nil")
eq(ctx and ctx.type, "fed_column",            "fed_column: type")
eq(ctx and ctx.alias, "supplier",             "fed_column: alias")
eq(ctx and ctx.table, "shipments",            "fed_column: table")
eq(ctx and ctx.word, "",                      "fed_column: empty word")

ctx = completion.parse_context_full("ORDER BY supplier.shipments.col")
eq(ctx and ctx.type, "fed_column",            "fed_column ORDER BY: type")
eq(ctx and ctx.alias, "supplier",             "fed_column ORDER BY: alias")
eq(ctx and ctx.table, "shipments",            "fed_column ORDER BY: table")
eq(ctx and ctx.word, "col",                   "fed_column ORDER BY: partial word")

ctx = completion.parse_context_full("SELECT s.shipments.dec")
eq(ctx and ctx.type, "fed_column",            "fed_column SELECT: type")
eq(ctx and ctx.alias, "s",                    "fed_column SELECT: alias")
eq(ctx and ctx.table, "shipments",            "fed_column SELECT: table")
eq(ctx and ctx.word, "dec",                   "fed_column SELECT: word")

-- Nil: no recognizable context
eq(completion.parse_context(""), nil,         "empty string: nil")
eq(completion.parse_context("--"), nil,       "comment: nil")

-- ── Schema cache + completion items ──────────────────────────────────────────
-- Mock db.list_tables and db.get_column_info to avoid real DB calls.

local function mock_db(tables_by_name)
  local orig_list  = db.list_tables
  local orig_cols  = db.get_column_info
  local orig_batch = db.get_schema_batch

  -- Return nil from batch so tests exercise the per-table fallback path
  -- (avoids real DuckDB CLI invocations in unit tests).
  db.get_schema_batch = function(url) return nil end

  db.list_tables = function(url)
    local result = {}
    for name, _ in pairs(tables_by_name) do
      table.insert(result, { name = name })
    end
    return result, nil
  end

  db.get_column_info = function(table_name, url)
    return tables_by_name[table_name] or {}, nil
  end

  return function()
    db.list_tables      = orig_list
    db.get_column_info  = orig_cols
    db.get_schema_batch = orig_batch
  end
end

local PG_URL   = "postgresql://localhost/test"
local MYSQL_URL = "mysql://root:pass@localhost/testdb"
local SQLITE_URL = "sqlite:test.db"
local DUCK_URL  = "duckdb:test.duckdb"

local USERS_COLS = {
  { column_name = "id",    data_type = "integer",  is_nullable = "NO"  },
  { column_name = "email", data_type = "text",     is_nullable = "NO"  },
  { column_name = "name",  data_type = "text",     is_nullable = "YES" },
}
local ORDERS_COLS = {
  { column_name = "id",       data_type = "integer", is_nullable = "NO"  },
  { column_name = "user_id",  data_type = "integer", is_nullable = "NO"  },
  { column_name = "total",    data_type = "numeric", is_nullable = "YES" },
}

-- Postgres: table completions
do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  local items = completion.complete("SELECT * FROM ", PG_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["users"],  "pg: users in table completions")
  ok(names["orders"], "pg: orders in table completions")
  restore()
end

-- Postgres: column completions (returns all known columns from all tables)
do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  local items = completion.complete("SELECT ", PG_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["id"],      "pg: id in column completions")
  ok(names["email"],   "pg: email in column completions")
  ok(names["user_id"], "pg: user_id in column completions")
  ok(names["total"],   "pg: total in column completions")
  restore()
end

-- MySQL: same contract, different URL
do
  local restore = mock_db({ customers = {
    { column_name = "cust_id", data_type = "int", is_nullable = "NO" },
    { column_name = "region",  data_type = "varchar", is_nullable = "YES" },
  }})
  completion.invalidate(MYSQL_URL)
  local items = completion.complete("FROM ", MYSQL_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["customers"], "mysql: customers in table completions")
  restore()
end

-- SQLite: PRAGMA-style column info (same field names)
do
  local restore = mock_db({ products = {
    { column_name = "sku",   data_type = "TEXT",    is_nullable = "YES" },
    { column_name = "price", data_type = "REAL",    is_nullable = "YES" },
  }})
  completion.invalidate(SQLITE_URL)
  local items = completion.complete("SELECT ", SQLITE_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["sku"],   "sqlite: sku in column completions")
  ok(names["price"], "sqlite: price in column completions")
  restore()
end

-- DuckDB single-DB: table completion
do
  local restore = mock_db({ shipments = {
    { column_name = "ship_date",        data_type = "DATE",    is_nullable = "NO"  },
    { column_name = "declared_contents",data_type = "VARCHAR", is_nullable = "YES" },
  }})
  completion.invalidate(DUCK_URL)
  local items = completion.complete("FROM ", DUCK_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["shipments"], "duckdb: shipments in table completions")
  restore()
end

-- ── Cache invalidation ────────────────────────────────────────────────────────

do
  local call_count = 0
  local orig_list = db.list_tables
  local orig_cols = db.get_column_info

  db.list_tables = function(url)
    call_count = call_count + 1
    return { { name = "t" } }, nil
  end
  db.get_column_info = function(tn, url)
    return { { column_name = "id", data_type = "integer", is_nullable = "NO" } }, nil
  end

  local url = "postgresql://localhost/cache_test"
  completion.invalidate(url)
  completion.complete("FROM ", url)
  completion.complete("FROM ", url)  -- second call: should use cache
  eq(call_count, 1, "cache: list_tables called only once on second complete")

  completion.invalidate(url)
  completion.complete("FROM ", url)
  eq(call_count, 2, "cache: list_tables called again after invalidate")

  db.list_tables = orig_list
  db.get_column_info = orig_cols
end

-- ── Dotted qualifier: column completion from named table ──────────────────────

do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  -- "FROM users u SELECT u." -> columns of users
  local items = completion.complete("SELECT u.", PG_URL, { ["u"] = "users" })
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["id"],    "dotted: u.id from users alias")
  ok(names["email"], "dotted: u.email from users alias")
  restore()
end

-- ── Completion item structure ─────────────────────────────────────────────────

do
  local restore = mock_db({ users = USERS_COLS })
  completion.invalidate(PG_URL)
  local items = completion.complete("FROM ", PG_URL)
  local first = items[1]
  not_nil(first,            "item exists")
  not_nil(first.word,       "item has word")
  not_nil(first.menu,       "item has menu annotation")
  restore()
end

-- ── extract_aliases ───────────────────────────────────────────────────────────

local ea = completion.extract_aliases

-- FROM table alias (no AS)
do
  local a = ea("SELECT * FROM employees e WHERE e.id = 1")
  eq(a["e"], "employees", "extract: FROM table alias")
end

-- FROM table AS alias
do
  local a = ea("SELECT * FROM employees AS e")
  eq(a["e"], "employees", "extract: FROM table AS alias")
end

-- UPDATE targets participate in dotted completion with or without AS.
for _, sql_text in ipairs({
  "UPDATE orders o SET total = 1 WHERE o.",
  "update orders o set total = 1 where o.",
  "UPDATE\norders\no\nSET total = 1 WHERE o.",
  'UPDATE "orders" o SET total = 1 WHERE o.',
  "UPDATE `orders` o SET total = 1 WHERE o.",
  "UPDATE orders AS o SET total = 1 WHERE o.",
  "DELETE FROM orders o WHERE o.",
  "DELETE o FROM orders o WHERE o.",
}) do
  eq(ea(sql_text)["o"], "orders", "extract: mutation target alias in " .. sql_text)
end
eq(next(ea("UPDATE orders SET total = 1")), nil, "extract: UPDATE SET is not an alias")
eq(next(ea("SELECT last_update orders o")), nil, "extract: UPDATE inside an identifier is ignored")
eq(next(ea("SELECT x$UPDATE orders o")), nil, "extract: UPDATE after identifier dollar is ignored")
eq(next(ea("SELECT 名UPDATE orders o")), nil, "extract: UPDATE after Unicode identifier is ignored")
eq(ea("UPDATE orders o SET total = 1; UPDATE users u SET name = 'x'")["u"],
  "users", "extract: UPDATE alias in a later statement")

do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  local sql_text = "UPDATE orders o SET total = 1 WHERE o."
  local items = completion.complete(sql_text, PG_URL, ea(sql_text))
  local names = {}
  for _, item in ipairs(items) do names[item.word] = true end
  ok(names["total"], "UPDATE alias+complete: target column total")
  ok(names["user_id"], "UPDATE alias+complete: target column user_id")
  eq(names["email"], nil, "UPDATE alias+complete: no unrelated table columns")
  restore()
end

-- JOIN table alias
do
  local a = ea("FROM orders o JOIN employees e ON o.emp_id = e.id")
  eq(a["o"], "orders",    "extract: JOIN o=orders")
  eq(a["e"], "employees", "extract: JOIN e=employees")
end

-- Multi-join: FROM + two JOINs
do
  local a = ea("SELECT * FROM orders o JOIN employees e ON e.id = o.emp_id JOIN departments d ON d.id = e.dept_id")
  eq(a["o"], "orders",      "extract: multi o=orders")
  eq(a["e"], "employees",   "extract: multi e=employees")
  eq(a["d"], "departments", "extract: multi d=departments")
end

-- SQL keyword as alias is skipped (FROM employees WHERE)
do
  local a = ea("SELECT * FROM employees WHERE id = 1")
  eq(a["where"], nil, "extract: WHERE is not an alias")
end

-- No aliases in a plain single-table query
do
  local a = ea("SELECT id, name FROM employees")
  eq(next(a), nil, "extract: no aliases in simple query")
end

-- AS form wins over bare form for the same alias key
do
  local a = ea("FROM employees AS e JOIN employees e ON true")
  eq(a["e"], "employees", "extract: AS form preserved")
end

-- Alias tracking integrates with complete() via dotted context
do
  local restore = mock_db({ employees = {
    { column_name = "emp_id",   data_type = "integer", is_nullable = "NO"  },
    { column_name = "emp_name", data_type = "text",    is_nullable = "YES" },
  }})
  completion.invalidate(PG_URL)
  -- full_sql contains the alias declaration; before-cursor is the dotted access
  local full_sql = "SELECT e.emp_name FROM employees e WHERE e."
  local aliases  = ea(full_sql)
  local items    = completion.complete("SELECT e.", PG_URL, aliases)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["emp_id"],   "alias+complete: emp_id via alias e")
  ok(names["emp_name"], "alias+complete: emp_name via alias e")
  restore()
end

-- ── DuckDB federation: dotted cache prefix scan ───────────────────────────────
-- When the schema cache has "supplier.shipments" keys, typing "supplier." or
-- "supplier.sh" should return tables from cache without a live query.
do
  local FED_URL = "duckdb:softrear.duckdb"
  local SHIP_COLS = {
    { column_name = "ship_id",   data_type = "integer", is_nullable = "NO"  },
    { column_name = "ship_date", data_type = "date",    is_nullable = "NO"  },
  }
  local ORD_COLS = {
    { column_name = "order_id",  data_type = "integer", is_nullable = "NO"  },
    { column_name = "amount",    data_type = "numeric",  is_nullable = "YES" },
  }
  -- Mock the schema cache with federation-prefixed keys
  local restore = mock_db({
    ["supplier.shipments"] = SHIP_COLS,
    ["supplier.orders"]    = ORD_COLS,
    ["main_table"]         = { { column_name = "id", data_type = "integer", is_nullable = "NO" } },
  })
  completion.invalidate(FED_URL)

  -- "supplier." -> should complete tables from cache
  local items = completion.complete("FROM supplier.", FED_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["shipments"],  "fed dotted: shipments from cache")
  ok(names["orders"],     "fed dotted: orders from cache")
  ok(not names["main_table"], "fed dotted: main_table not included")

  -- "supplier.sh" -> prefix filter applies
  items = completion.complete("FROM supplier.sh", FED_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["shipments"],  "fed dotted partial: shipments matches 'sh'")
  ok(not names["orders"], "fed dotted partial: orders doesn't match 'sh'")

  restore()
end

-- ── DuckDB federation: fed_column cache lookup ────────────────────────────────
-- When the schema cache has "supplier.shipments" column data, typing
-- "supplier.shipments." should return columns from cache, not a live query.
do
  local FED_URL = "duckdb:softrear.duckdb"
  local SHIP_COLS = {
    { column_name = "ship_id",   data_type = "integer", is_nullable = "NO"  },
    { column_name = "ship_date", data_type = "date",    is_nullable = "NO"  },
    { column_name = "declared",  data_type = "varchar",  is_nullable = "YES" },
  }
  local restore = mock_db({ ["supplier.shipments"] = SHIP_COLS })
  completion.invalidate(FED_URL)

  -- "supplier.shipments." -> columns from cache
  local items = completion.complete("WHERE supplier.shipments.", FED_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["ship_id"],   "fed_column cache: ship_id")
  ok(names["ship_date"], "fed_column cache: ship_date")
  ok(names["declared"],  "fed_column cache: declared")

  -- "supplier.shipments.sh" -> prefix filter
  items = completion.complete("WHERE supplier.shipments.sh", FED_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["ship_id"],     "fed_column prefix: ship_id matches 'sh'")
  ok(names["ship_date"],   "fed_column prefix: ship_date matches 'sh'")
  ok(not names["declared"], "fed_column prefix: declared doesn't match 'sh'")

  restore()
end

-- ── Auto-trigger: dotted context guard ───────────────────────────────────────
-- parse_context("supplier.") should return "dotted" so the auto-trigger
-- detects dotted context even when word == "".
do
  local guard_ctx = completion.parse_context_full("FROM supplier.")
  eq(guard_ctx and guard_ctx.type, "dotted", "auto-trigger guard: dotted context detected after '.'")
  eq(guard_ctx and guard_ctx.qualifier, "supplier", "auto-trigger guard: qualifier is 'supplier'")
  eq(guard_ctx and guard_ctx.word, "", "auto-trigger guard: word is empty after '.'")

  -- The autotrigger's own guard (completion.lua:532) tests the same thing with
  -- the pattern parse_context holds at line 197, so assert through that function.
  -- Re-matching the pattern in the test body, as this used to, only asserts that
  -- string.match works: it stays green however the plugin's copies drift.
  eq(completion.parse_context("FROM supplier."), "dotted",
    "auto-trigger guard: 'supplier.' reads as dotted, so word == '' must not bail out")
  eq(completion.parse_context("FROM "), "table",
    "auto-trigger guard: a plain FROM is not dotted, so word == '' does bail out")
end

-- ── DuckDB federation: live-query fallback for SQLite attachments ─────────────
-- When the schema cache is empty (e.g. first keystroke after GripAttach before
-- get_schema has populated it), the dotted handler falls to a live query.
-- The OLD fallback used b.information_schema.tables which fails for SQLite.
-- The NEW fallback must use duckdb_tables() WHERE database_name = 'b' instead.
do
  local ATT_URL = "duckdb:" .. vim.fn.tempname() .. "_attach_fallback_test.duckdb"
  local duckdb_adapter = require("dadbod-grip.adapters.duckdb")

  -- Register "b" as a SQLite attachment (no real DuckDB needed for this test)
  duckdb_adapter._attach_unchecked(ATT_URL, "sqlite:/tmp/test_butts.db", "b")

  -- Force cache miss: list_tables returns empty so "b.butts" is NOT in schema cache
  local orig_list  = db.list_tables
  local orig_cols  = db.get_column_info
  local orig_query = db.query
  local orig_batch = db.get_schema_batch

  db.list_tables     = function(url) return {}, nil end
  db.get_column_info = function(tn, url) return {}, nil end
  db.get_schema_batch = function(url) return nil end

  -- Mock db.query to simulate responses:
  -- information_schema → fails (SQLite has no information_schema)
  -- duckdb_tables()    → returns the "butts" table (correct fallback)
  db.query = function(sql, url)
    if sql:find("information_schema") then
      return nil, "Catalog Error: b.information_schema does not exist"
    end
    if sql:find("duckdb_tables") and sql:find("database_name") then
      return { rows = { {"butts"} }, columns = {"table_name"} }, nil
    end
    return nil, "unexpected query in test: " .. tostring(sql)
  end

  completion.invalidate(ATT_URL)
  local items = completion.complete("SELECT b.", ATT_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  -- This assertion drives the fix: "butts" must appear even when
  -- the schema cache is cold and the live fallback must run.
  ok(names["butts"],
     "attached SQLite alias 'b': 'butts' appears in 'SELECT b.' via live fallback")

  -- Cleanup
  duckdb_adapter.detach(ATT_URL, "b")
  db.list_tables      = orig_list
  db.get_column_info  = orig_cols
  db.query            = orig_query
  db.get_schema_batch = orig_batch
end


-- ── DuckDB federation: fed_column fallback for SQLite attachments ─────────────
-- Three-part "b.butts.col" when schema cache is cold should use duckdb_columns(),
-- not b.information_schema.columns (SQLite has no information_schema).
do
  local ATT2_URL = "duckdb:" .. vim.fn.tempname() .. "_fed_col_fallback_test.duckdb"
  local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
  duckdb_adapter._attach_unchecked(ATT2_URL, "sqlite:/tmp/test_butts2.db", "b")

  local orig_list  = db.list_tables
  local orig_cols  = db.get_column_info
  local orig_query = db.query
  local orig_batch = db.get_schema_batch

  db.list_tables      = function(url) return {}, nil end
  db.get_column_info  = function(tn, url) return {}, nil end
  db.get_schema_batch = function(url) return nil end

  db.query = function(sql, url)
    if sql:find("information_schema") then
      return nil, "Catalog Error: b.information_schema does not exist"
    end
    if sql:find("duckdb_columns") and sql:find("database_name") then
      return { rows = { {"id", "INTEGER"}, {"weight", "DOUBLE"} }, columns = {"column_name","data_type"} }, nil
    end
    return nil, "unexpected query: " .. tostring(sql)
  end

  completion.invalidate(ATT2_URL)
  local items = completion.complete("SELECT b.butts.", ATT2_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["id"],     "fed_column SQLite fallback: 'id' column via duckdb_columns()")
  ok(names["weight"], "fed_column SQLite fallback: 'weight' column via duckdb_columns()")

  duckdb_adapter.detach(ATT2_URL, "b")
  db.list_tables      = orig_list
  db.get_column_info  = orig_cols
  db.query            = orig_query
  db.get_schema_batch = orig_batch
end

-- ── table context: bare-name match for federated schema keys ─────────────────
-- Typing "FROM bu" with schema {"grip_test.butts": {}} must suggest "grip_test.butts".
-- The table part "butts" starts with "bu" even though the full key "grip_test.butts" does not.
do
  local FED_TABLE_URL = "duckdb:fed_table_match_test.duckdb"

  local orig_batch = db.get_schema_batch
  -- Schema has a federated table and a plain main-DB table
  db.get_schema_batch = function(url)
    return {
      ["grip_test.butts"] = {},
      ["users"] = {
        { column_name = "id", data_type = "integer", is_nullable = "NO" },
      },
    }
  end

  completion.invalidate(FED_TABLE_URL)

  -- "FROM bu" → bare-name match: "butts" in "grip_test.butts" starts with "bu"
  local items = completion.complete("SELECT * FROM bu", FED_TABLE_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["grip_test.butts"], "table bare-name match: 'FROM bu' finds 'grip_test.butts'")
  ok(not names["users"],       "table bare-name match: 'FROM bu' does not find 'users'")

  -- "FROM us" → direct prefix match: "users" starts with "us"
  items = completion.complete("SELECT * FROM us", FED_TABLE_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["users"],               "table direct match: 'FROM us' finds 'users'")
  ok(not names["grip_test.butts"], "table direct match: 'FROM us' does not find 'grip_test.butts'")

  -- "FROM " (empty word) → all tables, no double-add from bare match
  items = completion.complete("SELECT * FROM ", FED_TABLE_URL, {})
  local counts = {}
  for _, it in ipairs(items) do counts[it.word] = (counts[it.word] or 0) + 1 end
  ok(counts["grip_test.butts"] == 1, "table empty word: 'grip_test.butts' appears exactly once")
  ok(counts["users"] == 1,           "table empty word: 'users' appears exactly once")

  db.get_schema_batch = orig_batch
end

-- ── fed_column: empty cached_cols must fire live fallback ─────────────────────
-- When get_schema_batch returns table-names-only {"b.butts" -> {}}, typing
-- "b.butts." must still return columns via the live duckdb_columns() fallback.
-- Lua's empty-table truthiness makes {} truthy, so "if cached_cols then" is
-- the bug: it enters the cache branch, iterates zero rows, and returns nothing.
-- Fix: "if cached_cols and #cached_cols > 0 then" correctly falls through.
do
  local BATCH_URL = "duckdb:batch_empty_cols_test.duckdb"

  local orig_batch = db.get_schema_batch
  local orig_query = db.query

  -- Simulate table-names-only batch: key exists but column array is empty
  db.get_schema_batch = function(url) return { ["b.butts"] = {} } end

  -- Live fallback must be called and return columns
  db.query = function(sql, url)
    if sql:find("duckdb_columns") then
      return { rows = { {"id", "INTEGER"}, {"weight", "DOUBLE"} }, columns = {"column_name","data_type"} }, nil
    end
    return nil, "unexpected query: " .. tostring(sql)
  end

  completion.invalidate(BATCH_URL)
  local items = completion.complete("SELECT b.butts.", BATCH_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["id"],     "fed_column empty-cache live fallback: 'id' column appears")
  ok(names["weight"], "fed_column empty-cache live fallback: 'weight' column appears")

  db.get_schema_batch = orig_batch
  db.query            = orig_query
end

-- ── dotted: table-names-only batch still surfaces table names for alias. ───────
-- When get_schema_batch returns {"b.butts": {}, "b.orders": {}}, typing "b."
-- must still show "butts" and "orders" via the cache prefix scan. The scan
-- iterates schema keys (not values), so empty column arrays don't matter here.
do
  local BATCH2_URL = "duckdb:batch_dotted_test.duckdb"

  local orig_batch = db.get_schema_batch
  db.get_schema_batch = function(url) return { ["b.butts"] = {}, ["b.orders"] = {} } end

  completion.invalidate(BATCH2_URL)
  local items = completion.complete("SELECT b.", BATCH2_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["butts"],  "dotted names-only batch: 'butts' appears for 'b.'")
  ok(names["orders"], "dotted names-only batch: 'orders' appears for 'b.'")

  db.get_schema_batch = orig_batch
end

-- ── column context: main DB columns must survive when attachments exist ───────
-- Regression guard: when get_schema_batch returns a CORRECT mixed result
-- (main DB table has columns, attached table is names-only), SELECT b must
-- surface main DB column completions. If batch incorrectly returns all-empty,
-- no columns are found and only keywords like BETWEEN appear.
do
  local MIXED_URL = "duckdb:mixed_batch_col_test.duckdb"
  local orig_batch = db.get_schema_batch

  -- Simulate the CORRECT mixed-batch output that the fixed get_schema_batch must return:
  -- main DB table "employees" has full column info;
  -- attached catalog table "grip_test.butts" is names-only (empty array).
  db.get_schema_batch = function(url)
    return {
      ["employees"] = {
        { column_name = "budget",      data_type = "DECIMAL" },
        { column_name = "name",        data_type = "TEXT" },
        { column_name = "bonus_pct",   data_type = "REAL" },
      },
      ["grip_test.butts"] = {},
    }
  end

  completion.invalidate(MIXED_URL)

  -- SELECT b → column context: must find "budget" and "bonus_pct" from employees
  local items = completion.complete("SELECT b", MIXED_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["budget"],    "mixed batch col ctx: 'budget' column appears for SELECT b")
  ok(names["bonus_pct"], "mixed batch col ctx: 'bonus_pct' column appears for SELECT b")
  -- If the regression were present (all-empty batch), names would be empty here
  -- and only keyword "BETWEEN" would appear via the keyword fallback.

  -- SELECT n → must find "name"
  items = completion.complete("SELECT n", MIXED_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["name"], "mixed batch col ctx: 'name' column appears for SELECT n")

  db.get_schema_batch = orig_batch
end

-- ── warm_schema: populates cache so columns are available before first keypress ──
do
  local WARM_URL = "duckdb:warm_schema_test.duckdb"
  local orig_batch_async = db.get_schema_batch_async

  local async_called = false
  db.get_schema_batch_async = function(url, callback)
    async_called = true
    -- Simulate async result arriving synchronously for test purposes
    callback({
      ["warm_table"] = {
        { column_name = "warm_col", data_type = "TEXT" },
      },
    })
  end

  completion.invalidate(WARM_URL)
  completion.warm_schema(WARM_URL)

  ok(async_called, "warm_schema: calls get_schema_batch_async")

  -- After warm_schema, SELECT w must find warm_col (cache is populated)
  local items = completion.complete("SELECT w", WARM_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["warm_col"], "warm_schema: column available after pre-warm")

  db.get_schema_batch_async = orig_batch_async
end

-- ── alias cache: keyed by (bufnr, changedtick) ────────────────────────────────
-- extract_aliases used to run on every keystroke via table.concat(all_lines).
-- M._get_cached_aliases must only re-run it when the buffer's changedtick moves.

do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT * FROM employees e" })

  local call_count = 0
  local orig_extract = completion.extract_aliases
  completion.extract_aliases = function(sql)
    call_count = call_count + 1
    return orig_extract(sql)
  end

  completion._alias_cache[bufnr] = nil  -- start from a clean slate for this bufnr

  local a1 = completion._get_cached_aliases(bufnr)
  local a2 = completion._get_cached_aliases(bufnr)
  eq(call_count, 1, "alias cache: unchanged buffer does not re-parse on second call")
  eq(a1["e"], "employees", "alias cache: first call parses the alias")
  eq(a2["e"], "employees", "alias cache: cached call returns the same alias")

  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "JOIN departments d ON d.id = e.dept_id" })
  local a3 = completion._get_cached_aliases(bufnr)
  eq(call_count, 2, "alias cache: buffer edit bumps changedtick and forces a re-parse")
  eq(a3["e"], "employees", "alias cache: re-parse keeps the earlier alias")
  eq(a3["d"], "departments", "alias cache: re-parse picks up the new alias")

  completion.extract_aliases = orig_extract
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── alias cache: cleared on buffer wipeout ────────────────────────────────────

do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT * FROM employees e" })

  completion._get_cached_aliases(bufnr)
  not_nil(completion._alias_cache[bufnr], "alias cache: entry present before wipeout")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  eq(completion._alias_cache[bufnr], nil, "alias cache: entry cleared after BufWipeout/BufDelete")
end

-- Mutation aliases are parsed as SQL tokens, including quoted names/comments.
for _, sql_text in ipairs({
  "UPDATE orders /* target */ AS o SET total=1 WHERE o.",
  "UPDATE orders -- target\n o SET total=1 WHERE o.",
  'UPDATE "orders" AS "o" SET total=1 WHERE o.',
  "DELETE FROM orders AS o WHERE o.",
  "INSERT INTO orders AS o (id,total) VALUES (1,2) ON CONFLICT(id) DO UPDATE SET total=excluded.total WHERE o.",
  "REPLACE INTO orders AS o (id,total) VALUES (1,2)",
  "INSERT OR REPLACE INTO orders AS o (id,total) VALUES (1,2)",
}) do
  eq(ea(sql_text)["o"], "orders", "extract tokenized target: " .. sql_text)
end
for _, sql_text in ipairs({
  "SELECT 'FROM orders fake'",
  "SELECT 1 -- FROM orders fake",
  "SELECT 1 /* UPDATE orders fake SET total=1 */",
  "SELECT total AS fake FROM orders",
  "INSERT INTO orders(id,total) VALUES(1,2) ON CONFLICT(id) DO UPDATE SET total=excluded.total",
  "INSERT INTO orders(id,total) VALUES(1,2) ON DUPLICATE KEY UPDATE total=1",
}) do
  eq(next(ea(sql_text)), nil, "extract ignores fake source: " .. sql_text)
end
eq(ea("UPDATE orders o SET total=1 # FROM users fake\n WHERE o.", "mysql")["fake"], nil,
  "extract ignores MySQL hash comments")
eq(ea("UPDATE orders /* nested /* fake */ still comment */ o SET total=1", "postgresql")["o"],
  "orders", "extract PostgreSQL nested target comments")
eq(ea("UPDATE orders o SET total=$q$ FROM users fake $q$ WHERE o.", "postgresql")["fake"], nil,
  "extract ignores PostgreSQL dollar strings")
eq(next(ea("UPDATE orders /*! AS fake */ SET total=1", "mysql")), nil,
  "extract refuses executable MySQL comments")
eq(ea("UPDATE orders o SET total='unfinished FROM users fake").fake, nil,
  "extract does not interpret an unfinished string")
eq(ea('INSERT INTO "Mixed"."Orders" AS "O" (id) VALUES(1)', "postgresql")["O"],
  "Mixed.Orders", "extract preserves quoted PostgreSQL source and alias case")
eq(ea("SELECT * FROM employees AS e JOIN orders e ON true")["e"], "employees",
  "explicit alias keeps precedence over a later bare alias")

do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(MYSQL_URL)
  local function complete_names(sql_text, before, kind)
    local names, menus = {}, {}
    for _, entry in ipairs(completion.complete(before, MYSQL_URL, ea(sql_text, kind))) do
      names[entry.word], menus[entry.word] = true, entry.menu
    end
    return names, menus
  end
  local names = complete_names(
    "INSERT INTO orders(id,total) VALUES(1,2) AS new ON DUPLICATE KEY UPDATE total=new.total",
    "ON DUPLICATE KEY UPDATE total=new.", "mysql")
  ok(names.total and names.id, "MySQL row alias completes target columns")
  eq(names.email, nil, "MySQL row alias excludes unrelated columns")

  local sql_text = "INSERT INTO orders(total,id) VALUES(2,1),(3,2) AS new(amount,key_id)"
    .. " ON DUPLICATE KEY UPDATE total=new.amount"
  local menus
  names, menus = complete_names(sql_text, "ON DUPLICATE KEY UPDATE total=new.", "mysql")
  ok(names.amount and names.key_id, "MySQL row alias exposes renamed columns")
  eq(names.total, nil, "MySQL renamed column hides original name")
  eq(menus.amount, "[numeric]", "MySQL alias type follows explicit INSERT column order")
  eq(menus.key_id, "[integer]", "MySQL second alias follows explicit INSERT column order")

  names, menus = complete_names(
    "INSERT INTO orders SET total=COALESCE(2,3),id=1 AS new(amount,key_id)"
      .. " ON DUPLICATE KEY UPDATE total=new.amount",
    "ON DUPLICATE KEY UPDATE total=new.a", "mysql")
  ok(names.amount, "MySQL INSERT SET row alias completes")
  eq(names.key_id, nil, "MySQL row alias respects typed prefix")
  eq(menus.amount, "[numeric]", "MySQL INSERT SET alias type follows assignment order")

  names = complete_names("INSERT INTO orders VALUES(1,2,3) AS new(key_id,user_key,amount)",
    "ON DUPLICATE KEY UPDATE total=new.", "mysql")
  ok(names.key_id and names.user_key and names.amount, "row column aliases without INSERT column list")
  eq(names.id, nil, "row alias renames hide implicit schema names")

  names = complete_names('UPDATE orders AS "odd alias" SET total=1 WHERE "odd alias".',
    'WHERE "odd alias".')
  ok(names.total, "quoted qualifier with spaces resolves target columns")
  names = complete_names('UPDATE orders AS "odd""alias" SET total=1 WHERE "odd""alias".',
    'WHERE "odd""alias".')
  ok(names.total, "escaped quoted qualifier resolves target columns")
  names = complete_names("UPDATE orders O SET total=1 WHERE O.", "WHERE O.")
  ok(names.total, "unquoted uppercase reference resolves folded alias")
  restore()
end

-- Dialect affects comment/string boundaries even when buffer text is unchanged.
do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "UPDATE orders o SET total=1 # FROM users fake",
  })
  eq(completion._get_cached_aliases(bufnr, MYSQL_URL).fake, nil,
    "alias cache uses MySQL comment rules")
  eq(completion._get_cached_aliases(bufnr, PG_URL).fake, "users",
    "alias cache invalidates when the connection dialect changes")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- Columns named VALUE and quoted row aliases keep their explicit mapping.
do
  local restore = mock_db({ items = {
    { column_name = "id", data_type = "integer" },
    { column_name = "value", data_type = "text" },
  } })
  completion.invalidate(MYSQL_URL)
  local aliases = ea("INSERT INTO items(value,id) VALUES('x',1) AS new(v,i)", "mysql")
  local menus = {}
  for _, entry in ipairs(completion.complete("SET value=new.", MYSQL_URL, aliases)) do
    menus[entry.word] = entry.menu
  end
  eq(menus.v, "[text]", "VALUE column preserves reordered INSERT mapping")
  eq(menus.i, "[integer]", "ID column preserves reordered INSERT mapping")
  restore()
end

-- Blink uses the same alias cache and row-alias mapping as the other providers.
do
  local restore = mock_db({ orders = ORDERS_COLS })
  completion.invalidate(MYSQL_URL)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local previous_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  vim.b.db = MYSQL_URL
  local line = "INSERT INTO orders(id,total) VALUES(1,2) AS new ON DUPLICATE KEY UPDATE total=new."
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  local extract, calls = completion.extract_aliases, 0
  completion.extract_aliases = function(...)
    calls = calls + 1
    return extract(...)
  end
  local source = require("dadbod-grip.completion.blink").new()
  local labels = {}
  local blink_context = { line = line, cursor = { 1, #line }, bufnr = bufnr }
  for _ = 1, 2 do
    source:get_completions(blink_context, function(result)
      for _, entry in ipairs(result.items) do labels[entry.label] = true end
    end)
  end
  ok(labels.total, "Blink completes MySQL inserted-row alias")
  eq(calls, 1, "Blink cursor-only calls reuse the alias cache")
  completion.extract_aliases = extract
  vim.api.nvim_set_current_buf(previous_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

-- Nonreserved keyword-shaped table names remain valid completion sources.
for _, table_name in ipairs({ "do", "replace", "left", "inner", "end", "offset" }) do
  eq(ea("SELECT d.id FROM " .. table_name .. " AS d", "sqlite").d, table_name,
    "source table name is not filtered as an alias keyword: " .. table_name)
end

-- Resolve whole-URL templates only on cache misses, without retaining expansion.
do
  local template = "${GRIP_COMPLETION_TEST_URL}"
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "UPDATE orders o SET total=1 # FROM users fake",
  })
  local resolve, calls, expanded = db.resolved_url, 0, MYSQL_URL
  db.resolved_url = function(url)
    if url == template then calls = calls + 1; return expanded end
    return resolve(url)
  end
  eq(completion._get_cached_aliases(bufnr, template).fake, nil,
    "template connection uses expanded MySQL dialect")
  completion._get_cached_aliases(bufnr, template)
  eq(calls, 1, "cached completion does not re-expand connection URL")
  eq(completion._alias_cache[bufnr].url, template, "alias cache retains only original URL")
  expanded = PG_URL
  completion.invalidate(template)
  eq(completion._get_cached_aliases(bufnr, template).fake, "users",
    "connection invalidation refreshes the template dialect")
  db.resolved_url = resolve
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

for _, suffix in ipairs({
  "'unfinished FROM users fake",
  "/* unfinished FROM users fake",
  "$body$unfinished FROM users fake",
}) do
  local aliases = ea("SELECT i.id FROM items i; INSERT INTO users VALUES (" .. suffix, "postgresql")
  eq(aliases.i, "items", "unfinished suffix retains completed aliases: " .. suffix)
  eq(aliases.fake, nil, "unfinished suffix does not expose text as SQL: " .. suffix)
end
-- Source modifiers are separate from the target identifier.
for _, sql_text in ipairs({
  "SELECT i.id FROM ONLY items AS i",
  "UPDATE ONLY items AS i SET value='x' WHERE i.",
  "DELETE FROM ONLY items AS i WHERE i.",
}) do
  eq(ea(sql_text, "postgresql").i, "items", "PostgreSQL ONLY target alias: " .. sql_text)
end

do
  local restore = mock_db({ items = {
    { column_name = "id", data_type = "integer" },
    { column_name = "value", data_type = "text" },
  } })
  completion.invalidate(MYSQL_URL)
  for _, sql_text in ipairs({
    "INSERT INTO items SET value='x' AS new(v)",
    "INSERT INTO items PARTITION(p1) (value) VALUES('x') AS new(v)",
  }) do
    local menus = {}
    for _, entry in ipairs(completion.complete("SET value=new.", MYSQL_URL, ea(sql_text, "mysql"))) do
      menus[entry.word] = entry.menu
    end
    eq(menus.v, "[text]", "row alias type keeps source column after modifiers: " .. sql_text)
  end
  restore()
end

for _, suffix in ipairs({ "1e", "1e+", "$tag", "$" }) do
  local aliases = ea("SELECT i.id FROM items i WHERE i.id=" .. suffix, "postgresql")
  eq(aliases.i, "items", "unfinished scalar prefix keeps source aliases: " .. suffix)
end

-- Mutation modifiers occupy source positions, never alias positions.
for _, action in ipairs({ "ROLLBACK", "ABORT", "FAIL", "IGNORE", "REPLACE" }) do
  local aliases = ea("UPDATE OR " .. action .. " items AS i SET value='x' WHERE i.", "sqlite")
  eq(aliases.i, "items", "SQLite UPDATE OR " .. action .. " resolves target alias")
  eq(aliases[action:lower()], nil, "SQLite conflict action is not a source alias")
end
for _, modifiers in ipairs({ "LOW_PRIORITY", "IGNORE", "LOW_PRIORITY IGNORE" }) do
  local aliases = ea("UPDATE " .. modifiers .. " items AS i SET value='x' WHERE i.", "mysql")
  eq(aliases.i, "items", "MySQL UPDATE modifiers preserve target alias: " .. modifiers)
  eq(aliases.items, nil, "MySQL UPDATE modifier is not a target name: " .. modifiers)
end
for _, prefix in ipairs({ "UPDATE", "DELETE FROM", "SELECT i.id FROM" }) do
  local aliases = ea(prefix .. " items PARTITION(p0,p1) AS i WHERE i.", "mysql")
  eq(aliases.i, "items", "partition list precedes target alias: " .. prefix)
  eq(aliases.partition, nil, "partition clause is not a bare alias: " .. prefix)
end
eq(ea("UPDATE items PARTITION(p0", "mysql").partition, nil,
  "unfinished partition list does not become an alias")
eq(ea("DELETE FROM items OUTPUT deleted.id WHERE id=1", "sqlserver").output, nil,
  "SQL Server OUTPUT is not a DELETE target alias")
eq(ea("DELETE i OUTPUT deleted.id FROM items AS i WHERE i.id=1", "sqlserver").i, "items",
  "SQL Server OUTPUT preserves an explicit DELETE target alias")
eq(ea("SELECT output.id FROM items output", "sqlite").output, "items",
  "OUTPUT remains an ordinary alias in SQLite")
eq(ea("SELECT output.id FROM items output", "sqlserver").output, "items",
  "OUTPUT remains an ordinary SQL Server SELECT alias")
eq(ea(string.rep("SELECT (", 64) .. "1" .. string.rep(") FROM items OUTPUT", 64),
  "sqlserver").output, "items", "nested scalar SELECT keeps ordinary OUTPUT aliases")
eq(ea("DELETE output FROM items output WHERE output.id=1", "sqlserver").output, "items",
  "OUTPUT remains an alias in SQL Server DELETE source FROM")
eq(ea("DELETE FROM items OPTION(RECOMPILE)", "sqlserver").option, nil,
  "SQL Server OPTION is not a DELETE target alias")
eq(ea("DELETE TOP (1) FROM items OUTPUT deleted.id", "sqlserver").output, nil,
  "SQL Server TOP does not expose OUTPUT as an alias")
eq(ea("DELETE TOP (10) PERCENT FROM items OPTION(RECOMPILE)", "sqlserver").option, nil,
  "SQL Server TOP PERCENT does not expose OPTION as an alias")
eq(ea("SELECT option.id FROM items option", "sqlite").option, "items",
  "OPTION remains an ordinary alias in SQLite")
eq(ea("DELETE [option] FROM items AS [option] WHERE [option].id=1", "sqlserver").option, "items",
  "quoted OPTION remains a SQL Server source alias")
eq(ea('DELETE [output] FROM items AS [output] WHERE [output].id=1', "sqlserver").output, "items",
  "quoted OUTPUT remains an explicit SQL Server alias")
eq(ea("SELECT i.id FROM low_priority AS i", "sqlite").i, "low_priority",
  "UPDATE modifier words do not alter ordinary SELECT source extraction")

-- MariaDB URL dispatch exercises the shared MySQL rules through the real cache.
do
  local url = "mariadb://localhost/completion_modifiers"
  local restore = mock_db({ items = {
    { column_name = "id", data_type = "integer" },
    { column_name = "value", data_type = "text" },
  } })
  completion.invalidate(url)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "UPDATE LOW_PRIORITY IGNORE items PARTITION(p0) AS i SET value='x' WHERE i.",
  })
  local aliases = completion._get_cached_aliases(bufnr, url)
  eq(aliases.i, "items", "MariaDB connection dispatch recognizes mutation modifiers")
  local names = {}
  for _, entry in ipairs(completion.complete("WHERE i.", url, aliases)) do
    names[entry.word] = true
  end
  ok(names.id and names.value, "MariaDB modified target completes actual table columns")
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

-- Keyword-shaped variables cannot introduce source aliases. In particular,
-- a fake alias would hide completion for a real table with the same name.
for _, kind in ipairs({ "mysql", "sqlserver" }) do
  for _, variable in ipairs({ "update", "from", "join" }) do
    local sql_text = "SELECT @" .. variable .. " AS items, items.id FROM items"
    eq(next(ea(sql_text, kind)), nil, kind .. " variable is not a source: " .. variable)
  end
end

do
  local restore = mock_db({ items = {
    { column_name = "id", data_type = "integer" },
  } })
  for _, kind in ipairs({ "mysql", "sqlserver" }) do
    local url = kind .. "://localhost/completion_variables"
    completion.invalidate(url)
    local text = "SELECT @update AS items, items.id FROM items"
    local names = {}
    for _, entry in ipairs(completion.complete("SELECT items.", url, ea(text, kind))) do
      names[entry.word] = true
    end
    ok(names.id, kind .. " variable cannot shadow completion for the real table")
  end
  restore()
end

-- SQLite named parameters use either @ or :, including keyword-shaped names.
do
  local restore = mock_db({ items = {
    { column_name = "id", data_type = "integer" },
  } })
  completion.invalidate(SQLITE_URL)
  for _, prefix in ipairs({ "@", ":" }) do
    for _, parameter in ipairs({ "update", "from", "join" }) do
      local text = "SELECT " .. prefix .. parameter .. " AS items, items.id FROM items"
      eq(next(ea(text, "sqlite")), nil, "SQLite parameter is not a source: " .. prefix .. parameter)
    end
    local text = "SELECT " .. prefix .. "update AS items, items.id FROM items"
    local names = {}
    for _, entry in ipairs(completion.complete("SELECT items.", SQLITE_URL, ea(text, "sqlite"))) do
      names[entry.word] = true
    end
    ok(names.id, "SQLite " .. prefix .. "parameter preserves real-table column completion")
  end
  restore()
end

-- REPLACE is also a valid SQLite column/table name. Large SELECT lists must
-- not repeatedly search the remaining query for an INSERT data clause.
for _, naming in ipairs({ "replace AS c", "replace c" }) do
  local fields = {}
  for idx = 1, 1600 do fields[idx] = naming .. idx end
  local aliases = ea("SELECT " .. table.concat(fields, ", ") .. " FROM items AS i", "sqlite")
  eq(aliases.i, "items", "keyword-shaped SELECT columns preserve source alias")
  local count = 0
  for _ in pairs(aliases) do count = count + 1 end
  eq(count, 1, "keyword-shaped SELECT columns do not introduce mutation aliases")
end
eq(ea("REPLACE INTO items(id) VALUES(1); SELECT i.id FROM items AS i", "sqlite").i,
  "items", "REPLACE statement preserves following query aliases")
eq(ea("SELECT r.id FROM replace AS r", "sqlite").r, "replace",
  "keyword-shaped source table preserves its alias")

-- SQLite and DuckDB fold even quoted identifiers; PostgreSQL must continue
-- distinguishing them. Keep stored/displayed schema names in their original case.
do
  local restore = mock_db({
    MixedItems = { { column_name = "id", data_type = "integer" } },
    items = { { column_name = "lower_id", data_type = "integer" } },
    Items = { { column_name = "upper_id", data_type = "integer" } },
  })
  for _, case in ipairs({ { "sqlite", SQLITE_URL }, { "duckdb", DUCK_URL } }) do
    local kind, url = case[1], case[2]
    completion.invalidate(url)
    for _, target in ipairs({ "mixeditems", '"MixedItems"' }) do
      local aliases = ea("UPDATE " .. target .. ' AS "MiX" SET id=1', kind)
      for _, qualifier in ipairs({ "mix", "MIX", '"mIx"', '"MiX"' }) do
        local result = completion.complete("WHERE " .. qualifier .. ".", url, aliases)
        eq(result[1] and result[1].word, "id", kind .. " folds alias and source: " .. qualifier)
      end
    end
    -- Repeated completion reuses schema and folded-name indexes.
    local aliases = ea('UPDATE "MixedItems" AS "MiX" SET id=1', kind)
    for _ = 1, 2 do
      eq(completion.complete('WHERE "mix".', url, aliases)[1].word, "id",
        kind .. " repeated folded lookup")
    end
  end
  completion.invalidate(PG_URL)
  local aliases = ea('SELECT * FROM "Items" AS "I" JOIN items AS i ON true', "postgresql")
  eq(completion.complete('SELECT "I".', PG_URL, aliases)[1].word, "upper_id",
    "PostgreSQL quoted uppercase alias retains distinct target")
  eq(completion.complete("SELECT i.", PG_URL, aliases)[1].word, "lower_id",
    "PostgreSQL unquoted lowercase alias retains distinct target")
  eq(completion.complete("SELECT I.", PG_URL, aliases)[1].word, "lower_id",
    "PostgreSQL unquoted uppercase reference folds before alias lookup")
  eq(#completion.complete('SELECT "MiX".', PG_URL, ea("SELECT * FROM items AS mix", "postgresql")), 0,
    "PostgreSQL quoted qualifier does not fold to unquoted alias")
  for _, kind in ipairs({ "mysql", "sqlserver" }) do
    local url = kind .. "://localhost/completion_case"
    completion.invalidate(url)
    eq(#completion.complete('SELECT "mix".', url, ea('SELECT * FROM "MixedItems" AS "MiX"', kind)), 0,
      kind .. " does not assume a case-insensitive collation")
  end
  restore()
end

-- ── summary ───────────────────────────────────────────────────────────────────
print(string.format("\ncompletion_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
