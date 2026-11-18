-- Shared setup and assertions for the test suite (see test/run.lua).
local H = {}
local api = vim.api

-- Bytes meant for the terminal (Kitty graphics) are recorded instead of sent.
H.sent = {}
api.nvim_ui_send = function(data)
  table.insert(H.sent, data)
end

vim.o.termguicolors = true
vim.o.columns, vim.o.lines = 100, 40
vim.o.swapfile = false

H.m = require('mdrender')
H.math = require('mdrender.math')
H.m.setup({})
H.ns = api.nvim_get_namespaces().mdrender
H.PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
local defaults = vim.deepcopy(H.m.config)

--- Start each test from one empty window and the default settings.
function H.reset()
  vim.o.columns, vim.o.lines = 100, 40
  vim.cmd('silent! only!')
  vim.cmd('enew!')
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and buf ~= api.nvim_get_current_buf() then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  H.math._grace_ms(1000)
  for k in pairs(H.m.config) do
    H.m.config[k] = vim.deepcopy(defaults[k])
  end
end

--- Redraw now, wait until every requested formula has an answer, and redraw again.
--- The parse runs synchronously here, so each redraw is complete when this returns.
function H.settle(buf)
  buf = buf or api.nvim_get_current_buf()
  -- A background parse started earlier (on attach, say) finishes first.
  local parser = vim.treesitter.get_parser(buf, 'markdown')
  vim.wait(20000, function()
    return next(parser._ranges_being_parsed or {}) == nil
  end, 10)
  vim.g._ts_force_sync_parsing = true
  H.m._render(buf)
  local done = vim.wait(20000, function()
    return H.math.pending_count() == 0
  end, 10)
  H.m._render(buf)
  vim.g._ts_force_sync_parsing = nil
  assert(done, 'math renderer did not answer within 20 s')
end

--- Open the lines as a Markdown buffer in the current window, rendered and settled.
function H.open(lines, cursor_row)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(0, buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  if cursor_row then
    api.nvim_win_set_cursor(0, { cursor_row + 1, 0 })
  end
  H.settle(buf)
  return buf
end

--- Move the cursor to a 0-based row and redraw.
function H.cursor(row)
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  H.settle()
end

--- Extmarks of the plugin, as {row = , col = , ...details}, optionally on one row.
function H.marks(buf, row)
  buf = buf or api.nvim_get_current_buf()
  local s, e = 0, -1
  if row then
    s, e = { row, 0 }, { row, -1 }
  end
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, H.ns, s, e, { details = true })) do
    local d = m[4]
    d.row, d.col = m[2], m[3]
    table.insert(out, d)
  end
  return out
end

--- Text of a mark's virtual text, all chunks joined.
function H.vtext(d)
  local parts = {}
  for _, chunk in ipairs(d.virt_text or {}) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

--- The first mark on `row` for which pred(details) is true, or nil.
function H.find(row, pred, buf)
  for _, d in ipairs(H.marks(buf, row)) do
    if pred(d) then
      return d
    end
  end
end

function H.has_hl(row, group, buf)
  return H.find(row, function(d)
    return d.hl_group == group
  end, buf) ~= nil
end

--- A mark on `row` that draws a math image (placeholder cells in a MdRenderImg group).
function H.image(row, buf)
  return H.find(row, function(d)
    local chunk = d.virt_text and d.virt_text[1]
    return chunk and chunk[2] and chunk[2]:match('^MdRenderImg') and chunk[1]:find(H.PLACEHOLDER, 1, true)
  end, buf)
end

--- Number of images sent to the terminal so far.
function H.transmits()
  local n = 0
  for _, s in ipairs(H.sent) do
    if s:find('a=t,f=100', 1, true) then
      n = n + 1
    end
  end
  return n
end

function H.eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(('%s: expected %s, got %s'):format(what or 'value', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function H.ok(cond, what)
  if not cond then
    error(what or 'assertion failed', 2)
  end
end

return H
