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

test("repeated apply during a client wait executes pending SQL once", function(maps, session, writes, counts)
  local execute = db.execute
  db.execute = function(sql)
    local result = execute(sql)
    if #writes == 1 then
      vim.schedule(maps.grid_apply)
      vim.wait(20, function() return false end, 2)
    end
    return result
  end
  maps.grid_apply()
  local prompts, reopens = counts()
  assert(#writes == 1 and prompts == 1 and reopens == 1, "pending SQL was applied more than once")
  assert(writes[1] == "INSERT INTO items(value) VALUES(1)" and not session.pending_mutation,
    "successful apply must consume original SQL")
end)

test("cancelled confirmation can be confirmed later", function(maps, session, writes)
  vim.fn.confirm = function() return 2 end
  maps.grid_apply()
  assert(#writes == 0 and session.pending_mutation, "cancel executed or discarded SQL")
  vim.fn.confirm = function() return 1 end
  maps.grid_apply()
  assert(#writes == 1 and not session.pending_mutation, "cancel left apply locked")
end)

test("failed execution can be explicitly retried", function(maps, session, writes)
  local execute = db.execute
  db.execute = function() return nil, "fixture failure" end
  maps.grid_apply()
  assert(session.pending_mutation, "failure discarded pending SQL")
  db.execute = execute
  maps.grid_apply()
  assert(#writes == 1 and not session.pending_mutation, "failure left apply locked")
end)

test("thrown execution can be explicitly retried", function(maps, session, writes)
  local execute = db.execute
  db.execute = function() error("fixture exception") end
  local ok, err = pcall(maps.grid_apply)
  assert(not ok and tostring(err):find("fixture exception", 1, true), "exception was hidden")
  assert(session.pending_mutation, "exception discarded pending SQL")
  db.execute = execute
  maps.grid_apply()
  assert(#writes == 1 and not session.pending_mutation, "exception left apply locked")
end)

for _, action in ipairs({ "grid_undo", "grid_undo_all" }) do
  test("cancel cannot discard a mutation while its write is running: " .. action,
      function(maps, session, writes)
    local execute, pending = db.execute, session.pending_mutation
    db.execute = function(sql)
      vim.schedule(function()
        maps[action]()
        assert(session.pending_mutation == pending, "running SQL was reported as cancelled")
      end)
      vim.wait(20, function() return false end, 2)
      return execute(sql)
    end
    maps.grid_apply()
    assert(#writes == 1 and not session.pending_mutation, "completed SQL was not consumed once")
  end)
end

for _, target in ipairs({ "notification", "history", "refresh" }) do
  test("committed SQL is consumed before " .. target .. " can throw", function(maps, session, writes)
    local function throw() error("fixture post-write exception") end
    if target == "notification" then vim.notify = throw
    elseif target == "history" then history.record = throw
    else grip.open = throw end
    local ok, err = pcall(maps.grid_apply)
    assert(not ok and tostring(err):find("fixture post-write exception", 1, true), "exception was hidden")
    assert(#writes == 1 and not session.pending_mutation, "committed SQL remained retryable")
    vim.notify = function() end
    maps.grid_apply()
    assert(#writes == 1, "post-write exception allowed duplicate execution")
  end)
end

test("reentrant confirmation cannot prompt twice", function(maps, session, writes)
  local prompts = 0
  vim.fn.confirm = function()
    prompts = prompts + 1
    if prompts == 1 then maps.grid_apply() end
    return 1
  end
  maps.grid_apply()
  assert(prompts == 1 and #writes == 1 and not session.pending_mutation,
    "confirmation reentry executed pending SQL twice")
end)

db.execute, grip.open, history.record = original.execute, original.open, original.record
vim.fn.confirm, vim.notify = original.confirm, original.notify
print(string.format("\nmutation_apply_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
