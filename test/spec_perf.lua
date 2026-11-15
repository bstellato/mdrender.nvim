-- Large files: only the visible rows are decorated, so a redraw costs the same on a
-- 20,000-line file as on a short one. Most checks count work instead of timing it, so
-- they hold on any machine; one loose timing check catches what the counts miss.
-- MDRENDER_PERF_MS raises or lowers the time limit (default 25 ms).
local api = vim.api
local uv = vim.uv

local lines = dofile('test/gen_large.lua')(400) -- 21,085 lines, about 9,000 formulas
local limit_ms = tonumber(os.getenv('MDRENDER_PERF_MS')) or 25

local function open_large()
  local before = H.transmits()
  local buf = H.open(lines)
  return buf, H.transmits() - before
end

-- Rows of the plugin's marks.
local function rows(buf)
  local out = {}
  for _, d in ipairs(H.marks(buf)) do
    table.insert(out, d.row)
  end
  return out
end

-- Most marks a screen can need, with a screen of margin above and below.
local function mark_budget()
  return 3 * vim.o.lines * 6
end

return {
  { 'opening a large file decorates only the top', function()
    local buf = open_large()
    local r = rows(buf)
    H.ok(#r > 0, 'something decorated')
    H.ok(#r < mark_budget(), ('%d marks, budget %d'):format(#r, mark_budget()))
    H.ok(math.max(unpack(r)) < 3 * vim.o.lines, 'last decorated row: ' .. math.max(unpack(r)))
  end },

  { 'opening a large file renders only the visible formulas', function()
    H.math.clear() -- start with no cached images
    local _, sent = open_large()
    H.ok(sent < 150, sent .. ' images rendered at open')
  end },

  { 'jumping to the end decorates the end only', function()
    local buf = open_large()
    vim.cmd('normal! G')
    H.settle(buf)
    local r = rows(buf)
    local n = api.nvim_buf_line_count(buf)
    H.ok(#r > 0 and #r < mark_budget(), #r .. ' marks')
    H.ok(math.min(unpack(r)) > n - 3 * vim.o.lines, 'first decorated row: ' .. math.min(unpack(r)))
    local quote = n - 1
    while not lines[quote + 1]:match('^> ') do
      quote = quote - 1
    end
    H.ok(H.has_hl(quote, 'MdRenderQuote'), 'last quote decorated')
  end },

  { 'two windows on one buffer: both views decorated', function()
    local buf = open_large()
    vim.cmd('normal! G')
    vim.cmd('split')
    vim.cmd('normal! gg')
    H.settle(buf)
    local top, bottom = false, false
    local n = api.nvim_buf_line_count(buf)
    for _, row in ipairs(rows(buf)) do
      top = top or row < vim.o.lines
      bottom = bottom or row > n - vim.o.lines
    end
    H.ok(top and bottom, 'top and bottom both decorated')
    H.ok(#rows(buf) < 2 * mark_budget(), #rows(buf) .. ' marks')
  end },

  { 'scrolling decorates the new view', function()
    local buf = open_large()
    local target = 10000
    api.nvim_win_set_cursor(0, { target + 1, 0 })
    vim.cmd('normal! zt')
    H.settle(buf)
    local near = 0
    for _, row in ipairs(rows(buf)) do
      if row >= target and row < target + vim.o.lines then
        near = near + 1
      end
    end
    H.ok(near > 0, 'rows in view decorated')
  end },

  { 'an edit keeps the work bounded', function()
    local buf = open_large()
    api.nvim_win_set_cursor(0, { 5000, 0 })
    vim.cmd('normal! zz')
    H.settle(buf)
    api.nvim_buf_set_lines(buf, 5000, 5000, false, { 'An added line with $w_1$.' })
    H.settle(buf)
    H.ok(#rows(buf) < mark_budget(), #rows(buf) .. ' marks after the edit')
    H.ok(H.image(5000), 'added formula drawn')
  end },

  { 'after an edit the parse runs in the background and then draws', function()
    local buf = open_large()
    api.nvim_win_set_cursor(0, { 5000, 0 })
    vim.cmd('normal! zz')
    H.settle(buf)
    api.nvim_buf_set_lines(buf, 5000, 5000, false, { '# Added heading' })
    H.m._render(buf) -- asynchronous: may return before drawing
    local drawn = vim.wait(5000, function()
      return H.has_hl(5000, 'MdRenderH1')
    end, 10)
    H.ok(drawn, 'added heading drawn')
  end },

  { ('a cursor move redraws in under %d ms'):format(limit_ms), function()
    local buf = open_large()
    api.nvim_win_set_cursor(0, { 10000, 0 })
    vim.cmd('normal! zz')
    H.settle(buf)
    -- With slicing off, the parse and the drawing both finish inside the call.
    vim.g._ts_force_sync_parsing = true
    local times = {}
    for _ = 1, 21 do
      vim.cmd('normal! j')
      local t = uv.hrtime()
      H.m._render(buf)
      table.insert(times, (uv.hrtime() - t) / 1e6)
    end
    vim.g._ts_force_sync_parsing = nil
    table.sort(times)
    local median = times[11]
    H.ok(median < limit_ms, ('median redraw %.1f ms'):format(median))
  end },
}
