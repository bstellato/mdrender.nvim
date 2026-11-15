-- The paths real use takes: autocommands, timers, the screen-update hook and the
-- asynchronous parse. These tests never call the render function directly; they fire
-- the event and wait for its effect.
local api = vim.api

local function large()
  H.m.config.math.enabled = false
  return H.open(dofile('test/gen_large.lua')(400))
end

local function wait_for(pred, what, ms)
  H.ok(vim.wait(ms or 2000, pred, 5), what)
end

-- Marks of the plugin in the rows the window shows.
local function in_view(buf)
  local top, bot = vim.fn.line('w0') - 1, vim.fn.line('w$') - 1
  return #api.nvim_buf_get_extmarks(buf, H.ns, { top, 0 }, { bot, -1 }, {})
end

-- Replace the parser's parse for calls made by the plugin with a callback.
local function stub_parse(buf, fake)
  local parser = vim.treesitter.get_parser(buf, 'markdown')
  local real = parser.parse
  parser.parse = function(self, range, cb)
    if cb and debug.getinfo(2, 'S').source:match('mdrender/init%.lua$') then
      return fake(real, self, range, cb)
    end
    return real(self, range, cb)
  end
  return function()
    parser.parse = real
  end
end

return {
  { 'CursorMoved: the line under the cursor shows its source', function()
    local buf = H.open({ 'text', '', '---', '', 'end' }, 4)
    H.ok(H.find(2, function(d) return d.virt_text_pos == 'overlay' end), 'rule drawn')
    api.nvim_win_set_cursor(0, { 3, 0 })
    api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    wait_for(function()
      return not H.find(2, function(d) return d.virt_text_pos == 'overlay' end)
    end, 'rule source shown on the cursor line')
  end },

  { 'TextChanged: an edit is redrawn', function()
    local buf = H.open({ 'text', '', 'end' }, 2)
    api.nvim_buf_set_lines(buf, 0, 0, false, { '# Added', '' })
    api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    wait_for(function() return H.has_hl(0, 'MdRenderH1') end, 'added heading drawn')
  end },

  { 'WinScrolled: a scroll is redrawn', function()
    local buf = large()
    api.nvim_win_set_cursor(0, { 10001, 0 })
    vim.cmd('normal! zt')
    api.nvim_exec_autocmds('WinScrolled', {})
    wait_for(function() return in_view(buf) > 0 end, 'new view decorated')
  end },

  { 'a jump is decorated within the same screen update', function()
    local lines = {}
    for i = 1, 3000 do
      lines[#lines + 1] = i % 2 == 0 and '' or ('filler paragraph ' .. i)
    end
    -- The fence comes first: whatever it needs must not stop the rest being drawn.
    vim.list_extend(lines, { '```python', 'x = 1  # one', '```', '', '## Near the end', '', '- [ ] task', '- item', '', 'end' })
    local buf = H.open(lines)
    vim.cmd('redraw')
    vim.cmd('normal! G')
    vim.cmd('redraw') -- no event loop runs between the jump and the drawing
    local n = #lines
    local inline = vim.treesitter.get_parser(buf, 'markdown'):children().markdown_inline
    local trees = vim.tbl_count(inline:trees())
    H.ok(trees < 300, trees .. ' inline trees parsed: only the views, not the file')
    H.ok(H.has_hl(n - 6, 'MdRenderH2'), 'heading drawn in the same update')
    H.ok(H.find(n - 4, function(d) return d.conceal == '□' end), 'task drawn in the same update')
    -- Syntax-file colours need a scratch buffer, which a screen update cannot use;
    -- they follow right after.
    wait_for(function()
      return H.find(n - 9, function(d) return d.priority == 110 end) ~= nil
    end, 'python coloured right after the update')
  end },

  { 'a background parse draws when it finishes', function()
    local buf = H.open({ 'text', '', 'end' }, 2)
    local restore = stub_parse(buf, function(real, self, range, cb)
      real(self, range)
      vim.defer_fn(function() cb(nil, {}) end, 30)
    end)
    api.nvim_buf_set_lines(buf, 0, 0, false, { '# Later', '' })
    H.m._render(buf)
    H.ok(not H.has_hl(0, 'MdRenderH1'), 'not drawn before the parse ends')
    wait_for(function() return H.has_hl(0, 'MdRenderH1') end, 'drawn after the parse')
    restore()
  end },

  { 'a render that finishes late does not draw over a newer one', function()
    local buf = large()
    local calls = 0
    local restore = stub_parse(buf, function(real, self, range, cb)
      calls = calls + 1
      if calls == 1 then
        real(self, range)
        vim.defer_fn(function() cb(nil, {}) end, 50) -- the first render is slow
        return
      end
      return real(self, range, cb)
    end)
    H.m._render(buf) -- top of the file, slow
    vim.cmd('normal! G')
    H.m._render(buf) -- end of the file, done at once
    vim.wait(120)
    restore()
    local n = api.nvim_buf_line_count(buf)
    local first = H.marks(buf)[1]
    H.ok(first and first.row > n - 3 * vim.o.lines, 'decorations at the end, first row ' .. (first and first.row or -1))
  end },

  { 'a parse that times out keeps the decorations shown', function()
    local buf = H.open({ '# Title', '', 'text', '', 'end' }, 4)
    local before = #H.marks(buf)
    -- A redraw starts by clearing the plugin's marks; count those clears.
    local real_clear, clears = api.nvim_buf_clear_namespace, 0
    api.nvim_buf_clear_namespace = function(b, n, ...)
      if n == H.ns then
        clears = clears + 1
      end
      return real_clear(b, n, ...)
    end
    local restore = stub_parse(buf, function(_, _, _, cb)
      cb('TIMEOUT')
    end)
    api.nvim_buf_set_lines(buf, 2, 3, false, { 'changed' })
    local ok, err = pcall(H.m._render, buf)
    restore()
    api.nvim_buf_clear_namespace = real_clear
    assert(ok, err)
    H.eq(0, clears, 'redraws after the timeout')
    H.eq(before, #H.marks(buf), 'marks kept')
  end },

  { 'one screen above and below the view is decorated, nothing further', function()
    local buf = large()
    api.nvim_win_set_cursor(0, { 10001, 0 })
    vim.cmd('normal! zz')
    H.settle(buf)
    local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
    local lo, hi = info.topline - 1 - info.height, info.botline + info.height
    local above, below = false, false
    for _, d in ipairs(H.marks(buf)) do
      above = above or (d.row < info.topline - 1 and d.row >= lo)
      below = below or (d.row >= info.botline and d.row < hi)
      H.ok(d.row >= lo - 60 and d.row <= hi + 60, 'mark far from the view at row ' .. d.row)
    end
    H.ok(above and below, 'margin above and below decorated')
  end },

  { 'a block seen by two windows is drawn once', function()
    local lines = { '```python' }
    for i = 1, 400 do
      lines[#lines + 1] = 'x = ' .. i
    end
    vim.list_extend(lines, { '```', '', 'end' })
    local buf = H.open(lines)
    vim.cmd('split')
    vim.cmd('normal! G')
    H.settle(buf)
    for _, row in ipairs({ 5, #lines - 10 }) do
      local n = 0
      for _, d in ipairs(H.marks(buf, row)) do
        if d.line_hl_group == 'MdRenderCode' then
          n = n + 1
        end
      end
      H.eq(1, n, 'background marks on row ' .. row)
    end
  end },

  { 'redraws stay cheap after scrolling through the whole file', function()
    local buf = large()
    -- Parsing the whole file leaves an inline tree for every paragraph, as a scroll
    -- through the file does.
    local parser = vim.treesitter.get_parser(buf, 'markdown')
    parser:parse(true)
    H.ok(vim.tbl_count(parser:children().markdown_inline:trees()) > 5000, 'inline trees for the whole file')
    api.nvim_win_set_cursor(0, { 10001, 0 })
    vim.cmd('normal! zz')
    H.settle(buf)
    -- Count the capture queries one redraw runs: one per tree near the view.
    local meta = getmetatable(vim.treesitter.query.parse('markdown', '(document) @d')).__index
    local real, count = meta.iter_captures, 0
    meta.iter_captures = function(...)
      count = count + 1
      return real(...)
    end
    local ok, err = pcall(H.settle, buf)
    meta.iter_captures = real
    assert(ok, err)
    H.ok(count < 1000, count .. ' capture queries for two redraws')
  end },

  { 'fence languages are looked up once', function()
    local code = require('mdrender.code')
    local real, calls = vim.treesitter.language.add, 0
    vim.treesitter.language.add = function(...)
      calls = calls + 1
      return real(...)
    end
    local ok, err = pcall(function()
      H.ok(code.has_parser('lua {#once}'), 'found')
      H.ok(not code.has_parser('nolang {#once}'), 'missing')
      local first = calls
      H.ok(first > 0, 'looked up')
      code.has_parser('lua {#once}')
      code.has_parser('nolang {#once}')
      H.eq(first, calls, 'lookups after the first')
    end)
    vim.treesitter.language.add = real
    assert(ok, err)
  end },
}
