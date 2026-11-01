-- Exercise the actual preview apply handler with mocked database boundaries.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, history = require("dadbod-grip.db"), require("dadbod-grip.history")
local original = { execute = db.execute, open = grip.open, record = history.record,
  confirm = vim.fn.confirm, notify = vim.notify }
local pass, fail = 0, 0
local function test(name, run)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local sql = "INSERT INTO items(value) VALUES(1)"
  local pending = { sql = sql, type = "INSERT", table_name = "items", row_count = 1 }
  local session = { state = {}, url = "sqlite:unused", pending_mutation = pending }
  view._sessions[bufnr] = session
  local maps, writes, prompts, reopens = {}, {}, 0, 0
  require("dadbod-grip.view.keymaps_edit").setup(bufnr, {
    view = view, kmap = function(action, callback) maps[action] = callback end,
    session = function() return session end, session_is_editable = function() return false end,
  })
  vim.notify = function() end
  vim.fn.confirm = function() prompts = prompts + 1; return 1 end
  history.record = function() end
  grip.open = function() reopens = reopens + 1 end
  db.execute = function(statement) writes[#writes + 1] = statement; return { affected = 1 } end
  local ok, err = pcall(run, maps, session, writes, function() return prompts, reopens end)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
  view._sessions[bufnr] = nil
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

for _, unavailable in ipairs({ false, true }) do
  test("affected-count availability: " .. tostring(unavailable), function(maps, session)
    session.pending_mutation.affected_count_unavailable = unavailable
    local message
    vim.notify = function(text) message = text end
    db.execute = function() return { affected = 0 } end
    maps.grid_apply()
    assert(message and message:find("INSERT executed", 1, true), "execution message missing")
    assert((message:find("0 rows affected", 1, true) ~= nil) == not unavailable,
      "unavailable count was reported, or an available count was hidden")
  end)
end

db.execute, grip.open, history.record = original.execute, original.open, original.record
vim.fn.confirm, vim.notify = original.confirm, original.notify
print(string.format("\nmutation_result_count_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
