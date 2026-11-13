-- Kitty graphics protocol: send PNGs as bytes and place them with Unicode
-- placeholders, so images scroll with the buffer text.
local M = {}

local diacritics = require('mdrender.diacritics')
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
local CHUNK = 4096

local function send(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
  end
end

--- Transmit a PNG (base64) and create a virtual placement of cols x rows cells.
--- Bytes are sent inline (t=d): file-path transfer is not supported everywhere.
function M.transmit(id, png_b64, cols, rows)
  local pos, len, first = 1, #png_b64, true
  while pos <= len do
    local chunk = png_b64:sub(pos, pos + CHUNK - 1)
    pos = pos + CHUNK
    local more = pos <= len and 1 or 0
    local ctl = first and ('a=t,f=100,t=d,q=2,i=%d,m=%d'):format(id, more) or ('m=%d'):format(more)
    send('\27_G' .. ctl .. ';' .. chunk .. '\27\\')
    first = false
  end
  send(('\27_Ga=p,U=1,q=2,i=%d,c=%d,r=%d\27\\'):format(id, cols, rows))
end

function M.delete(id)
  send(('\27_Ga=d,d=I,q=2,i=%d\27\\'):format(id))
end

--- Highlight group whose foreground colour encodes the image id.
function M.hl(id)
  local name = 'MdRenderImg' .. id
  vim.api.nvim_set_hl(0, name, { fg = id, ctermfg = id % 256 })
  return name
end

--- One string of placeholder cells per image row.
function M.placeholder_rows(cols, rows)
  cols = math.min(cols, #diacritics)
  rows = math.min(rows, #diacritics)
  local out = {}
  for r = 1, rows do
    local cells = {}
    local rd = vim.fn.nr2char(diacritics[r])
    for c = 1, cols do
      cells[c] = PLACEHOLDER .. rd .. vim.fn.nr2char(diacritics[c])
    end
    out[r] = table.concat(cells)
  end
  return out
end

--- Cell size in pixels, or nil when the terminal does not report it.
function M.cell_size()
  local ok, ffi = pcall(require, 'ffi')
  if not ok then
    return nil
  end
  pcall(ffi.cdef, [[
    struct mdrender_winsize { unsigned short row, col, xpixel, ypixel; };
    int ioctl(int, unsigned long, ...);
    int open(const char *, int, ...);
    int close(int);
  ]])
  local TIOCGWINSZ = vim.fn.has('linux') == 1 and 0x5413 or 0x40087468
  local okc, w, h = pcall(function()
    local fd = ffi.C.open('/dev/tty', 0)
    if fd < 0 then
      return nil
    end
    local ws = ffi.new('struct mdrender_winsize')
    local rc = ffi.C.ioctl(fd, TIOCGWINSZ, ws)
    ffi.C.close(fd)
    if rc < 0 or ws.xpixel == 0 or ws.ypixel == 0 or ws.col == 0 or ws.row == 0 then
      return nil
    end
    return ws.xpixel / ws.col, ws.ypixel / ws.row
  end)
  if okc and w and h then
    return w, h
  end
  return nil
end

return M
