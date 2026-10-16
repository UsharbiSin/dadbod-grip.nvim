-- Only the seeded SQLite fixture is used. No window or buffer API is mocked.
return function(scenario)
  vim.o.splitkeep, vim.o.scrolloff, vim.o.sidescrolloff = "screen", 0, 0
  vim.o.equalalways = false
  local grip = require("dadbod-grip")
  local view = require("dadbod-grip.view")
  local schema = require("dadbod-grip.schema")
  local pad = require("dadbod-grip.query_pad")
  local data = require("dadbod-grip.data")
  local url = "sqlite:tests/seed_sqlite.db"
  grip.setup({ connections_path = vim.fn.tempname(), open_sidebar = true })
  assert(vim.fn.exists(":GripZoom") == 2, "GripZoom command is missing")
  assert(require("dadbod-grip.connections").switch(url, "synthetic zoom", "sqlite"))
  assert(vim.wait(5000, function()
    return pad.get_pad_bufnr() and schema.is_open() and vim.fn.bufnr("grip://welcome") ~= -1
  end, 10), "initial workspace did not finish opening")
  grip.open("users", url)
  assert(vim.wait(5000, function()
    local session = view._sessions[vim.fn.bufnr("grip://users")]
    return session and session._column_info ~= nil
  end, 10), "initial result metadata did not finish loading")
  local gridbuf, padbuf = vim.fn.bufnr("grip://users"), pad.get_pad_bufnr()
  local wins = { grid = vim.fn.bufwinid(gridbuf), query = vim.fn.bufwinid(padbuf), sidebar = schema.get_winid() }
  local session, state = view._sessions[gridbuf], schema.get_state(url)
  session.state = data.add_change(session.state, 1, "name", "unsaved zoom result")
  view.render(gridbuf, session.state)
  local sql = {}
  for i = 1, 90 do sql[i] = "SELECT 'unsaved query " .. i .. string.rep("x", 120) .. "';" end
  vim.api.nvim_buf_set_lines(padbuf, 0, -1, false, sql)
  vim.api.nvim_set_current_win(wins.grid)
  vim.cmd("belowright vsplit")
  wins.external = vim.api.nvim_get_current_win()
  local note = vim.api.nvim_create_buf(true, false)
  vim.bo[note].bufhidden = "hide"
  vim.api.nvim_win_set_buf(wins.external, note)
  vim.api.nvim_buf_set_lines(note, 0, -1, false, { "unsaved external note" })
  for _, win in pairs(wins) do vim.wo[win].wrap = false end
  vim.api.nvim_win_set_width(wins.sidebar, 25)
  vim.wo[wins.sidebar].winfixwidth = true
  vim.api.nvim_win_set_height(wins.query, 9)
  vim.wo[wins.query].winfixheight = true
  vim.api.nvim_win_call(wins.query, function()
    vim.fn.winrestview({ lnum = 25, col = 70, topline = 22, leftcol = 55 })
  end)
  local function snapshot()
    vim.cmd("redraw")
    local result = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        result[#result + 1] = { win = win, buf = vim.api.nvim_win_get_buf(win),
          width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win),
          fixwidth = vim.wo[win].winfixwidth, fixheight = vim.wo[win].winfixheight,
          view = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
      end
    end
    return result
  end
  local function check_data()
    assert(view._sessions[gridbuf] == session and data.has_changes(session.state), "staged result was lost")
    assert(data.effective_value(session.state, 1, "name") == "unsaved zoom result")
    assert(schema.get_state(url) == state, "sidebar state was replaced")
    assert(vim.api.nvim_buf_is_valid(padbuf) and vim.bo[padbuf].modified, "unsaved query was discarded")
    assert(vim.api.nvim_buf_get_lines(padbuf, 0, 1, false)[1] == sql[1])
    assert(vim.api.nvim_buf_is_valid(note) and vim.bo[note].modified, "external note was discarded")
    assert(vim.wo[wins.sidebar].winfixwidth and vim.wo[wins.query].winfixheight,
      "original fixed-size settings were not restored")
    assert(vim.v.errmsg == "", vim.v.errmsg)
    return true
  end
  local function check_sizes()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        assert(vim.api.nvim_win_get_width(win) > 1 and vim.api.nvim_win_get_height(win) > 1,
          "zoom left a surviving pane at its minimum size")
      end
    end
  end
  local function zoom(win)
    vim.api.nvim_set_current_win(win)
    local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    local layout = vim.fn.winlayout()
    vim.cmd("GripZoom")
    assert(vim.api.nvim_get_current_win() == win, "zoom changed the current window")
    assert(vim.deep_equal(layout, vim.fn.winlayout()), "zoom replaced or closed windows")
    assert(vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win) > width * height,
      "current pane did not grow")
  end
  local function roundtrip(win)
    vim.api.nvim_set_current_win(win)
    local before = snapshot()
    zoom(win)
    vim.cmd("GripZoom")
    assert(vim.deep_equal(snapshot(), before), "restore changed sizes, options, buffers, or views")
    check_data()
  end
  if wins[scenario] then
    roundtrip(wins[scenario])
  elseif scenario == "repeat" then
    for _ = 1, 10 do roundtrip(wins.query) end
  elseif scenario == "edit" then
    zoom(wins.query)
    vim.api.nvim_buf_set_lines(padbuf, 90, 90, false, { "SELECT 'typed while zoomed';" })
    vim.api.nvim_win_set_cursor(wins.query, { 91, 7 })
    vim.cmd("GripZoom")
    assert(vim.api.nvim_win_get_cursor(wins.query)[1] == 91, "restore rewound the edited query cursor")
    assert(vim.api.nvim_buf_get_lines(padbuf, 90, 91, false)[1] == "SELECT 'typed while zoomed';")
    check_data()
  elseif scenario == "resize" then
    zoom(wins.query)
    _G.grip_zoom_check = function() check_sizes(); return check_data() end
  elseif scenario == "external-split" then
    zoom(wins.query)
    vim.cmd("belowright split")
    local extra = vim.api.nvim_get_current_win()
    local added = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(extra, added)
    vim.api.nvim_buf_set_lines(added, 0, -1, false, { "new split created while zoomed" })
    local layout = vim.fn.winlayout()
    vim.cmd("GripZoom")
    assert(vim.deep_equal(layout, vim.fn.winlayout()), "restore rebuilt an obsolete layout")
    assert(vim.api.nvim_win_is_valid(extra) and vim.api.nvim_win_get_buf(extra) == added)
    check_sizes()
    check_data()
  elseif scenario == "closed-target" then
    zoom(wins.external)
    vim.api.nvim_win_close(wins.external, true)
    assert(vim.wait(1000, function() return vim.wo[wins.sidebar].winfixwidth end, 10),
      "closing the zoomed pane left stale fixed-size settings")
    check_sizes()
    check_data()
    roundtrip(wins.grid)
  elseif scenario == "closed-other" then
    zoom(wins.query)
    vim.api.nvim_win_close(wins.external, true)
    local layout = vim.fn.winlayout()
    vim.cmd("GripZoom")
    assert(vim.deep_equal(layout, vim.fn.winlayout()), "restore resurrected a closed pane")
    check_sizes()
    check_data()
  elseif scenario == "rearranged" then
    zoom(wins.query)
    vim.cmd("wincmd H")
    local layout = vim.fn.winlayout()
    vim.cmd("GripZoom")
    assert(vim.deep_equal(layout, vim.fn.winlayout()), "restore undid the moved split")
    check_sizes()
    check_data()
  elseif scenario == "focus" then
    zoom(wins.grid)
    vim.api.nvim_set_current_win(wins.sidebar)
    vim.api.nvim_win_set_cursor(wins.sidebar, { 5, 0 })
    vim.cmd("GripZoom")
    assert(vim.api.nvim_get_current_win() == wins.sidebar, "restore stole focus")
    assert(vim.api.nvim_win_get_cursor(wins.sidebar)[1] == 5, "restore lost sidebar navigation")
    check_data()
  elseif scenario == "other-scroll" then
    local lines = {}
    for i = 1, 200 do lines[i] = "unsaved note line " .. i end
    vim.api.nvim_buf_set_lines(note, 0, -1, false, lines)
    vim.api.nvim_win_call(wins.external, function()
      vim.fn.winrestview({ lnum = 50, col = 0, topline = 40 })
    end)
    zoom(wins.grid)
    vim.api.nvim_set_current_win(wins.external)
    local before_scroll = vim.fn.winsaveview()
    vim.cmd("normal! 5\005")
    local navigated = vim.fn.winsaveview()
    assert(navigated.lnum == before_scroll.lnum and navigated.topline == before_scroll.topline + 5,
      "expected scrolling without cursor movement")
    vim.api.nvim_set_current_win(wins.grid)
    vim.cmd("GripZoom")
    local restored = vim.api.nvim_win_call(wins.external, vim.fn.winsaveview)
    assert(restored.topline == navigated.topline, "restore undid navigation in a visited pane")
    check_data()
  elseif scenario == "help-split" then
    vim.cmd("help windows")
    roundtrip(vim.api.nvim_get_current_win())
  elseif scenario == "help" then
    zoom(wins.query)
    view.show_help()
    local help = vim.api.nvim_get_current_win()
    assert(vim.api.nvim_win_get_config(help).relative ~= "", "expected actual floating help")
    vim.api.nvim_win_close(help, true)
    vim.api.nvim_set_current_win(wins.query)
    vim.cmd("GripZoom")
    check_data()
    view.show_help()
    help = vim.api.nvim_get_current_win()
    local layout = vim.fn.winlayout()
    vim.cmd("GripZoom")
    assert(vim.api.nvim_get_current_win() == help and vim.deep_equal(layout, vim.fn.winlayout()),
      "zoom resized split windows from a floating help pane")
  elseif scenario == "tabs" then
    local first = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_win(wins.query)
    local before = snapshot()
    zoom(wins.query)
    vim.cmd("tabnew")
    vim.cmd("vsplit")
    local second = snapshot()
    vim.cmd("GripZoom")
    vim.cmd("GripZoom")
    assert(vim.deep_equal(second, snapshot()), "zoom state leaked between tabs")
    vim.cmd("GripZoom")
    vim.cmd("tabclose!")
    vim.api.nvim_set_current_tabpage(first)
    vim.cmd("GripZoom")
    assert(vim.deep_equal(before, snapshot()), "original tab did not restore")
    check_data()
  elseif scenario == "single" then
    vim.cmd("tabnew")
    local before = snapshot()
    vim.cmd("GripZoom")
    vim.cmd("GripZoom")
    assert(vim.deep_equal(before, snapshot()), "single-window zoom changed state")
  else
    error("unknown zoom scenario: " .. scenario)
  end
  return true
end
