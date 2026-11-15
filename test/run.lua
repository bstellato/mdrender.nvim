-- Test runner. From the repository root:
--   nvim --headless --clean -n --cmd 'set rtp+=.' -c 'luafile test/run.lua'
-- Runs every test/spec_*.lua and exits with the number of failures as status.
-- MDRENDER_TEST=<Lua pattern> runs only the tests whose "file: name" matches.
_G.H = dofile('test/helpers.lua')

local filter = os.getenv('MDRENDER_TEST')
local files = vim.fn.glob('test/spec_*.lua', false, true)
table.sort(files)

local passed, failed = 0, {}
for _, file in ipairs(files) do
  local spec = dofile(file)
  for _, case in ipairs(spec) do
    local label = vim.fn.fnamemodify(file, ':t:r'):gsub('^spec_', '') .. ': ' .. case[1]
    if not filter or label:match(filter) then
      H.reset()
      local ok, err = xpcall(case[2], debug.traceback)
      if ok then
        passed = passed + 1
        io.write('  ok    ' .. label .. '\n')
      else
        table.insert(failed, label)
        io.write('  FAIL  ' .. label .. '\n' .. err:gsub('\n', '\n        ') .. '\n')
      end
    end
  end
end

io.write(('\n%d passed, %d failed\n'):format(passed, #failed))
for _, label in ipairs(failed) do
  io.write('  failed: ' .. label .. '\n')
end
io.flush()
vim.cmd(#failed == 0 and 'qa!' or ('cquit ' .. math.min(#failed, 255)))
