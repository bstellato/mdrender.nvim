-- Math images: a persistent Node process turns TeX into PNGs (MathJax + resvg),
-- cached by formula so each one is rendered and transmitted once.
local M = {}

local kitty = require('mdrender.kitty')

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local node_dir = root .. '/node'

local job, buffer = nil, ''
local pending = {} -- request id -> cache key
local cache = {} -- key -> {state, id, cols, rows, png, err}
local next_req, next_img = 0, 0x4D0000
local building = false
M.on_update = function() end

local function installed()
  return vim.uv.fs_stat(node_dir .. '/node_modules/mathjax-full') ~= nil
end

function M.build(cb)
  if building then
    return
  end
  if vim.fn.executable('npm') == 0 then
    vim.notify('mdrender: npm not found; math rendering is off', vim.log.levels.WARN)
    return
  end
  building = true
  vim.notify('mdrender: installing the math renderer (npm install)...')
  vim.system({ 'npm', 'install', '--no-audit', '--no-fund' }, { cwd = node_dir }, function(res)
    building = false
    vim.schedule(function()
      if res.code == 0 then
        vim.notify('mdrender: math renderer installed')
        if cb then
          cb()
        end
      else
        vim.notify('mdrender: npm install failed\n' .. (res.stderr or ''), vim.log.levels.ERROR)
      end
    end)
  end)
end

local function on_reply(line)
  local ok, reply = pcall(vim.json.decode, line)
  if not ok or type(reply) ~= 'table' then
    return
  end
  local key = pending[reply.id]
  pending[reply.id] = nil
  local entry = key and cache[key]
  if not entry then
    return
  end
  if reply.ok then
    next_img = next_img + 1
    entry.state, entry.id = 'ready', next_img
    entry.cols, entry.rows, entry.png = reply.cols, reply.rows, reply.png
    entry.hl = kitty.hl(entry.id)
    entry.lines = kitty.placeholder_rows(entry.cols, entry.rows)
    kitty.transmit(entry.id, entry.png, entry.cols, entry.rows)
  else
    entry.state, entry.err = 'error', reply.error or 'render error'
  end
  M.on_update()
end

local function start()
  if job then
    return true
  end
  if vim.fn.executable('node') == 0 then
    return false
  end
  if not installed() then
    M.build(M.on_update)
    return false
  end
  job = vim.system({ 'node', node_dir .. '/render.js' }, {
    stdin = true,
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      buffer = buffer .. data
      local lines = vim.split(buffer, '\n', { plain = true })
      buffer = table.remove(lines)
      vim.schedule(function()
        for _, line in ipairs(lines) do
          if line ~= '' then
            on_reply(line)
          end
        end
      end)
    end,
  }, function()
    job = nil
    for id, key in pairs(pending) do
      cache[key] = nil
      pending[id] = nil
    end
  end)
  return true
end

--- Look up a formula. Returns the cache entry (state: pending|ready|error),
--- or nil when the renderer is unavailable.
---@param opts {tex: string, display: boolean, fg: string, cw: number, ch: number, max_cols: integer, min_rows: integer, cfg: table}
function M.get(opts)
  local key = table.concat({
    opts.tex, opts.display and 'D' or 'I', opts.fg, opts.cw, opts.ch,
    opts.display and opts.max_cols or 0, opts.min_rows or 0,
  }, '\0')
  local entry = cache[key]
  if entry then
    return entry
  end
  if not start() then
    return nil
  end
  next_req = next_req + 1
  cache[key] = { state = 'pending' }
  pending[next_req] = key
  local cfg = opts.cfg
  job:write(vim.json.encode({
    id = next_req,
    tex = opts.tex,
    display = opts.display,
    fg = opts.fg,
    cw = opts.cw,
    ch = opts.ch,
    max_cols = opts.max_cols,
    min_rows = opts.min_rows,
    scale = cfg.scale,
    weight = cfg.weight,
    inline_em = cfg.inline_size,
    display_em = cfg.display_size,
    baseline = cfg.baseline,
    macros = next(cfg.macros) and cfg.macros or nil,
  }) .. '\n')
  return cache[key]
end

-- Formulas sent to the renderer and not answered yet (for the tests).
function M.pending_count()
  return vim.tbl_count(pending)
end

--- Recreate the highlight groups that carry the image ids (after `:highlight clear`).
function M.restore_highlights()
  for _, e in pairs(cache) do
    if e.state == 'ready' then
      kitty.hl(e.id)
    end
  end
end

--- Send every cached image again (after a terminal re-attach drops them).
function M.retransmit()
  for _, e in pairs(cache) do
    if e.state == 'ready' then
      kitty.transmit(e.id, e.png, e.cols, e.rows)
    end
  end
end

--- Forget all images (colours or cell size changed).
function M.clear()
  for key, e in pairs(cache) do
    if e.state == 'ready' then
      kitty.delete(e.id)
    end
    cache[key] = nil
  end
end

function M.stop()
  M.clear()
  if job then
    job:kill('sigterm')
    job = nil
  end
end

return M
