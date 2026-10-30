-- completion.lua: native SQL completion for the query pad.
-- Implements omnifunc (<C-x><C-o>), auto-trigger (TextChangedI), and
-- a first-class nvim-cmp source ({ name = 'dadbod_grip' }).
-- Works for all adapters. Handles DuckDB cross-database federation.
-- Supports SQL alias tracking: FROM employees e → e. completes employees cols.

local M = {}

local esc = require("dadbod-grip.sql").escape_literal

local _ag = vim.api.nvim_create_augroup("DadbodGripCompletion", { clear = true })

local CACHE_TTL = 300  -- 5 minutes

-- _cache[url] = { tables = { name -> [{column_name, data_type, is_nullable}] }, time }
local _cache = {}

-- ── Schema fetching ────────────────────────────────────────────────────────────

--- Fetch and cache schema for a database URL.
--- Returns { [table_name] = columns[] } where columns have column_name/data_type/is_nullable.
function M.get_schema(url)
  local now = os.time()
  local cached = _cache[url]
  if cached and (now - cached.time) < CACHE_TTL then
    return cached.tables
  end

  local db = require("dadbod-grip.db")

  -- Prefer batch fetch (single CLI spawn for DuckDB federation).
  -- Falls back to per-table when adapter doesn't support it.
  local tables
  if db.get_schema_batch then
    tables = db.get_schema_batch(url)
  end

  if not tables then
    local result, err = db.list_tables(url)
    if err or not result then return {} end
    tables = {}
    for _, t in ipairs(result) do
      local name = type(t) == "table" and (t.name or (t.rows and t.rows[1] and t.rows[1][1])) or t
      if name and name ~= "" then
        local cols, _ = db.get_column_info(name, url)
        tables[name] = cols or {}
      end
    end
  end

  _cache[url] = { tables = tables, time = now }
  return tables
end

