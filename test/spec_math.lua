-- Math images: inline, display, fenced, errors, the cursor line, caching, colours.
-- Needs the Node renderer (`cd node && npm install`).
local api = vim.api

local doc = {
  'Inline $x^2$ here.', -- 0
  '', -- 1
  '$$', -- 2
  '\\int_0^1 x\\,dx', -- 3
  '$$', -- 4
  '', -- 5
  '```math', -- 6
  'a^2 + b^2 = c^2', -- 7
  '```', -- 8
  '', -- 9
  'Broken $\\frac{a$ here.', -- 10
  '', -- 11
  'end', -- 12
}
local last = #doc - 1

-- Up to Neovim 0.12 a line wraps by its raw width, hidden text included.
local old_wrap = vim.fn.has('nvim-0.13') == 0
local long = 'x_{1}' .. string.rep('+x_{1}', 45) -- 275 columns: three rows in a window of 100
local wrapped = { 'Text', '$$', long, '$$', '', '```math', long, '```', '', 'end' }

return {
  { 'the renderer is installed', function()
    H.ok(vim.uv.fs_stat('node/node_modules/mathjax-full'), 'run `cd node && npm install` first')
  end },

  { 'inline math is drawn as an image', function()
    H.open(doc, last)
    local img = H.image(0)
    H.ok(img, 'image on the inline formula')
    H.eq(7, img.col, 'image starts at the formula')
  end },

  { 'display math: every source line replaced, source hidden', function()
    H.open(doc, last)
    for row = 2, 4 do
      local img = H.find(row, function(d) return d.virt_text_win_col ~= nil end)
      H.ok(img and img.virt_text[1][1]:find(H.PLACEHOLDER, 1, true), 'image row on line ' .. row)
      H.ok(H.find(row, function(d) return d.conceal == '' end), 'source hidden on line ' .. row)
    end
  end },

  { 'math fences are drawn like display math', function()
    H.open(doc, last)
    H.ok(H.find(7, function(d) return d.virt_text_win_col ~= nil end), 'image in the fence')
  end },

  { 'display math: a source line that wraps gets an image row on each screen row', function()
    local buf = H.open(wrapped, #wrapped - 1)
    local win = api.nvim_get_current_win()
    local cpo = vim.o.cpoptions
    -- Breaks at word boundaries, breaks at the window edge, and rows of two widths
    -- ("n" in 'cpoptions': wrapped rows also use the number column).
    local setups = {
      function() end,
      function() vim.wo.linebreak = false end,
      function() vim.wo.number, vim.o.cpoptions = true, cpo .. 'n' end,
    }
    for k, setup in ipairs(setups) do
      setup()
      H.settle(buf)
      vim.cmd('redraw')
      local what = ' (setup ' .. k .. ')'
      local textoff = vim.fn.getwininfo(win)[1].textoff
      -- The lines drawn over (0-based): the `$$` block, and the body of the math fence.
      for _, block in ipairs({ { 1, 3 }, { 6, 6 } }) do
        local first, lines = block[1], block[2] - block[1] + 1
        local top = vim.fn.screenpos(win, first + 1, 1).row
        local n = vim.fn.screenpos(win, block[2] + 2, 1).row - top
        -- Up to Neovim 0.12 the long line takes three rows; from 0.13 hidden text does not wrap.
        H.eq(lines + (old_wrap and 2 or 0), n, 'screen rows of the block at line ' .. first .. what)
        local rows, seen = {}, {}
        for row = first, block[2] do
          for _, d in ipairs(H.marks(nil, row)) do
            if d.virt_text_win_col then
              local r = vim.fn.screenpos(win, row + 1, d.col + 1).row
              table.insert(rows, r)
              H.ok(not seen[d.virt_text[1][1]], 'a different image row on screen row ' .. r)
              seen[d.virt_text[1][1]] = true
              if d.col > 0 then
                H.eq(r - 1, vim.fn.screenpos(win, row + 1, d.col).row, 'mark at the first column of screen row ' .. r)
              end
              H.ok(
                vim.fn.screenstring(r, textoff + d.virt_text_win_col + 1):find(H.PLACEHOLDER, 1, true),
                'image cell drawn on screen row ' .. r .. what
              )
            end
          end
        end
        H.eq(vim.fn.range(top, top + n - 1), rows, 'screen rows with an image row')
        H.ok(not H.find(block[2], function(d) return d.virt_lines ~= nil end), 'no rows added below')
      end
    end
    vim.wo.number, vim.o.cpoptions = false, cpo
  end },

  { 'display math: a line that ends at the window edge takes no extra row', function()
    local buf = H.open({ '$$', 'xx' .. string.rep('+x', 99), '$$', '', 'end' }, 4) -- 200 columns
    vim.wo.linebreak = false
    H.settle(buf)
    local n = 0
    for _, d in ipairs(H.marks(nil, 1)) do
      n = n + (d.virt_text_win_col and 1 or 0)
    end
    H.eq(old_wrap and 2 or 1, n, 'image rows on the long line')
  end },

  { 'display math below the window: the wrapped rows are placed before they scroll in', function()
    local doc = {}
    for i = 1, 50 do
      doc[i] = 'line ' .. i
    end
    vim.list_extend(doc, wrapped)
    H.open(doc, 0) -- 38 rows show; the block is in the margin that is decorated ahead
    local n = 0
    for row = 51, 53 do
      for _, d in ipairs(H.marks(nil, row)) do
        n = n + (d.virt_text_win_col and 1 or 0)
      end
    end
    H.eq(old_wrap and 5 or 3, n, 'image rows')
  end },

  { 'display math: a change of the wrapping options is drawn again', function()
    if not old_wrap then
      return -- the options do not change the rows of hidden text
    end
    H.open(wrapped, #wrapped - 1)
    local function image_rows()
      local n = 0
      for _, d in ipairs(H.marks(nil, 2)) do
        n = n + (d.virt_text_win_col and 1 or 0)
      end
      return n
    end
    H.eq(3, image_rows(), 'image rows on the long line')
    -- OptionSet is fired by hand: Neovim does not fire it while the test script runs.
    vim.cmd('setlocal nowrap')
    api.nvim_exec_autocmds('OptionSet', { pattern = 'wrap' })
    H.ok(vim.wait(2000, function() return image_rows() == 1 end, 10), 'one image row without wrapping')
    vim.cmd('setlocal wrap foldcolumn=9')
    api.nvim_exec_autocmds('OptionSet', { pattern = 'foldcolumn' })
    H.ok(vim.wait(2000, function() return image_rows() == 4 end, 10), 'four image rows in a narrower text area')
  end },

  { 'inline math across a line break is drawn after the break', function()
    if not old_wrap then
      return -- hiding the source before the break moves the break
    end
    local tex = '$\\alpha' .. string.rep('+\\alpha', 9) .. '$' -- 70 columns of source
    local line = string.rep('word ', 18) .. tex .. ' end' -- the formula starts at column 90
    H.open({ line, '', 'end' }, 2)
    vim.cmd('redraw')
    local win = api.nvim_get_current_win()
    local img = H.image(0)
    H.ok(img, 'image drawn')
    H.eq('overlay', img.virt_text_pos, 'drawn over the source')
    local r = vim.fn.screenpos(win, 1, img.col + 1).row
    H.eq(r - 1, vim.fn.screenpos(win, 1, img.col).row, 'image at the first column after the break')
    local cells = vim.fn.strchars(img.virt_text[1][1]) / 3 -- a placeholder and two diacritics per cell
    H.eq(r, vim.fn.screenpos(win, 1, img.col + cells).row, 'screen row of the last image cell')
    H.ok(H.find(0, function(d) return d.conceal == '' and d.col == 90 and d.end_col == img.col end),
      'source before the break hidden')
    H.ok(H.find(0, function(d) return d.conceal == '' and d.col == img.col + cells and d.end_col == 90 + #tex end),
      'source after the image hidden')
  end },

  { 'inline math is drawn at its start when the cells fit on the row, and never across a break', function()
    if not old_wrap then
      return
    end
    -- The formula starts at every column from 70 to 99 of a window 100 columns wide.
    local doc = {}
    for pad = 70, 99 do
      vim.list_extend(doc, { string.rep('w', pad - 1) .. ' $a + b + c + d + e + f + g$ end', '' })
    end
    vim.o.lines = 100
    local buf = H.open(doc, #doc - 1)
    local win = api.nvim_get_current_win()
    local function row_of(line, col)
      return vim.fn.screenpos(win, line + 1, col + 1).row
    end
    for _, linebreak in ipairs({ true, false }) do
      vim.wo.linebreak = linebreak
      H.settle(buf)
      vim.cmd('redraw')
      local moved = 0
      for line = 0, #doc - 2, 2 do
        local what = (' (line %d, linebreak %s)'):format(line, tostring(linebreak))
        local img = H.image(line)
        H.ok(img, 'image' .. what)
        local cells = vim.fn.strchars(img.virt_text[1][1]) / 3
        local start = line / 2 + 70
        -- Without 'linebreak' the row ends at column 100, wherever the words end.
        if not linebreak and start + cells <= 100 then
          H.eq({ 'overlay', start }, { img.virt_text_pos, img.col }, 'image at the start of the formula' .. what)
        elseif img.virt_text_pos == 'overlay' then
          moved = moved + (img.col > start and 1 or 0)
          H.eq(row_of(line, img.col), row_of(line, img.col + cells - 1), 'screen row of the last image cell' .. what)
        end
      end
      H.ok(moved > 0, 'some images drawn after the break')
    end
    vim.o.lines = 40
  end },

  { 'a broken formula shows the TeX error', function()
    H.open(doc, last)
    local err = H.find(10, function(d) return d.virt_text_pos == 'eol' end)
    H.ok(err, 'error shown')
    H.ok(H.vtext(err):find('Missing close brace', 1, true), 'error text: ' .. H.vtext(err))
    H.eq('MdRenderMathError', err.virt_text[1][2], 'error colour')
  end },

  { 'the cursor line shows the source', function()
    H.open(doc, last)
    H.cursor(0)
    H.ok(not H.image(0), 'no image on the cursor line')
    H.ok(H.find(3, function(d) return d.virt_text_win_col ~= nil end), 'other formulas still drawn')
    H.cursor(3)
    H.ok(not H.find(3, function(d) return d.virt_text_win_col ~= nil end), 'display source with the cursor inside')
    H.ok(H.image(0), 'inline image back')
  end },

  { 'moving the cursor reuses the images', function()
    H.math.clear() -- counts below must not depend on earlier tests
    H.open(doc, last)
    local before = H.transmits()
    for _, row in ipairs({ 0, 3, 7, 10, 12, 0, 12 }) do
      H.cursor(row)
    end
    H.eq(before, H.transmits(), 'images sent after cursor moves')
  end },

  { 'editing a formula renders only that one', function()
    H.math.clear() -- counts below must not depend on earlier tests
    local buf = H.open(doc, last)
    local before = H.transmits()
    api.nvim_buf_set_lines(buf, 0, 1, false, { 'Inline $x^3$ here.' })
    H.settle(buf)
    H.eq(before + 1, H.transmits(), 'images sent after the edit')
    H.ok(H.image(0), 'new image drawn')
  end },

  { 'the same formula twice is rendered once', function()
    H.math.clear() -- counts below must not depend on earlier tests
    local before = H.transmits()
    H.open({ '$y_1$ and $y_1$ and $y_1$', '', 'end' }, 2)
    H.eq(before + 1, H.transmits(), 'images sent')
  end },

  { 'past the cache cap, the oldest images off screen are dropped', function()
    H.math.clear()
    local sent = #H.sent -- deletes from the clear above do not count
    H.m.config.math.cache_mb = 8000 / 2 ^ 20 -- a few inline images
    local buf = H.open({ '$a_{1}$', '', 'end' }, 2)
    for i = 2, 12 do
      api.nvim_buf_set_lines(buf, 0, 1, false, { ('$a_{%d}$'):format(i) })
      H.settle(buf)
    end
    H.ok(H.math.cache_bytes() <= 8000, 'cache within the cap: ' .. H.math.cache_bytes())
    H.ok(H.image(0), 'the formula on screen is drawn')
    local deletes = 0
    for i = sent + 1, #H.sent do
      deletes = deletes + (H.sent[i]:find('a=d,d=I', 1, true) and 1 or 0)
    end
    H.ok(deletes > 0, 'dropped images deleted from the terminal')
    -- A dropped formula is rendered again when it comes back.
    local before = H.transmits()
    api.nvim_buf_set_lines(buf, 0, 1, false, { '$a_{1}$' })
    H.settle(buf)
    H.eq(before + 1, H.transmits(), 'dropped formula sent again')
    H.ok(H.image(0), 'dropped formula drawn again')
  end },

  { 'images on screen stay past the cache cap', function()
    H.math.clear()
    H.m.config.math.cache_mb = 1000 / 2 ^ 20 -- less than the formulas below
    local lines = {}
    for i = 1, 10 do
      table.insert(lines, ('$b_{%d}$'):format(i))
      table.insert(lines, '')
    end
    table.insert(lines, 'end')
    local buf = H.open(lines, #lines - 1)
    H.ok(H.math.cache_bytes() > 1000, 'over the cap: ' .. H.math.cache_bytes())
    for i = 0, 9 do
      H.ok(H.image(2 * i), 'image on row ' .. 2 * i)
    end
    -- A new formula goes over the cap again; the ones on screen are not dropped.
    local before = H.transmits()
    H.cursor(1)
    api.nvim_buf_set_lines(buf, -2, -1, false, { '$c_{1}$' })
    H.settle(buf)
    H.eq(before + 1, H.transmits(), 'only the new formula was sent')
    for i = 0, 10 do
      H.ok(H.image(2 * i), 'image on row ' .. 2 * i .. ' after the new formula')
    end
  end },

  { 'answers that are never drawn do not stay in the cache', function()
    H.math.clear()
    H.math._grace_ms(50)
    H.m.config.math.cache_mb = 8000 / 2 ^ 20
    -- Request many formulas, then close the buffer before the answers arrive.
    local lines = {}
    for i = 1, 20 do
      table.insert(lines, ('$d_{%d}$ and more'):format(i))
    end
    local buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(0, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.g._ts_force_sync_parsing = true
    H.m._render(buf)
    H.ok(H.math.pending_count() >= 10, 'formulas requested: ' .. H.math.pending_count())
    vim.cmd('enew!')
    api.nvim_buf_delete(buf, { force = true })
    vim.wait(20000, function() return H.math.pending_count() == 0 end, 10)
    H.ok(H.math.cache_bytes() > 8000, 'over the cap: ' .. H.math.cache_bytes())
    vim.wait(100)
    -- The next answer drops them.
    H.open({ '$e_{1}$', '', 'end' }, 2)
    H.ok(H.math.cache_bytes() <= 8000, 'back within the cap: ' .. H.math.cache_bytes())
    H.ok(H.image(0), 'new formula drawn')
  end },

  { 'clearing while formulas are rendering: late answers are ignored', function()
    H.math.clear()
    local buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(0, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { '$f_{1}$ and $f_{2}$', '', 'end' })
    vim.bo[buf].filetype = 'markdown'
    api.nvim_win_set_cursor(0, { 3, 0 })
    vim.g._ts_force_sync_parsing = true
    H.m._render(buf)
    H.eq(2, H.math.pending_count(), 'formulas requested')
    local before = H.transmits()
    H.math.clear() -- the same formulas are requested again below
    H.settle(buf)
    vim.wait(200) -- the first answers arrive too
    H.eq(before + 2, H.transmits(), 'each formula sent once')
    H.ok(H.image(0), 'drawn')
    H.math.clear()
    H.eq(0, H.math.cache_bytes(), 'bytes after clear')
  end },

  { 'image ids of dropped images are reused', function()
    H.math.clear()
    H.m.config.math.cache_mb = 8000 / 2 ^ 20
    local buf = H.open({ '$g_{1}$', '', 'end' }, 2)
    local before = H.math.ids_used()
    for i = 2, 30 do
      api.nvim_buf_set_lines(buf, 0, 1, false, { ('$g_{%d}$'):format(i) })
      H.settle(buf)
    end
    H.ok(H.math.ids_used() - before <= 10, 'new ids for 29 images: ' .. (H.math.ids_used() - before))
    H.ok(H.image(0), 'last formula drawn')
  end },

  { 'after a clear, ids still on screen are not given to new images', function()
    local a = H.open({ '$k_{1}$', '', 'end' }, 2)
    local old = H.image(0, a).virt_text[1][2]
    H.math.clear() -- a still shows the old image until its next redraw
    vim.cmd('vsplit')
    local b = H.open({ '$k_{2}$', '', 'end' }, 2)
    H.ok(H.image(0, b).virt_text[1][2] ~= old, 'new image got a fresh id')
  end },

  { 'math in a table cell stays past the cache cap', function()
    H.math.clear()
    H.m.config.math.cache_mb = 1000 / 2 ^ 20
    local buf = H.open({ '| a | b |', '|---|---|', '| $h_{1}$ | $h_{2}$ |', '', 'x', '', 'end' }, 6)
    H.ok(next(H.math.in_use()), 'table images drawn')
    local before = H.transmits()
    H.cursor(5)
    api.nvim_buf_set_lines(buf, 4, 5, false, { '$h_{3}$' })
    H.settle(buf)
    H.cursor(6)
    H.eq(before + 1, H.transmits(), 'only the new formula was sent')
  end },

  { 'clearing the cache frees every byte', function()
    H.open(doc, last)
    H.ok(H.math.cache_bytes() > 0, 'cache in use')
    H.math.clear()
    H.eq(0, H.math.cache_bytes(), 'bytes after clear')
  end },

  { 'a colour scheme change renders the images again', function()
    H.open(doc, last)
    local before = H.transmits()
    vim.cmd('doautocmd ColorScheme')
    H.settle()
    H.ok(H.transmits() >= before + 3, 'images sent again: ' .. (H.transmits() - before))
    H.ok(H.image(0), 'image drawn')
  end },

  { 'macros from the config', function()
    H.m.config.math.macros = { reals = '\\mathbf{R}' }
    H.m.set('math.scale', '2') -- applies the settings and clears the cache
    H.open({ '$x \\in \\reals$', '', 'end' }, 2)
    H.ok(H.image(0), 'macro expanded')
    H.ok(not H.find(0, function(d) return d.virt_text_pos == 'eol' end), 'no error')
  end },

  { 'math off: no images, source left as is', function()
    H.m.config.math.enabled = false
    H.open(doc, last)
    H.ok(not H.image(0), 'no inline image')
    H.ok(not H.find(3, function(d) return d.virt_text_win_col ~= nil end), 'no display image')
  end },

  { 'images are sent as Kitty graphics with Unicode placeholders', function()
    H.open({ '$z$', '', 'end' }, 2)
    local found = false
    for _, s in ipairs(H.sent) do
      if s:find('a=p,U=1', 1, true) then
        found = true
      end
    end
    H.ok(found, 'virtual placement sent')
    H.ok(H.image(0).virt_text[1][2]:match('^MdRenderImg%d+$'), 'image id in the highlight group')
  end },
}
