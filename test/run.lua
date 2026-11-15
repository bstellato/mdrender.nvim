-- Test runner. From the repository root:
--   nvim --headless --clean -n --cmd 'set rtp+=.' -c 'luafile test/run.lua'
-- Runs every test/spec_*.lua and exits with the number of failures as status.
-- MDRENDER_TEST=<Lua pattern> runs only the tests whose "file: name" matches.
--
-- A test also fails when anything reports an error while it runs, including
-- autocommands, timers and scheduled callbacks (they set v:errmsg).
local passed, failed = 0, {}

local function fail(label, err)
  table.insert(failed, label)
  io.write('  FAIL  ' .. label .. '\n        ' .. tostring(err):gsub('\n', '\n        ') .. '\n')
end

local function run()
  _G.H = dofile('test/helpers.lua')
  local filter = os.getenv('MDRENDER_TEST')
  local files = vim.fn.glob('test/spec_*.lua', false, true)
  table.sort(files)
  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ':t:r'):gsub('^spec_', '')
    local ok, spec = pcall(dofile, file)
    if not ok then
      fail(name .. ': (loading the file)', spec)
      spec = {}
    end
    for _, case in ipairs(spec) do
      local label = name .. ': ' .. case[1]
      if not filter or label:match(filter) then
        H.reset()
        vim.v.errmsg = ''
        local ok2, err = xpcall(case[2], debug.traceback)
        -- Let pending timers and scheduled callbacks run, so their errors count here.
        vim.wait(20)
        if ok2 and vim.v.errmsg ~= '' then
          ok2, err = false, 'error reported while the test ran: ' .. vim.v.errmsg
        end
        if ok2 then
          passed = passed + 1
          io.write('  ok    ' .. label .. '\n')
        else
          fail(label, err)
        end
      end
    end
  end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  fail('(runner)', err)
end
io.write(('\n%d passed, %d failed\n'):format(passed, #failed))
for _, label in ipairs(failed) do
  io.write('  failed: ' .. label .. '\n')
end
io.flush()
vim.cmd(#failed == 0 and 'qa!' or ('cquit ' .. math.min(#failed, 255)))
