-- Shared lexer boundaries must remain strict outside completion.
local tokenize = require("dadbod-grip.sql_tokens").tokenize
local pass, fail = 0, 0
local function test(name, run)
  local ok, err = pcall(run)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

for _, case in ipairs({
  { "postgresql", "SELECT $1 FROM items i" },
  { "duckdb", "SELECT $1, $value FROM items i" },
  { "sqlite", "SELECT $1, $value::part(FROM) FROM items i" },
  { "sqlserver", "SELECT * FROM #items i" },
  { "sqlserver", "SELECT * FROM ##items i" },
  { "sqlserver", "SELECT /* outer /* inner */ outer */ * FROM items i" },
  { "sqlserver", "SELECT -- comment\r* FROM items i" },
}) do
  test("completion extensions do not widen strict checks: " .. case[2], function()
    for _, mode in ipairs({ false, true }) do
      assert(tokenize(case[2], case[1], mode) == nil, "strict tokenization must remain unsupported")
    end
    assert(tokenize(case[2], case[1], "completion", true), "completion must recognize the dialect syntax")
    local positioned = assert(tokenize(case[2], case[1], "completion_positions", true))
    assert(positioned[#positioned].finish == #case[2], "cursor context needs the final source position")
  end)
end

for _, comment in ipairs({ "/*+ \\q */", "/*+ SET_VAR(x=1) \\x */", "/*+ hint\n\\C utf8\n*/" }) do
  test("MySQL hint client commands cannot be discarded: " .. comment, function()
    local text = "UPDATE " .. comment .. "items SET value='x' WHERE id=2"
    for _, mode in ipairs({ false, true, "completion", "completion_positions" }) do
      assert(tokenize(text, "mysql", mode, true) == nil, "client command hidden by a hint")
    end
    assert(tokenize(text, "mysql", true, false, true) == nil, "normalizer must preserve this batch")
  end)
end

for _, comment in ipairs({ "/*+ MAX_EXECUTION_TIME(1000) */", "/* ordinary \\q comment */" }) do
  test("MySQL inert comment stays usable: " .. comment, function()
    local text = "UPDATE " .. comment .. "items SET value='x' WHERE id=2"
    for _, mode in ipairs({ false, true, "completion", "completion_positions" }) do
      assert(tokenize(text, "mysql", mode), "valid hint or ordinary comment rejected")
    end
  end)
end

for _, kind in ipairs({ "postgresql", "duckdb" }) do
  test(kind .. " dollar strings remain opaque before parameters", function()
    local tokens = assert(tokenize("SELECT $tag$ FROM fake $1 $tag$, $1 FROM items i", kind, "completion", true))
    local sources = 0
    for _, token in ipairs(tokens) do if token.upper == "FROM" then sources = sources + 1 end end
    assert(sources == 1, "string contents leaked into alias discovery")
  end)
end

test("SQLite parameter suffixes do not create source tokens", function()
  local tokens = assert(tokenize("SELECT $value::part(FROM/*x*/fake) FROM items i", "sqlite", "completion", true))
  local sources = 0
  for _, token in ipairs(tokens) do if token.upper == "FROM" then sources = sources + 1 end end
  assert(sources == 1, "parameter suffix leaked into alias discovery")
end)

print(string.format("\nsql_tokens_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
