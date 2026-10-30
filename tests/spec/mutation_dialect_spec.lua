-- Check dialect-specific preview SQL at the public database boundary.
-- These are parser/preview tests with mocked DB responses, not live DB tests.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db = require("dadbod-grip.db")
local pass, fail = 0, 0
local notify, confirm = vim.notify, vim.fn.confirm
local original = {
  query = db.query, execute = db.execute, is_readonly = db.is_readonly,
  get_primary_keys = db.get_primary_keys, get_column_info = db.get_column_info,
}
local queries, writes, metadata, notices = {}, {}, {}, {}
db.query = function(sql)
  queries[#queries + 1] = sql
  return { columns = { "id", "value" }, rows = { { "2", "old" } } }
end
db.execute = function(sql) writes[#writes + 1] = sql; error("preview attempted a write") end
db.is_readonly = function() return false end
db.get_primary_keys = function(tbl) metadata[#metadata + 1] = tbl; return { "id" } end
db.get_column_info = function()
  return {
    { column_name = "id", data_type = "integer" },
    { column_name = "value", data_type = "text" },
  }
end
vim.notify = function(message, level)
  if level and level >= vim.log.levels.WARN then notices[#notices + 1] = message end
end

local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected),
    label .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function cleanup()
  local buffers = {}
  for buf in pairs(view._sessions) do buffers[#buffers + 1] = buf end
  for _, buf in ipairs(buffers) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    view._sessions[buf] = nil
  end
  while #vim.api.nvim_list_wins() > 1 do
    local wins = vim.api.nvim_list_wins()
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end
local function test(name, run)
  cleanup()
  queries, writes, metadata, notices = {}, {}, {}, {}
  db.is_readonly = function() return false end
  db.execute = function(sql) writes[#writes + 1] = sql; error("preview attempted a write") end
  vim.fn.confirm = confirm
  local ok, err = pcall(run)
  vim.fn.confirm = confirm
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local cases = {
  {
    name = "SQL Server unquoted OUTPUT assignment column", kind = "sqlserver",
    sql = "UPDATE items SET output=1, value='changed' WHERE id=2",
    select = 'SELECT * FROM "items" WHERE id=2', value = "changed",
  },
  {
    name = "SQL Server OUTPUT column expression before OUTPUT clause", kind = "sqlserver",
    sql = "UPDATE items SET value=output OUTPUT inserted.value WHERE id=2",
    select = 'SELECT * FROM "items" WHERE id=2',
  },
  {
    name = "SQL Server OUTPUT and RETURNING result aliases", kind = "sqlserver",
    sql = "UPDATE items SET value='changed' OUTPUT inserted.id AS output, inserted.value AS returning WHERE id=2",
    select = 'SELECT * FROM "items" WHERE id=2', value = "changed",
  },
  {
    name = "SQL Server UPDATE OUTPUT before WHERE", kind = "sqlserver",
    sql = "UPDATE items SET value='changed' OUTPUT inserted.id, deleted.value WHERE id=2",
    select = 'SELECT * FROM "items" WHERE id=2', value = "changed",
  },
  {
    name = "SQL Server UPDATE OUTPUT INTO destination list", kind = "sqlserver",
    sql = "UPDATE items SET value='changed' OUTPUT inserted.id, CONCAT(deleted.value,',',inserted.value)"
      .. " INTO audit_items(id,value) WHERE id=2 OPTION (RECOMPILE)",
    select = 'SELECT * FROM "items" WHERE id=2', value = "changed",
  },
  {
    name = "SQL Server UPDATE two OUTPUT clauses and nested SET", kind = "sqlserver",
    sql = "UPDATE items SET value=CONCAT('x',',y') OUTPUT inserted.id INTO @audit(id)"
      .. " OUTPUT inserted.value WHERE id IN (SELECT id FROM other WHERE value='OUTPUT')",
    select = 'SELECT * FROM "items" WHERE id IN (SELECT id FROM other WHERE value=\'OUTPUT\')',
  },
  {
    name = "SQL Server UPDATE OUTPUT without WHERE", kind = "sqlserver",
    sql = "UPDATE items SET value='changed' OUTPUT inserted.id",
    select = 'SELECT * FROM "items"', value = "changed",
  },
  {
    name = "SQL Server DELETE OUTPUT before WHERE", kind = "sqlserver",
    sql = "DELETE FROM items OUTPUT deleted.id, deleted.value WHERE id=2",
    select = 'SELECT * FROM "items" WHERE id=2',
  },
  {
    name = "SQL Server DELETE optional FROM and OUTPUT INTO", kind = "sqlserver",
    sql = "DELETE items OUTPUT deleted.id INTO audit_items(id) WHERE id=2",
    select = 'SELECT * FROM "items" WHERE id=2',
  },
  {
    name = "SQL Server DELETE quoted optional FROM target", kind = "sqlserver",
    sql = "DELETE [dbo].[items] OUTPUT deleted.[id] WHERE [id]=2",
    table_name = "dbo.items", select = 'SELECT * FROM "dbo"."items" WHERE [id]=2',
  },
  {
    name = "SQL Server DELETE OUTPUT without WHERE", kind = "sqlserver",
    sql = "DELETE items OUTPUT deleted.id",
    select = 'SELECT * FROM "items"',
  },
  {
    name = "SQL Server DELETE alias source", kind = "sqlserver",
    sql = "DELETE i FROM items AS i WHERE i.id=2",
    select = 'SELECT * FROM "items" AS i WHERE i.id=2',
  },
  {
    name = "SQL Server trailing OPTION hint", kind = "sqlserver",
    sql = "DELETE FROM items OPTION (RECOMPILE)",
    select = 'SELECT * FROM "items"',
  },
  {
    name = "MySQL trailing hash comment", kind = "mysql",
    sql = "UPDATE items AS i SET value='changed' WHERE i.id=2 # trailing",
    select = 'SELECT * FROM "items" AS i WHERE i.id=2', value = "changed",
  },
  {
    name = "MySQL hash immediately before newline", kind = "mysql",
    sql = "DELETE FROM items AS i WHERE i.id=2 #\n AND i.value='old'",
    select = 'SELECT * FROM "items" AS i WHERE i.id=2 #\n AND i.value=\'old\'',
  },
  {
    name = "MySQL internal hash comment preserves AND", kind = "mysql",
    sql = "UPDATE items AS i SET value='changed' WHERE i.id=2 # WHERE i.id=1\n AND i.id>0",
    select = 'SELECT * FROM "items" AS i WHERE i.id=2 # WHERE i.id=1\n AND i.id>0', value = "changed",
  },
  {
    name = "MySQL subtraction and LEFT/RIGHT functions", kind = "mysql",
    sql = "UPDATE items AS i SET value=LEFT(value,1) WHERE RIGHT(i.value,1)='d' AND i.id--1=3",
    select = 'SELECT * FROM "items" AS i WHERE RIGHT(i.value,1)=\'d\' AND i.id--1=3',
  },
  {
    name = "PostgreSQL DISTINCT FROM operators", kind = "postgresql",
    sql = "UPDATE items AS i SET value=value IS NOT DISTINCT FROM 'old' WHERE i.value IS DISTINCT FROM NULL",
    select = 'SELECT * FROM "items" AS i WHERE i.value IS DISTINCT FROM NULL',
  },
  {
    name = "PostgreSQL nested comments", kind = "postgresql",
    sql = "UPDATE items /* outer /* WHERE false */ still outer */ AS i SET value='changed' WHERE i.id=2",
    select = 'SELECT * FROM "items" AS i WHERE i.id=2', value = "changed",
  },
  {
    name = "PostgreSQL dollar strings", kind = "postgresql",
    sql = "UPDATE items AS i SET value=$v$next, WHERE SET$v$ WHERE i.value=$p$WHERE, LIMIT$p$",
    select = 'SELECT * FROM "items" AS i WHERE i.value=$p$WHERE, LIMIT$p$', value = "next, WHERE SET",
  },
  {
    name = "PostgreSQL quoted case", kind = "postgresql",
    sql = 'UPDATE "Mixed"."Items" AS "It" SET "value"=\'changed\' WHERE "It".id=2',
    select = 'SELECT * FROM "Mixed"."Items" AS "It" WHERE "It".id=2',
    table_name = "Mixed.Items", value = "changed",
  },
  {
    name = "trailing line comment before RETURNING", kind = "postgresql",
    sql = "DELETE FROM items AS i WHERE i.id=2 -- do not swallow the wrapper\nRETURNING id",
    select = 'SELECT * FROM "items" AS i WHERE i.id=2',
  },
}
for _, case in ipairs(cases) do
  test(case.name, function()
    if case.kind == "sqlserver" then db.is_readonly = original.is_readonly end
    grip._mutation_preview(case.sql, case.kind .. "://unused/fixture", case.sql:match("^%u+"), {})
    local session = assert(view._sessions[vim.api.nvim_get_current_buf()], table.concat(notices, "; "))
    local pending = assert(session.pending_mutation, "no pending mutation")
    eq(queries, { case.select }, "generated SELECT")
    eq(session.state.sql, case.select, "session SELECT")
    eq(pending.sql, case.sql, "original mutation retained")
    eq(pending.table_name, case.table_name or "items", "base-table metadata")
    eq(metadata, case.kind == "sqlserver" and {} or { case.table_name or "items" }, "schema lookup target")
    eq(session.state.changes[1], case.value and { value = case.value } or nil, "literal-only staging")
    eq(writes, {}, "no mutation executed")
    eq(notices, {}, "no warnings/errors")
    if case.kind == "sqlserver" then
      eq(session.state.readonly, true, "SQL Server grid remains read-only")
      local apply = vim.fn.maparg(require("dadbod-grip.keymaps").get("grid_apply"), "n", false, true).callback
      vim.fn.confirm = function() return 2 end
      apply()
      eq(writes, {}, "declining confirmation must not execute")
      db.execute = function(sql) writes[#writes + 1] = sql; return { affected = 1 } end
      vim.fn.confirm = function() return 1 end
      apply()
      eq(writes, { case.sql }, "confirmed SQL executes exactly once despite read-only grid")
      eq(session.pending_mutation, nil, "confirmed mutation cleared")
      eq(notices, {}, "confirmation warnings/errors")
    end
  end)
end

for _, case in ipairs({
  { kind = "sqlserver", sql = "UPDATE i SET value='changed' OUTPUT inserted.id FROM items AS i WHERE i.id=2" },
  { kind = "sqlserver", sql = "DELETE i OUTPUT deleted.id FROM items AS i JOIN other AS o ON i.id=o.id" },
  { kind = "sqlserver", sql = "UPDATE items SET value='changed' OUTPUT inserted.id; DELETE FROM items" },
  { kind = "sqlserver", sql = "DELETE items OUTPUT deleted.id WHERE id=2; DELETE FROM other" },
  { kind = "sqlserver", sql = "UPDATE items SET value='changed' OUTPUT WHERE id=2" },
  { kind = "sqlserver", sql = "DELETE items OUTPUT" },
  { kind = "mysql", sql = "UPDATE items /*!50000 AS i */ SET value='changed' WHERE id=2" },
  { kind = "mysql", sql = "UPDATE items /*M!100100 AS i */ SET value='changed' WHERE id=2" },
  { kind = "postgresql", sql = "UPDATE items SET value=other.value FROM other WHERE items.id=other.id" },
  { kind = "postgresql", sql = "DELETE FROM items USING other WHERE items.id=other.id" },
  { kind = "mysql", sql = "UPDATE LOW_PRIORITY items SET value='changed' WHERE id=2" },
  { kind = "postgresql", sql = "UPDATE ONLY items SET value='changed' WHERE id=2" },
}) do
  test("reject unsupported source: " .. case.sql, function()
    grip._mutation_preview(case.sql, case.kind .. "://unused/fixture", case.sql:match("^%u+"), {})
    for _, session in pairs(view._sessions) do
      assert(not session.pending_mutation, "unsupported source opened a pending preview")
    end
    eq(queries, {}, "unsupported source must not issue a guessed SELECT")
    eq(writes, {}, "unsupported source must not execute")
    assert(#notices > 0, "rejection must explain why preview is unavailable")
  end)
end

cleanup()
for name, fn in pairs(original) do db[name] = fn end
vim.notify = notify
print(string.format("\nmutation_dialect_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
