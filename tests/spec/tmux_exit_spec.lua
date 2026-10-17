-- Exercise the real exit gate against deterministic tmux process states.
local pass, fail = 0, 0
for _, case in ipairs({
  { "normal exit", { "1:0:" }, 0, 1 },
  { "dead pane before status", { "1::", "1:0:" }, 0, 2 },
  { "status before pane EOF", { "0:0:", "1:0:" }, 0, 2 },
  { "delayed failure", { "1::", "1:7:" }, 7, 2, "failed with status 7" },
  { "delayed signal", { "1::", "1::TERM" }, 1, 2, "exited on signal TERM" },
  { "missing status", { "1::" }, 1, 3, "exit status did not become available" },
  { "live pane", { "0::" }, 1, 3, "process did not exit" },
  { "invalid status", { "1:not-a-number:" }, 1, 3, "exit status did not become available" },
  { "tmux command failure", { "1:0:" }, 3, 1, "synthetic tmux failure", 3 },
}) do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(case[2], dir .. "/states")
  vim.fn.writefile({ "0" }, dir .. "/cursor")
  vim.fn.writefile(vim.split([=[#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == capture-pane ]]; then printf 'synthetic capture\n'; exit 0; fi
index="$(cat "$GRIP_TMUX_EXIT_CURSOR")"
printf '%s\n' "$((index+1))" > "$GRIP_TMUX_EXIT_CURSOR"
if [[ "${GRIP_TMUX_EXIT_CLI_RC:-0}" != 0 ]]; then
  printf 'synthetic tmux failure\n' >&2
  exit "$GRIP_TMUX_EXIT_CLI_RC"
fi
line="$(sed -n "$((index+1))p" "$GRIP_TMUX_EXIT_STATES")"
if [[ -z "$line" ]]; then line="$(tail -n 1 "$GRIP_TMUX_EXIT_STATES")"; fi
printf '%s\n' "$line"
]=], "\n"), dir .. "/tmux")
  vim.fn.setfperm(dir .. "/tmux", "rwx------")
  local ok, err = pcall(function()
    local result = vim.system({ "bash", "tests/fixtures/wait_for_tmux_exit.sh", "synthetic-only", "3", "0" }, {
      text = true, env = { PATH = dir .. ":" .. vim.env.PATH,
        GRIP_TMUX_EXIT_STATES = dir .. "/states", GRIP_TMUX_EXIT_CURSOR = dir .. "/cursor",
        GRIP_TMUX_EXIT_CLI_RC = tostring(case[6] or 0) },
    }):wait()
    assert(result.code == case[3], "expected exit " .. case[3] .. ", got " .. result.code .. ": " .. result.stderr)
    assert(tonumber(vim.fn.readfile(dir .. "/cursor")[1]) == case[4], "did not wait for the expected process state")
    if case[5] then assert(result.stderr:find(case[5], 1, true), result.stderr) end
  end)
  vim.fn.delete(dir, "rf")
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. case[1] .. ": " .. tostring(err)) end
end
print(string.format("tmux_exit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
