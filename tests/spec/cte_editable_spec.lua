-- cte_editable_spec.lua: safely editable WITH query results.
--
-- Uses tests/seed_sqlite.db so the full public open() path exercises table
-- inference, primary-key lookup, and the final data.new() readonly decision.

local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local db   = require("dadbod-grip.db")

local url = "sqlite:tests/seed_sqlite.db"

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, msg)
  assert(actual == expected,
    (msg or "") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function open_cte(sql)
  cleanup_grids()
  grip.open(sql, url, { from_pad = true })
  local bufnr, session = next(view._sessions)
  assert(bufnr and session, "expected a grid session")
  return bufnr, session
end

test("single-base-table CTE result with full primary key is editable", function()
  local _, session = open_cte([[
WITH user_ids AS (
  SELECT id FROM users WHERE id <= 3
)
SELECT *
FROM orders
WHERE user_id IN (SELECT id FROM user_ids)
]])
  eq(session.state.table_name, "orders", "base table")
  eq(session.state.readonly, false, "result should be editable")
  eq(session.state.pks[1], "id", "primary key")
end)

test("single-base-table CTE result without primary key stays read-only", function()
  local _, session = open_cte([[
WITH user_ids AS (
  SELECT id FROM users WHERE id <= 3
)
SELECT user_id, total
FROM orders
WHERE user_id IN (SELECT id FROM user_ids)
]])
  eq(session.state.table_name, "orders", "base table is still known")
  eq(session.state.readonly, true, "missing result PK must keep result read-only")
  eq(#session.state.pks, 0, "unsafe PK metadata is discarded")
end)

test("composite primary key must be complete in the result", function()
  local _, session = open_cte([[
WITH active_tenants AS (
  SELECT tenant_id FROM composite_pk WHERE active = 1
)
SELECT tenant_id, role
FROM composite_pk
WHERE tenant_id IN (SELECT tenant_id FROM active_tenants)
]])
  eq(session.state.table_name, "composite_pk", "base table")
  eq(session.state.readonly, true, "one missing PK component must keep result read-only")
  eq(#session.state.pks, 0, "partial composite PK metadata is discarded")
end)

test("read-only connection still wins over inferred CTE table", function()
  local real_is_readonly = db.is_readonly
  db.is_readonly = function() return true end

  local ok, err = pcall(function()
    local _, session = open_cte([[
WITH user_ids AS (
  SELECT id FROM users WHERE id <= 3
)
SELECT *
FROM orders
WHERE user_id IN (SELECT id FROM user_ids)
]])
    eq(session.state.table_name, "orders", "base table")
    eq(session.state.readonly, true, "connection mode must keep result read-only")
    eq(#session.state.pks, 0, "read-only connections expose no editable PK metadata")
  end)

  db.is_readonly = real_is_readonly
  assert(ok, err)
end)

cleanup_grids()

print(string.format("cte_editable_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
