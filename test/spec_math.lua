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
    H.m.config.math.cache_mb = 8000 / 2 ^ 20 -- a few inline images
    local buf = H.open({ '$a_{1}$', '', 'end' }, 2)
    for i = 2, 12 do
      api.nvim_buf_set_lines(buf, 0, 1, false, { ('$a_{%d}$'):format(i) })
      H.settle(buf)
    end
    H.ok(H.math.cache_bytes() <= 8000, 'cache within the cap: ' .. H.math.cache_bytes())
    H.ok(H.image(0), 'the formula on screen is drawn')
    local deletes = 0
    for _, s in ipairs(H.sent) do
      deletes = deletes + (s:find('a=d,d=I', 1, true) and 1 or 0)
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
