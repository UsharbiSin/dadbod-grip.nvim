-- Compact, actionable welcome content. The caller owns navigation and commands.
local M = {}

function M.render(buf)
  local km = require("dadbod-grip.keymaps")
  local function key(action, fallback) return km.get(action) or fallback end
  local lines, marks, rows = {}, {}, {}
  local function add(text, hl, col, end_col)
    lines[#lines + 1] = text
    if hl then marks[#marks + 1] = { #lines - 1, hl, col or 0, end_col or #text } end
  end
  add("  ╔═╦═╦═╗", "Special")
  local brand = "  ║d║b║g║  dadbod-grip v" .. require("dadbod-grip.version")
  add(brand, "Special")
  marks[#marks + 1] = { #lines - 1, "Title", brand:find("dadbod-grip", 1, true) - 1, #brand }
  add("  ╚═╩═╩═╝", "Special")
  local activate = km.get("welcome_activate")
  local move = km.get("welcome_next")
  local controls = activate and activate .. " choose" or "Type a command"
  if move then controls = controls .. " | " .. move .. "/" .. key("welcome_prev", "k") .. " move" end
  add("  START  " .. controls, "Title")
  for _, action in ipairs({
    { "demo", "Open demo", ":GripStart" },
    { "connect", "Connect a database", ":GripConnect" },
    { "tables", "Browse tables", key("table_picker_go", ":GripTables") },
    { "query", "Open SQL pad", key("tab_2", ":GripQuery") },
  }) do
    local prefix = string.format("  %-21s ", action[2])
    add(prefix .. action[3], action[3]:sub(1, 1) == ":" and "Statement" or "Identifier", #prefix)
    rows[#lines] = action[1]
  end
  -- Stable row identities keep selections intact when this buffer is shared by
  -- differently sized windows or tabs. The workspace also fits a short split.
  for i, line in ipairs({
    "  +--------+-----------------------+",
    "  | Schema | SQL pad               |",
    "  |        +-----------------------+",
    "  |        | Table / results       |",
    "  +--------+-----------------------+",
  }) do
    local hint = ({ { "help", "Help" }, { "schema_browser", "Schema" },
      { "zoom", "Zoom" }, { "welcome_close", "Close" } })[i]
    if hint and km.get(hint[1]) then line = line .. "  " .. km.get(hint[1]) .. " " .. hint[2] end
    add(line, "Comment")
  end
  if km.get("qpad_execute") then
    add("  Demo: rolls -> " .. key("tab_2", ":GripQuery") .. " SQL -> "
      .. km.get("qpad_execute") .. " run", "Comment")
  else
    add("  Demo: :Grip SELECT sku FROM rolls LIMIT 20", "Comment")
  end
  -- Reopening in another tab must not rewrite an already visible buffer.
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  local ns = vim.api.nvim_create_namespace("grip_welcome")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[3], { end_col = mark[4], hl_group = mark[2] })
  end
  return rows
end

return M
