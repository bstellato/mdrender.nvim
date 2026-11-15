-- Time a full redraw on a large file:
--   nvim -l test/gen_large.lua 400 > /tmp/large.md
--   nvim --headless --clean -n --cmd 'set rtp+=.' /tmp/large.md -c 'luafile test/bench.lua'
vim.o.termguicolors = true
vim.o.columns, vim.o.lines = 120, 50
vim.api.nvim_ui_send = function() end
local m = require('mdrender')
m.setup({})
local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_get_namespaces().mdrender
local uv = vim.uv
local function ms(f)
  local t = uv.hrtime()
  f()
  return (uv.hrtime() - t) / 1e6
end
local function report(label, f, n)
  n = n or 5
  local best, sum = math.huge, 0
  for _ = 1, n do
    local t = ms(f)
    best, sum = math.min(best, t), sum + t
  end
  io.write(('%-34s best %7.1f ms   mean %7.1f ms\n'):format(label, best, sum / n))
end

io.write(('lines: %d\n'):format(vim.api.nvim_buf_line_count(buf)))
io.write(('first render (math requests): %.1f ms\n'):format(ms(function() m._render(buf) end)))
local t0 = uv.hrtime()
-- Wait until no formula is pending: renders triggered by replies run meanwhile.
vim.wait(60000, function()
  m._render(buf)
  for _, e in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do end
  return require('mdrender.math').pending_count() == 0
end, 200)
io.write(('all formulas ready after %.0f ms\n'):format((uv.hrtime() - t0) / 1e6))
io.write(('extmarks: %d\n'):format(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})))

report('render, cursor at top', function() m._render(buf) end)
vim.api.nvim_win_set_cursor(0, { math.floor(vim.api.nvim_buf_line_count(buf) / 2), 0 })
vim.cmd('normal! zz')
report('render, cursor in the middle', function() m._render(buf) end)
report('cursor move + render', function()
  vim.cmd('normal! j')
  m._render(buf)
end)
-- After an edit the parse runs in slices; time the blocking first slice, then the
-- whole parse with slicing turned off.
local row = vim.api.nvim_win_get_cursor(0)[1]
report('edit + render, blocking part', function()
  vim.api.nvim_buf_set_lines(buf, row, row, false, { 'new $z_1$ line' })
  m._render(buf)
end)
vim.wait(2000, function() return false end, 50)
vim.g._ts_force_sync_parsing = true
report('edit + render, synchronous parse', function()
  vim.api.nvim_buf_set_lines(buf, row, row, false, { 'new $z_1$ line' })
  m._render(buf)
end)
vim.g._ts_force_sync_parsing = nil

if os.getenv('PROFILE') then
  local prof = require('jit.p')
  prof.start('Fl', '/dev/stdout')
  for _ = 1, 5 do m._render(buf) end
  prof.stop()
end
vim.cmd('qa!')
