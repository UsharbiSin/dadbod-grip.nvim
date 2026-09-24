-- projection_edit_safety_spec.lua: projected query columns must map safely
-- back to the base table before a result grid is editable.

local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")

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

local function open_query(sql)
  cleanup_grids()
  grip.open(sql, url, { from_pad = true })
  local bufnr, session = next(view._sessions)
  assert(bufnr and session, "expected a grid session")
  return session
end

test("aliased column result stays read-only", function()
  local session = open_query([[
SELECT id, total AS status
FROM orders;
]])
  eq(session.state.readonly, true, "aliased result must not be editable")
  eq(session.state.table_name, nil, "unsafe projection must not expose a mutation table")
  eq(view._is_editable(session), false, "grid edit actions must stay disabled")
end)

test("computed aliased column result stays read-only", function()
  local session = open_query([[
SELECT id, total * 2 AS status
FROM orders;
]])
  eq(session.state.readonly, true, "computed result must not be editable")
  eq(session.state.table_name, nil, "unsafe projection must not expose a mutation table")
  eq(view._is_editable(session), false, "grid edit actions must stay disabled")
end)

test("plain direct column projection remains editable", function()
  local session = open_query([[
SELECT id, total
FROM orders;
]])
  eq(session.state.table_name, "orders", "base table")
  eq(session.state.readonly, false, "direct base-table columns should remain editable")
  eq(session.state.pks[1], "id", "primary key")
  eq(view._is_editable(session), true, "grid edit actions should remain enabled")
end)

cleanup_grids()

print(string.format("projection_edit_safety_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
