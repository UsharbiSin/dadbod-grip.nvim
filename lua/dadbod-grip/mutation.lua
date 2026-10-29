-- Parse only single-target UPDATE/DELETE previews. Token positions let us keep
-- predicate text intact while ignoring keywords inside comments or expressions.
local sql = require("dadbod-grip.sql")
local M = {}

local clauses = {
  SET = true, WHERE = true, ORDER = true, LIMIT = true, OFFSET = true,
  RETURNING = true, OUTPUT = true, USING = true, FROM = true, OPTION = true,
  JOIN = true, INNER = true, LEFT = true, RIGHT = true, FULL = true,
  CROSS = true, NATURAL = true, INDEXED = true, NOT = true, PARTITION = true,
  WITH = true, USE = true, FORCE = true, IGNORE = true,
}
local closes = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
local expression_prefix = {
  WHERE = true, AND = true, OR = true, NOT = true, IS = true, IN = true,
  LIKE = true, BETWEEN = true, WHEN = true, THEN = true, ELSE = true,
  CASE = true, COLLATE = true,
}

function M.parse(text, tokens, adapter_kind, stmt_type)
  local function reject()
    return nil, "Cannot safely preview this mutation; use a single target table"
  end
  if not tokens or not tokens[1] or tokens[1].upper ~= stmt_type
      or (stmt_type ~= "UPDATE" and stmt_type ~= "DELETE") then return reject() end

  local function raw(first, last)
    return text:sub(tokens[first].start, tokens[last or first].finish)
  end
  local function name(token)
    return adapter_kind == "postgresql" and token.upper and token.text:lower() or token.text
  end
  local function same(a, b)
    if adapter_kind == "postgresql" then return name(a) == name(b) end
    return a.text:lower() == b.text:lower()
  end
  local function path(pos)
    local parts = {}
    if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil, pos end
    repeat
      parts[#parts + 1] = tokens[pos]
      pos = pos + 1
      if not tokens[pos] or tokens[pos].kind ~= "." then break end
      pos = pos + 1
      if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil, pos end
    until false
    return parts, pos
  end

  -- A single terminal semicolon is allowed. Never preview only one statement
  -- while retaining multiple statements in the SQL offered for execution.
  local depth, stack, last = {}, {}, #tokens
  for idx, token in ipairs(tokens) do
    depth[idx] = #stack
    if token.kind == "(" or token.kind == "[" or token.kind == "{" then
      stack[#stack + 1] = token.kind
    elseif closes[token.kind] then
      if stack[#stack] ~= closes[token.kind] then return reject() end
      stack[#stack] = nil
    elseif token.kind == ";" then
      if #stack > 0 or idx ~= #tokens then return reject() end
      last = idx - 1
    end
  end
  if #stack > 0 then return reject() end

  local pos, delete_target = 2, nil
  if stmt_type == "DELETE" then
    if tokens[pos] and tokens[pos].upper ~= "FROM" then
      if tokens[pos].kind ~= "ident" then return reject() end
      delete_target = tokens[pos]
      pos = pos + 1
    end
    if not tokens[pos] or tokens[pos].upper ~= "FROM" then return reject() end
    pos = pos + 1
  end

  local target
  target, pos = path(pos)
  if not target then return reject() end
  -- These dialect modifiers are not target names. Reject them until their
  -- inheritance/conflict semantics can be represented by the preview.
  if (adapter_kind == "postgresql" and target[1].upper == "ONLY")
      or (adapter_kind == "mysql" and (target[1].upper == "LOW_PRIORITY"
        or target[1].upper == "IGNORE")) then return reject() end
  local names = {}
  for idx, token in ipairs(target) do
    -- Catalog APIs use a dotted table name; a literal dot inside one quoted
    -- component cannot be represented there without confusing table and schema.
    if token.text:find(".", 1, true) then return reject() end
    names[idx] = name(token)
  end
  local table_name = table.concat(names, ".")
  local source_sql = sql.quote_ident(table_name)

  local alias
  if tokens[pos] and tokens[pos].upper == "AS" then
    pos = pos + 1
    if not tokens[pos] or tokens[pos].kind ~= "ident" then return reject() end
    alias = tokens[pos]
  elseif tokens[pos] and tokens[pos].kind == "ident" and not clauses[tokens[pos].upper] then
    alias = tokens[pos]
  end
  if alias then
    source_sql = source_sql .. " AS " .. raw(pos)
    pos = pos + 1
  end
  if delete_target and not same(delete_target, alias or target[#target]) then return reject() end

  local set_start
  if stmt_type == "UPDATE" then
    if not tokens[pos] or tokens[pos].upper ~= "SET" then return reject() end
    set_start, pos = pos + 1, pos + 1
  elseif pos <= last and tokens[pos].upper ~= "WHERE"
      and tokens[pos].upper ~= "ORDER" and tokens[pos].upper ~= "LIMIT"
      and tokens[pos].upper ~= "RETURNING"
      and (tokens[pos].upper ~= "OPTION" or adapter_kind ~= "sqlserver") then
    return reject()
  end

  local where_idx, tail_idx
  for idx = pos, last do
    local token = tokens[idx]
    local previous, following = tokens[idx - 1], tokens[idx + 1]
    if depth[idx] == 0 and (not previous or previous.kind ~= ".")
        and (not following or following.kind ~= ".") then
      local keyword = token.upper
      -- UPDATE FROM adds another source, but DISTINCT FROM is an expression
      -- operator. Once WHERE starts, source clauses can only be nested queries.
      if not where_idx and ((keyword == "FROM" and tokens[idx - 1].upper ~= "DISTINCT")
          or keyword == "OUTPUT") then return reject() end
      if keyword == "WHERE" then
        if where_idx then return reject() end
        where_idx = idx
      elseif keyword == "RETURNING" or keyword == "LIMIT"
          or (keyword == "OPTION" and adapter_kind == "sqlserver")
          or (keyword == "ORDER" and following and following.upper == "BY") then
        -- Some dialects allow these words as unquoted columns. An assignment
        -- or expression operand cannot start a trailing statement clause.
        local operand = (following and following.kind == "=")
          or (previous and (expression_prefix[previous.upper]
            or previous.kind:match("^[=+*/%%<>!~|&^,:@-]$")))
        if not operand then
          -- A real trailing clause cannot precede the statement's WHERE.
          -- Refuse an ambiguous keyword instead of silently dropping a filter.
          if not where_idx then
            for later = idx + 1, last do
              if depth[later] == 0 and tokens[later].upper == "WHERE"
                  and tokens[later - 1].kind ~= "."
                  and (not tokens[later + 1] or tokens[later + 1].kind ~= ".") then return reject() end
            end
          end
          tail_idx = idx
          break
        end
      end
    end
  end

  local result = { table_name = table_name, source_sql = source_sql, assignments = {} }
  if where_idx then
    local end_token = tail_idx and tail_idx - 1 or last
    if where_idx + 1 > end_token then return reject() end
    -- Exclude trailing comments so a removed clause cannot leave a line comment
    -- swallowing SQL appended by an adapter; internal newlines stay intact.
    local finish = tokens[end_token].finish
    result.where = vim.trim(text:sub(tokens[where_idx].finish + 1, finish))
  end

  -- Only literals have a known new value without executing the mutation.
  -- Expressions and subqueries remain unstaged rather than displaying SQL as data.
  local function literal(first, finish)
    if first > finish then return false end
    local token, value = tokens[first], raw(first, finish)
    if first == finish then
      if token.upper == "NULL" then return true, nil end
      if token.kind == "literal" and value:sub(1, 1) == "'" then
        if token.escape_string or ((adapter_kind == "mysql" or adapter_kind == "postgresql")
            and value:find("\\", 1, true)) then return false end
        return true, token.text
      end
      if token.kind == "literal" and value:match("^%$") then
        local delimiter = value:match("^(%$[%w_]*%$)")
        if delimiter then return true, value:sub(#delimiter + 1, -#delimiter - 1) end
      end
    end
    if value:match("^[+-]?%d+%.?%d*$") or value:match("^[+-]?%.%d+$")
        or value:match("^[+-]?%d+%.?%d*[eE][+-]?%d+$") then return true, value end
    return false
  end

  local function assignment(first, finish)
    local fields, next_pos = path(first)
    if not fields or next_pos > finish or tokens[next_pos].kind ~= "=" then return end
    if #fields > 1 then
      local qualifiers = alias and { alias } or target
      local matches = #fields - 1 == #qualifiers
      if matches then
        for idx = 1, #qualifiers do
          if not same(fields[idx], qualifiers[idx]) then matches = false; break end
        end
      end
      if not matches and not alias and #fields == 2 then matches = same(fields[1], target[#target]) end
      if not matches then return end
    end
    local known, value = literal(next_pos + 1, finish)
    if known then
      result.assignments[#result.assignments + 1] = { column = name(fields[#fields]), value = value }
    end
  end
  if set_start then
    local finish = (where_idx or tail_idx or (last + 1)) - 1
    if finish < set_start then return reject() end
    local first = set_start
    for idx = first, finish do
      if depth[idx] == 0 and tokens[idx].kind == "," then
        assignment(first, idx - 1)
        first = idx + 1
      end
    end
    assignment(first, finish)
  end
  return result
end

return M