--- Invalidate the cache for a given URL (call on connection switch or GripAttach/Detach).
function M.invalidate(url)
  _cache[url] = nil
  for bufnr, cached in pairs(M._alias_cache or {}) do
    if cached.url == url then M._alias_cache[bufnr] = nil end
  end
  -- Also invalidate any federated entries keyed as "url::alias"
  local prefix = url .. "::"
  for k in pairs(_cache) do
    if k:sub(1, #prefix) == prefix then
      _cache[k] = nil
    end
  end
end

--- Pre-warm the schema cache asynchronously so columns are ready before the first keypress.
--- Called after connection switch and after GripAttach. No-op if adapter lacks async batch.
--- All five adapters (duckdb, postgresql, mysql, sqlite, sqlserver) implement
--- get_schema_batch_async, each building the same SQL and reusing the same parser as its
--- synchronous get_schema_batch, so warming can never disagree with a later cold fetch.
function M.warm_schema(url)
  local db = require("dadbod-grip.db")
  if not db.get_schema_batch_async then return end
  db.get_schema_batch_async(url, function(schema)
    if schema then
      _cache[url] = { tables = schema, time = os.time() }
    end
  end)
end

-- ── Alias extraction ───────────────────────────────────────────────────────────

-- SQL keywords that cannot be unquoted table names or aliases here.
local _ALIAS_KEYWORDS = {
  WHERE=1, ON=1, SET=1, INNER=1, LEFT=1, RIGHT=1, FULL=1, OUTER=1, CROSS=1,
  HAVING=1, GROUP=1, ORDER=1, LIMIT=1, OFFSET=1, UNION=1, INTERSECT=1,
  EXCEPT=1, INTO=1, AS=1, AND=1, OR=1, NOT=1, NULL=1, IS=1, IN=1,
  LIKE=1, BETWEEN=1, WHEN=1, THEN=1, ELSE=1, END=1, CASE=1, WITH=1,
  SELECT=1, FROM=1, JOIN=1, BY=1, VALUES=1, RETURNING=1,
  INSERT=1, REPLACE=1, UPDATE=1, DELETE=1, DEFAULT=1, DO=1, USING=1,
}
local insert_modifiers = {
  LOW_PRIORITY=1, DELAYED=1, HIGH_PRIORITY=1, IGNORE=1,
}
local update_modifiers = { LOW_PRIORITY=1, IGNORE=1 }
local sqlite_conflicts = { ROLLBACK=1, ABORT=1, FAIL=1, IGNORE=1, REPLACE=1 }

local function identifier(token)
  return token and token.kind == "ident" and not _ALIAS_KEYWORDS[token.upper]
end
local function alias_name(token)
  if token.upper then return token.text:lower() end
  return token.text
end
local function alias_source(tokens, pos)
  if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil, pos end
  local names = { alias_name(tokens[pos]) }
  pos = pos + 1
  while tokens[pos] and tokens[pos].kind == "." do
    if not tokens[pos + 1] or tokens[pos + 1].kind ~= "ident" then return nil, pos end
    names[#names + 1] = alias_name(tokens[pos + 1])
    pos = pos + 2
  end
  return table.concat(names, "."), pos
end
local function add_alias(aliases, explicit, token, target, is_explicit)
  if not identifier(token) then return end
  local key = alias_name(token)
  if is_explicit or not explicit[key] then
    aliases[key], explicit[key] = target, is_explicit
  end
end
local function target_alias(tokens, aliases, explicit, target, pos, bare)
  local is_explicit = tokens[pos] and tokens[pos].upper == "AS"
  if is_explicit then pos = pos + 1 end
  if (is_explicit or bare) and identifier(tokens[pos]) then
    add_alias(aliases, explicit, tokens[pos], target, is_explicit)
    return pos + 1
  end
  return pos
end
local function column_list(tokens, pos)
  if not tokens[pos] or tokens[pos].kind ~= "(" then return nil, pos end
  local columns, at = {}, pos + 1
  while tokens[at] and tokens[at].kind == "ident" do
    columns[#columns + 1] = alias_name(tokens[at])
    at = at + 1
    if tokens[at] and tokens[at].kind == ")" then return columns, at + 1 end
    if not tokens[at] or tokens[at].kind ~= "," then break end
    at = at + 1
  end
  return nil, pos
end
-- SQL Server's first DELETE FROM names the target, where OUTPUT/OPTION
-- are clauses. Later FROM sources still allow ordinary aliases such as output.
local function delete_from_target(tokens, from_pos, matching)
  local pos = from_pos - 1
  if tokens[pos] and tokens[pos].upper == "PERCENT" then pos = pos - 1 end
  if tokens[pos] and tokens[pos].kind == ")" then
    -- Build this map only for an ambiguous SQL Server source. Repeated nested
    -- SELECT aliases named OUTPUT must not rescan the same parentheses.
    if not matching then
      matching = {}
      local stack = {}
      for idx, token in ipairs(tokens) do
        if token.kind == "(" then stack[#stack + 1] = idx
        elseif token.kind == ")" and #stack > 0 then
          matching[idx], stack[#stack] = stack[#stack], nil
        end
      end
    end
    local opening = matching[pos]
    pos = opening and opening - 1 or 0
    if not tokens[pos] or tokens[pos].upper ~= "TOP" then return false, matching end
    pos = pos - 1
  end
  return tokens[pos] and tokens[pos].upper == "DELETE", matching
end

local function insert_aliases(tokens, aliases, explicit, pos)
  if tokens[pos] and tokens[pos].upper == "OR" then pos = pos + 2 end
  while tokens[pos] and insert_modifiers[tokens[pos].upper] do pos = pos + 1 end
  if tokens[pos] and tokens[pos].upper == "INTO" then pos = pos + 1 end
  local target
  target, pos = alias_source(tokens, pos)
  if not target then return end
  pos = target_alias(tokens, aliases, explicit, target, pos, false)
  if tokens[pos] and tokens[pos].upper == "PARTITION" then
    local partitions, after = column_list(tokens, pos + 1)
    if not partitions then return end
    pos = after
  end
  local source_columns
  source_columns, pos = column_list(tokens, pos)
  -- Row aliases belong to VALUES/SET, never to SELECT expressions or UPSERT
  -- assignments. Parentheses keep functions and nested queries out of this scan.
  local depth, data_clause = 0, nil
  for idx = pos, #tokens do
    local token = tokens[idx]
    if token.kind == ";" then break end
    if token.kind == "(" then depth = depth + 1
    elseif token.kind == ")" then depth = depth - 1
    elseif depth == 0 then
      if token.upper == "SELECT" or token.upper == "ON" or token.upper == "RETURNING" then break end
      if not data_clause and (token.upper == "VALUES" or token.upper == "VALUE" or token.upper == "SET") then
        data_clause = token.upper
      elseif data_clause == "SET" and token.kind == "ident"
          and tokens[idx + 1] and tokens[idx + 1].kind == "="
          and (tokens[idx - 1].upper == "SET" or tokens[idx - 1].kind == ",") then
        source_columns = source_columns or {}
        source_columns[#source_columns + 1] = alias_name(token)
      elseif data_clause and token.upper == "AS" and identifier(tokens[idx + 1]) then
        local columns = column_list(tokens, idx + 2)
        if tokens[idx + 2] and tokens[idx + 2].kind == "(" and not columns then break end
        local value = columns and {
          table_name = target, columns = columns, source_columns = source_columns,
        } or target
        add_alias(aliases, explicit, tokens[idx + 1], value, true)
        break
      end
    end
  end
end

--- Return alias -> table mappings, ignoring SQL in strings and comments.
--- MySQL row aliases with explicit column aliases carry table_name, columns,
--- and source_columns instead of a string so completion can retain the renames.
function M.extract_aliases(sql_text, adapter_kind)
  if not sql_text or sql_text == "" then return {} end
  local tokens = require("dadbod-grip.sql_tokens").tokenize(sql_text, adapter_kind, "completion", true)
  if not tokens then return {} end
  local aliases, explicit = {}, {}
  local closing_parens
  for idx, token in ipairs(tokens) do
    local previous = tokens[idx - 1]
    if not previous or previous.kind ~= "." then
      local keyword = token.upper
      local update_target = keyword == "UPDATE"
        and not (previous and (previous.upper == "DO" or previous.upper == "KEY"))
        and not (tokens[idx + 1] and tokens[idx + 1].upper == "SET")
      if keyword == "FROM" or keyword == "JOIN" or update_target then
        local source_pos = idx + 1
        if adapter_kind == "postgresql" and tokens[source_pos] and tokens[source_pos].upper == "ONLY" then
          source_pos = source_pos + 1
        elseif update_target and adapter_kind == "sqlite"
            and tokens[source_pos] and tokens[source_pos].upper == "OR" then
          local action = tokens[source_pos + 1]
          source_pos = action and sqlite_conflicts[action.upper] and source_pos + 2 or #tokens + 1
        elseif update_target and adapter_kind == "mysql" then
          while tokens[source_pos] and update_modifiers[tokens[source_pos].upper] do
            source_pos = source_pos + 1
          end
        end
        local target, pos = alias_source(tokens, source_pos)
        if target then
          if adapter_kind == "mysql" and tokens[pos] and tokens[pos].upper == "PARTITION" then
            local partitions, after = column_list(tokens, pos + 1)
            pos = partitions and after or #tokens + 1
          end
          local clause = tokens[pos] and tokens[pos].upper
          local is_clause = false
          if adapter_kind == "sqlserver" and keyword == "FROM"
              and (clause == "OUTPUT" or clause == "OPTION") then
            is_clause, closing_parens = delete_from_target(tokens, idx, closing_parens)
          end
          if not is_clause then target_alias(tokens, aliases, explicit, target, pos, true) end
        end
      elseif keyword == "INSERT" or keyword == "REPLACE" then
        insert_aliases(tokens, aliases, explicit, idx + 1)
      end
    end
  end
  return aliases
end

-- ── Alias cache ────────────────────────────────────────────────────────────────
-- Tokenizing the whole buffer is only necessary after an edit or connection
-- change. Cursor-only completion requests reuse this map across all providers.

--- M._alias_cache[bufnr] = { tick = changedtick, url = url, aliases = {...} }
--- One entry per buffer (not a history of ticks) is enough: only the latest
--- buffer content is ever queried.
M._alias_cache = {}

--- Return the alias map for `bufnr`, re-parsing only when its changedtick
--- moved since the last call. Exported (not local) so all three call sites
--- (omnifunc, TextChangedI, cmp source) share one cache.
function M._get_cached_aliases(bufnr, url)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = M._alias_cache[bufnr]
  if cached and cached.tick == tick and cached.url == url then
    return cached.aliases
  end

  local kind = require("dadbod-grip.adapters").kind(require("dadbod-grip.db").resolved_url(url))
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local aliases = M.extract_aliases(table.concat(all_lines, "\n"), kind)
  M._alias_cache[bufnr] = { tick = tick, url = url, aliases = aliases }
  return aliases
end

-- Drop the cache entry when its buffer goes away so a stale/huge alias map
-- can't outlive the buffer it was parsed from. Not scoped to a specific
-- bufnr (unlike the per-buffer autocmds in setup_auto_complete below) since
-- omnifunc and the cmp source can populate entries for any buffer with vim.b.db set.
vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
  group = _ag,
  callback = function(args)
    M._alias_cache[args.buf] = nil
  end,
})

-- ── Context parsing ────────────────────────────────────────────────────────────

-- Read a trailing qualifier without interpreting text inside its quotes as SQL.
local function dotted_qualifier(before)
  local qualifier, word = before:match("([%w_$\128-\255]+)%.([%w_$\128-\255]*)$")
  if qualifier then return qualifier, word, false end
  local dot, quoted_word = before:match("()%.([%w_$\128-\255]*)$")
  if not dot then return end
  local finish = dot - 1
  local close = before:sub(finish, finish)
  local opening = close == "]" and "[" or close
  if close ~= '"' and close ~= "`" and close ~= "]" then return end
  local pos = finish - 1
  while pos > 0 do
    local ch = before:sub(pos, pos)
    if ch == close and before:sub(pos - 1, pos - 1) == close then
      pos = pos - 2
    elseif ch == opening then
      local text = before:sub(pos + 1, finish - 1)
      return text:gsub(close .. close, close), quoted_word, true
    else
      pos = pos - 1
    end
  end
end

--- Classify the SQL text before the cursor.
--- Returns one of: "table", "column", "dotted", "fed_column", or nil.
--- (Simple string result for the most common cases.)
function M.parse_context(before)
  if not before or before == "" then return nil end
  -- Strip trailing comment
  if before:match("^%-%-") then return nil end

  local up = before:upper()

  -- fed_column: alias.table.word (three-part, check first)
  if before:match("[%w_]+%.[%w_]+%.[%w_]*$") then
    return "fed_column"
  end

  -- dotted: qualifier.word (two-part)
  if dotted_qualifier(before) then
    return "dotted"
  end

  -- Table context: after FROM / JOIN / UPDATE / INSERT INTO
  if up:match("FROM%s+[%w_]*$")
    or up:match("JOIN%s+[%w_]*$")
    or up:match("UPDATE%s+[%w_]*$")
    or up:match("INTO%s+[%w_]*$") then
    return "table"
  end

  -- Column context: after SELECT / WHERE / ORDER BY / GROUP BY / HAVING
  if up:match("SELECT%s+.*$")
    or up:match("WHERE%s+.*$")
    or up:match("ORDER%s+BY%s+.*$")
    or up:match("GROUP%s+BY%s+.*$")
    or up:match("HAVING%s+.*$") then
    return "column"
  end

  return nil
end

--- Full context parse: returns structured table with type, word, qualifier, alias, table fields.
--- Used by omnifunc and by tests that need the full detail.
function M.parse_context_full(before)
  if not before or before == "" then return nil end
  if before:match("^%-%-") then return nil end

  -- fed_column: alias.table.word
  local alias, tbl, word = before:match("([%w_]+)%.([%w_]+)%.([%w_]*)$")
  if alias then
    return { type = "fed_column", alias = alias, table = tbl, word = word }
  end

  -- dotted: qualifier.word
  local qualifier, qword, quoted = dotted_qualifier(before)
  if qualifier then
    return { type = "dotted", qualifier = qualifier, word = qword, quoted = quoted }
  end

  local up = before:upper()

  -- Table context
  if up:match("FROM%s+[%w_]*$")
    or up:match("JOIN%s+[%w_]*$")
    or up:match("UPDATE%s+[%w_]*$")
    or up:match("INTO%s+[%w_]*$") then
    local word2 = before:match("([%w_]*)$") or ""
    return { type = "table", word = word2 }
  end

  -- Column context
  if up:match("SELECT%s+.*$")
    or up:match("WHERE%s+.*$")
    or up:match("ORDER%s+BY%s+.*$")
    or up:match("GROUP%s+BY%s+.*$")
    or up:match("HAVING%s+.*$") then
    local word2 = before:match("([%w_]*)$") or ""
    return { type = "column", word = word2 }
  end

  return nil
end

-- ── Completion items ───────────────────────────────────────────────────────────

--- Build a completion item from a string name and optional menu annotation.
local function item(word, menu)
  return { word = word, menu = menu or "" }
end

--- SQL keywords returned when no schema context is detected (start of query).
local SQL_KEYWORDS = {
  "SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
  "FULL OUTER JOIN", "ON", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET",
  "UNION", "UNION ALL", "INTERSECT", "EXCEPT", "WITH", "AS", "DISTINCT",
  "INSERT INTO", "UPDATE", "DELETE FROM", "SET", "VALUES",
  "AND", "OR", "NOT", "NULL", "IS NULL", "IS NOT NULL", "IN", "NOT IN",
  "LIKE", "ILIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END",
  "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST",
}

--- Return completion items for `before` (text before cursor) and the given URL.
--- Optional `aliases` table maps SQL alias -> table_name for dotted completion.
--- Returns array of { word, menu } items.
function M.complete(before, url, aliases)
  aliases = aliases or {}
  local ctx = M.parse_context_full(before)
  if not ctx then
    -- No SQL context yet: complete keywords by prefix (e.g. "SEL" -> "SELECT").
    local word = before:match("([%w_]*)$") or ""
    if word == "" then return {} end
    local up_word = word:upper()
    local kw_items = {}
    for _, kw in ipairs(SQL_KEYWORDS) do
      if kw:sub(1, #up_word) == up_word then
        table.insert(kw_items, item(kw, "[keyword]"))
      end
    end
    return kw_items
  end

  local schema = M.get_schema(url)
  local items = {}

  if ctx.type == "table" then
    -- Complete table names. Two match strategies:
    -- 1. Full-key prefix: "gr" matches "grip_test.butts", "us" matches "users".
    -- 2. Bare-name suffix: "bu" matches "butts" inside "grip_test.butts" and
    --    suggests the fully-qualified name. Only fires when word is non-empty
    --    (empty word already matches all names via strategy 1 with prefix "").
    for name, _ in pairs(schema) do
      if name:sub(1, #ctx.word) == ctx.word then
        table.insert(items, item(name, "[table]"))
      elseif ctx.word ~= "" then
        local bare = name:match("%.([^.]+)$")
        if bare and bare:sub(1, #ctx.word) == ctx.word then
          table.insert(items, item(name, "[table]"))
        end
      end
    end

  elseif ctx.type == "column" then
    -- Complete column names from all tables
    local seen = {}
    for _, cols in pairs(schema) do
      for _, col in ipairs(cols) do
        local cname = col.column_name
        if cname and not seen[cname] and cname:sub(1, #ctx.word) == ctx.word then
          seen[cname] = true
          table.insert(items, item(cname, "[" .. (col.data_type or "?") .. "]"))
        end
      end
    end

  elseif ctx.type == "dotted" then
    local q = ctx.qualifier
    -- Check if qualifier is a known table alias resolving to a local table
    local resolved = aliases[q] or (not ctx.quoted and aliases[q:lower()]) or q
    local row_alias = type(resolved) == "table" and resolved or nil
    local cols = schema[row_alias and row_alias.table_name or resolved]
    if cols then
      if row_alias then
        -- Column aliases rename the inserted values in their declared order.
        -- An explicit INSERT column list can differ from the table's order.
        local by_name = {}
        for _, col in ipairs(cols) do by_name[col.column_name] = col end
        for idx, cname in ipairs(row_alias.columns) do
          local source_name = row_alias.source_columns and row_alias.source_columns[idx]
          local col = source_name and by_name[source_name] or (not row_alias.source_columns and cols[idx])
          if cname:sub(1, #ctx.word) == ctx.word then
            table.insert(items, item(cname, "[" .. (col and col.data_type or "?") .. "]"))
          end
        end
      else
        -- qualifier is a table name (or aliased table): complete its columns
        for _, col in ipairs(cols) do
          local cname = col.column_name
          if cname and cname:sub(1, #ctx.word) == ctx.word then
            table.insert(items, item(cname, "[" .. (col.data_type or "?") .. "]"))
          end
        end
      end
    else
      -- Check the cache for "qualifier.tablename" keys: covers DuckDB federation
      -- (attached catalogs like supplier.shipments) and PG/native schemas (analytics.events).
      local prefix = q .. "."
      local found_in_cache = false
      for name, _ in pairs(schema) do
        if name:sub(1, #prefix) == prefix then
          found_in_cache = true
          local tname = name:sub(#prefix + 1)
          if tname:sub(1, #ctx.word) == ctx.word then
            table.insert(items, item(tname, "[table]"))
          end
        end
      end
      -- If nothing in the cache, fall through to a live DuckDB attachment query.
      -- Use duckdb_tables() which works for all attachment types (SQLite, PG, etc.).
      -- Never use catalog.information_schema: SQLite attachments have none.
      if not found_in_cache then
        local ok, duckdb = pcall(require, "dadbod-grip.adapters.duckdb")
        if ok then
          -- The attachment registry is keyed by the expanded URL (that is
          -- what db.resolve hands the adapter on every query), while `url`
          -- here is vim.b.db/vim.g.db -- the template.
          local atts = duckdb.get_attachments(require("dadbod-grip.db").resolved_url(url))
          for _, att in ipairs(atts) do
            if att.alias == q then
              local db = require("dadbod-grip.db")
              local safe_q = esc(q)
              local sql = string.format(
                "SELECT table_name FROM duckdb_tables() WHERE database_name = '%s' AND internal = false"
                  .. " UNION ALL SELECT view_name FROM duckdb_views() WHERE database_name = '%s' AND internal = false",
                safe_q, safe_q
              )
              local result, _ = db.query(sql, url)
              if result and result.rows then
                for _, row in ipairs(result.rows) do
                  local tname = row[1]
                  if tname and tname:sub(1, #ctx.word) == ctx.word then
                    table.insert(items, item(tname, "[table]"))
                  end
                end
              end
              break
            end
          end
        end
      end
    end

  elseif ctx.type == "fed_column" then
    -- Three-part: alias.table.word (e.g. supplier.shipments.col or analytics.events.col)
    -- Use the schema cache first (populated by get_schema → get_column_info).
    local cached_key = ctx.alias .. "." .. ctx.table
    local cached_cols = schema[cached_key]
    if cached_cols and #cached_cols > 0 then
      for _, col in ipairs(cached_cols) do
        local cname = col.column_name
        if cname and cname:sub(1, #ctx.word) == ctx.word then
          table.insert(items, item(cname, "[" .. (col.data_type or "?") .. "]"))
        end
      end
    else
      -- Fallback: live query for DuckDB attachments not yet cached.
      -- Use duckdb_columns() which works for all attachment types (SQLite, PG, etc.).
      -- Never use catalog.information_schema: SQLite attachments have none.
      local db = require("dadbod-grip.db")
      local safe_alias = esc(ctx.alias)
      local safe_table = esc(ctx.table)
      local sql = string.format(
        "SELECT column_name, data_type FROM duckdb_columns() WHERE database_name = '%s' AND table_name = '%s' AND internal = false",
        safe_alias, safe_table
      )
      local result, _ = db.query(sql, url)
      if result and result.rows then
        for _, row in ipairs(result.rows) do
          local cname, dtype = row[1], row[2]
          if cname and cname:sub(1, #ctx.word) == ctx.word then
            table.insert(items, item(cname, "[" .. (dtype or "?") .. "]"))
          end
        end
      end
    end
  end

  -- For table/column contexts, also append keyword matches for the typed word.
  -- This lets "SELECT col f" offer both column names AND "FROM".
  -- Skip dotted/fed_column: ctx.word is after the dot, keywords don't apply there.
  if ctx.type == "table" or ctx.type == "column" then
    local up_word = ctx.word:upper()
    if up_word ~= "" then
      for _, kw in ipairs(SQL_KEYWORDS) do
        if kw:sub(1, #up_word) == up_word then
          table.insert(items, item(kw, "[keyword]"))
        end
      end
    end
  end

  return items
end

-- ── Omnifunc ───────────────────────────────────────────────────────────────────

--- Standard Vim omnifunc. Set as vim.bo.omnifunc in query_pad.
--- Triggered by <C-x><C-o> in insert mode.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    -- Return the column where the current completion word starts.
    local line = vim.api.nvim_get_current_line()
    local col  = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte position
    local start = col
    -- Walk back over word chars only (alnum + underscore).
    -- Stop at dot, space, comma, etc. so dotted completions like
    -- "supplier.sh" replace only "sh" and leave "supplier." intact.
    while start > 0 do
      local ch = line:sub(start, start)
      if ch:match("[%w_]") then
        start = start - 1
      else
        break
      end
    end
    return start
  else
    -- Return completion items.
    local url = vim.b.db
    if not url or url == "" then return {} end

    local line = vim.api.nvim_get_current_line()
    local col  = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)

    -- Extract aliases from the full buffer so dotted completion resolves
    -- e.g. "SELECT e." where "FROM employees e" appears elsewhere in the query.
    -- Cached by changedtick: see M._get_cached_aliases.
    local aliases = M._get_cached_aliases(vim.api.nvim_get_current_buf(), url)

    -- For dotted completion, we need the full context including qualifier.
    -- The `base` from Vim may strip the qualifier, so we use `before` directly.
    local raw_items = M.complete(before, url, aliases)
    local vim_items = {}
    for _, it in ipairs(raw_items) do
      table.insert(vim_items, {
        word = it.word,
        menu = it.menu,
        icase = 1,
      })
    end
    return vim_items
  end
end

-- ── Auto-complete (as-you-type) ────────────────────────────────────────────────

--- Install a TextChangedI autocmd that fires vim.fn.complete() in insert mode.
--- Completions appear automatically without any keypress.
--- url_fn() returns the current connection URL (re-read live on each keystroke).
--- Kept separate from omnifunc so nvim-cmp users who add { name = 'omni' } also work.
function M.setup_auto_complete(bufnr, url_fn)
  -- Disable nvim-cmp and blink.cmp for this buffer so they don't conflict
  -- with grip's native popup. No-op when neither is installed.
  vim.api.nvim_create_autocmd("BufEnter", {
    group  = _ag,
    buffer = bufnr,
    callback = function()
      pcall(function() require("cmp").setup.buffer({ enabled = false }) end)
      vim.b[bufnr].completion = false
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group  = _ag,
    buffer = bufnr,
    callback = function()
      -- Defer past all TextChangedI handlers (blink, cmp, etc.) so their popups
      -- appear first. We only show our popup if nothing else is visible.
      vim.schedule(function()
        if vim.fn.pumvisible() == 1 then return end

        local url = url_fn()
        if not url or url == "" then return end

        local line = vim.api.nvim_get_current_line()
        local col  = vim.api.nvim_win_get_cursor(0)[2]
        local before = line:sub(1, col)

        -- Require ≥1 word char OR a trailing dot (dotted context: supplier., alias.).
        local word = before:match("([%w_]*)$") or ""
        local in_dotted_ctx = dotted_qualifier(before) ~= nil
        if word == "" and not in_dotted_ctx then return end

        local aliases = M._get_cached_aliases(bufnr, url)

        local raw = M.complete(before, url, aliases)
        if #raw == 0 then return end

        local start = col
        while start > 0 do
          local ch = line:sub(start, start)
          if ch:match("[%w_]") then start = start - 1 else break end
        end

        local vim_items = {}
        for _, it in ipairs(raw) do
          table.insert(vim_items, { word = it.word, menu = it.menu, icase = 1 })
        end
        if vim.fn.pumvisible() == 0 then
          vim.fn.complete(start + 1, vim_items)
        end
      end)
    end,
  })
end

-- ── nvim-cmp source ────────────────────────────────────────────────────────────

--- Register dadbod-grip as a first-class nvim-cmp completion source.
--- Safe to call multiple times; nvim-cmp deduplicates by source name.
--- Users opt in by adding { name = 'dadbod_grip' } to their cmp sources:
---
---   require('cmp').setup({ sources = { { name = 'dadbod_grip' }, ... } })
---
--- Without nvim-cmp installed this is a no-op.
function M.register_cmp_source()
  local ok, cmp = pcall(require, "cmp")
  if not ok then return end

  local source = {}

  -- Only active when a database connection is configured for the buffer.
  function source:is_available()
    local url = vim.b.db or vim.g.db
    return url ~= nil and url ~= ""
  end

  function source:get_debug_name()
    return "dadbod_grip"
  end

  -- Fire automatically on "." (dotted context: alias.col, tbl.col, fed.tbl.col).
  -- Keyword context (FROM, WHERE) is handled by the TextChangedI autocmd.
  function source:get_trigger_characters()
    return { "." }
  end

  function source:complete(params, callback)
    local url = vim.b.db or vim.g.db
    if not url or url == "" then callback(nil) return end

    local before = params.context.cursor_before_line
    local bufnr  = params.context.bufnr

    local aliases = M._get_cached_aliases(bufnr, url)

    local raw = M.complete(before, url, aliases)
    if #raw == 0 then callback(nil) return end

    -- Map to LSP CompletionItem format that nvim-cmp expects.
    local cmp_types = require("cmp.types")
    local items = {}
    for _, it in ipairs(raw) do
      -- Choose kind: table entries get Module icon, columns get Field icon.
      local kind = cmp_types.lsp.CompletionItemKind.Field
      if it.menu == "[table]" then
        kind = cmp_types.lsp.CompletionItemKind.Module
      end
      table.insert(items, {
        label      = it.word,
        detail     = it.menu,
        kind       = kind,
        insertText = it.word,
      })
    end
    callback({ items = items, isIncomplete = false })
  end

  cmp.register_source("dadbod_grip", source)
end

return M
