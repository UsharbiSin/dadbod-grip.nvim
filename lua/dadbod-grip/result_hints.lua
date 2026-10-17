-- Two window-local footer rows; grid data keeps its own horizontal viewport.
local M = {}

function M.pack(items, width)
  if width < 1 or #items == 0 then return {} end
  local rows, omitted = { {} }, false
  local function text(row) return #row > 0 and (" " .. table.concat(row, "  ")) or "" end
  for _, item in ipairs(items) do
    local row = rows[#rows]
    local candidate = text(row) .. (#row > 0 and "  " or " ") .. item
    if vim.fn.strdisplaywidth(candidate) <= width then
      row[#row + 1] = item
    elseif #rows < 2 and vim.fn.strdisplaywidth(item) + 1 <= width then
      rows[#rows + 1] = { item }
    else
      omitted = true
    end
  end
  if omitted then
    if #rows < 2 then rows[#rows + 1] = {} end
    local row = rows[#rows]
    -- Discovery and the first core action in each row take precedence over ….
    while #row > 1 and vim.fn.strdisplaywidth(text(row) .. "  …") > width do table.remove(row) end
    local marker = text(row) .. (#row > 0 and "  …" or " …")
    if vim.fn.strdisplaywidth(marker) <= width then row[#row + 1] = "…"
    elseif #row == 0 and vim.fn.strdisplaywidth("…") <= width then row[1] = "…" end
  end
  local result = {}
  for _, row in ipairs(rows) do
    local line = text(row)
    if vim.fn.strdisplaywidth(line) > width then line = "…" end
    if line ~= "" then result[#result + 1] = line end
  end
  return result
end

-- Query time is observed by this client around db.query, not server execution.
-- Keep milliseconds useful for fast queries and share the loading timer's
-- seconds/minutes format for longer ones.
function M.query_time(ms, width)
  local ui = require("dadbod-grip.ui")
  local duration = ms < 1000 and (ms .. "ms") or ui.format_elapsed(ms)
  for _, label in ipairs({ " Query: " .. duration .. " client", " Q: " .. duration .. " client",
      " " .. duration .. " client", " Q:" .. duration, " " .. duration }) do
    if vim.fn.strdisplaywidth(label) <= width then return label end
  end
  return ui.truncate_display(" " .. duration, width)
end

function M.attach(sessions)
  local ns = vim.api.nvim_create_namespace("grip_result_hints")
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf)
      local render = sessions[buf] and sessions[buf]._render
      if not (render and render.hint_row) then return false end
      local info = vim.fn.getwininfo(win)[1]
      if not info then return false end
      local width = info.width - info.textoff
      if render.query_time_row then
        local text = require("dadbod-grip.ui").pad_display(M.query_time(render.query_elapsed_ms, width), width, false)
        vim.api.nvim_buf_set_extmark(buf, ns, render.query_time_row, 0, {
          virt_text = { { text, "GripStatusOk" } }, virt_text_win_col = 0,
          virt_text_pos = "overlay", ephemeral = true,
        })
      end
      local key = width .. ":" .. vim.o.ambiwidth
      local lines = render.hint_cache[key]
      if not lines then
        lines = M.pack(render.hint_items, width)
        render.hint_cache[key] = lines
      end
      for i, line in ipairs(lines) do
        vim.api.nvim_buf_set_extmark(buf, ns, render.hint_row + i - 1, 0, {
          virt_text = { { line, "Comment" } }, virt_text_win_col = 0,
          virt_text_pos = "overlay", ephemeral = true,
        })
      end
      return false
    end,
  })
end

return M
