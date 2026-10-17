-- One loading-clock owner per synchronous database write. Keep the retained
-- client duration inside the float callback so window setup/teardown and the
-- subsequent SELECT are not counted as database-client work.
local M = {}

-- A client wait pumps input as well as timers. Only the initiating grid/query
-- may accept completion: navigation or new edits during the wait own their
-- current state, even though the old SQL may have committed successfully.
function M.capture_owner(bufnr, session)
  local state, url, spec, query_sql = session.state, session.url, session.query_spec, session.query_sql
  local generation, current_view = session._refresh_generation, session.current_view
  return function()
    return require("dadbod-grip.view")._sessions[bufnr] == session
      and vim.api.nvim_buf_is_valid(bufnr) and session.state == state and session.url == url
      and session.query_spec == spec and session.query_sql == query_sql
      and session._refresh_generation == generation and session.current_view == current_view
  end
end

function M.execute(sql, url, label)
  local short = ((label or "SQL"):match("^([^\n]+)") or "SQL"):sub(1, 50)
  local written = require("dadbod-grip.ui").blocking("  writing " .. short .. "...", function()
    local db = require("dadbod-grip.db")
    local opts = { engine_timing = require("dadbod-grip").get_opts().engine_timing }
    local t0 = vim.uv.hrtime()
    local result, err = db.execute(sql, url, opts)
    -- Use one table: ui.blocking's Lua 5.1 unpack must not lose an error after
    -- a leading nil result. Never retry a failed or interrupted write.
    return { result = result, err = err, elapsed_ms = math.floor((vim.uv.hrtime() - t0) / 1e6) }
  end)
  -- These are the adapters' shared fallback messages for an interrupted wait
  -- or client timeout. The child/server may have committed before it stopped,
  -- or may still be running after vim.wait returned: no automatic retry.
  local unknown = written.err == "command timed out"
    or (written.err and written.err:match("^[%w_-]+ exited with code 124$") ~= nil)
  if unknown then
    written.err = "Write wait interrupted or timed out; database outcome is unknown. Refresh before retrying.\n"
      .. written.err
  end
  return written.result, written.err, written.elapsed_ms, unknown
end

return M
