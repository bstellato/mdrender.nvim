-- Modules and settings: kitty, code, set, setting names, the command.
local kitty = require('mdrender.kitty')
local code = require('mdrender.code')

-- Capture vim.notify messages while f runs.
local function notices(f)
  local got, real = {}, vim.notify
  vim.notify = function(msg, level)
    table.insert(got, { msg = msg, level = level })
  end
  local ok, err = pcall(f)
  vim.notify = real
  assert(ok, err)
  return got
end

local function count(s, sub)
  local n, i = 0, 1
  while true do
    local a, b = s:find(sub, i, true)
    if not a then
      return n
    end
    n, i = n + 1, b + 1
  end
end

return {
  { 'kitty: one placeholder cell per column, one string per row', function()
    local rows = kitty.placeholder_rows(3, 2)
    H.eq(2, #rows, 'rows')
    for _, row in ipairs(rows) do
      H.eq(3, count(row, H.PLACEHOLDER), 'cells')
    end
    H.ok(rows[1] ~= rows[2], 'rows differ by their row diacritic')
  end },

  { 'kitty: large images are sent in 4096-byte chunks, then placed', function()
    local first = #H.sent
    kitty.transmit(4242, string.rep('A', 10000), 5, 2)
    local msgs = vim.list_slice(H.sent, first + 1)
    H.eq(4, #msgs, 'three chunks and a placement')
    H.ok(msgs[1]:find('a=t,f=100,t=d,q=2,i=4242,m=1', 1, true), 'first chunk: ' .. msgs[1]:sub(1, 40))
    H.ok(msgs[2]:find('^\27_Gm=1;'), 'middle chunk')
    H.ok(msgs[3]:find('^\27_Gm=0;'), 'last chunk')
    H.ok(msgs[4]:find('a=p,U=1,q=2,i=4242,c=5,r=2', 1, true), 'virtual placement')
  end },

  { 'kitty: the highlight group carries the image id as its colour', function()
    local name = kitty.hl(0x4D0042)
    H.eq('MdRenderImg' .. 0x4D0042, name, 'group name')
    H.eq(0x4D0042, vim.api.nvim_get_hl(0, { name = name }).fg, 'colour')
  end },

  { 'code: treesitter parsers are found and remembered', function()
    H.ok(code.has_parser('lua'), 'lua has a parser')
    H.ok(code.has_parser('Lua {.numberLines}'), 'label with attributes')
    H.ok(not code.has_parser('no-such-language'), 'unknown language')
    H.ok(not code.has_parser('???'), 'not a language name')
  end },

  { 'code: syntax-file colours for languages without a parser', function()
    local spans = code.highlight('python', { 'def f(x):', '    return 1  # one' })
    H.ok(#spans > 0, 'spans')
    local groups = {}
    for _, s in ipairs(spans) do
      groups[s[4]] = true
      H.ok(s[1] >= 0 and s[1] <= 1 and s[3] > s[2], 'span bounds')
    end
    H.ok(groups.Statement and groups.Comment, 'keyword and comment groups: ' .. vim.inspect(vim.tbl_keys(groups)))
    H.eq({}, code.highlight('no-such-language', { 'x' }), 'unknown language')
    H.eq({}, code.highlight('python', {}), 'no lines')
  end },

  { 'set: numbers, booleans and lists are converted', function()
    H.open({ '# x', '', 'end' }, 2)
    H.m.set('math.inline_size', '1.25')
    H.eq(1.25, H.m.config.math.inline_size, 'number')
    H.m.set('math.enabled', 'false')
    H.eq(false, H.m.config.math.enabled, 'boolean')
    H.m.set('bullets', '-, +')
    H.eq({ '-', '+' }, H.m.config.bullets, 'list')
    H.m.set('math.cell', '10,22')
    H.eq({ 10, 22 }, H.m.config.math.cell, 'number list')
    H.m.set('win_options.conceallevel', '3')
    H.eq(3, vim.wo.conceallevel, 'window option applied')
  end },

  { 'set: bad names and values are refused', function()
    local got = notices(function()
      H.m.set('no.such.setting', '1')
      H.m.set('math.scale', 'big')
      H.m.set('math', '1')
    end)
    H.eq(3, #got, 'errors: ' .. vim.inspect(got))
    for _, n in ipairs(got) do
      H.eq(vim.log.levels.ERROR, n.level, 'level of ' .. n.msg)
    end
    H.eq(2, H.m.config.math.scale, 'value kept')
  end },

  { 'setting names cover nested settings, for completion', function()
    local names = H.m.setting_names()
    for _, want in ipairs({ 'math.inline_size', 'math.cell', 'accent.dark', 'bullets', 'win_options.conceallevel' }) do
      H.ok(vim.tbl_contains(names, want), 'has ' .. want)
    end
    H.ok(not vim.tbl_contains(names, 'math'), 'no table names')
    H.eq(names, vim.fn.sort(vim.deepcopy(names)), 'sorted')
  end },

  { ':MdRender completes actions and settings, and rejects unknown ones', function()
    H.ok(vim.tbl_contains(vim.fn.getcompletion('MdRender ', 'cmdline'), 'toggle'), 'actions')
    H.ok(vim.tbl_contains(vim.fn.getcompletion('MdRender set ', 'cmdline'), 'math.scale'), 'settings')
    local got = notices(function()
      vim.cmd('MdRender frobnicate')
      vim.cmd('MdRender set')
    end)
    H.eq(2, #got, 'errors')
  end },

  { 'g:mdrender configures without a setup() call', function()
    local ok = vim.fn.system({
      'nvim', '--headless', '--clean', '-n', '--cmd', 'set rtp+=.',
      '--cmd', 'set termguicolors', '--cmd', "let g:mdrender = {'max_width': 42}",
      '-c', "lua io.write(require('mdrender').config.max_width)", '-c', 'qa!',
    })
    H.eq('42', vim.trim(ok), 'max_width from g:mdrender')
  end },
}
