-- Math images: a persistent Node process turns TeX into PNGs (MathJax + resvg),
-- cached by formula so each one is rendered and transmitted once. The cache is capped
-- (math.cache_mb): past the cap, the least recently used images not on screen are dropped.
local M = {}

local kitty = require('mdrender.kitty')

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local node_dir = root .. '/node'

local job, buffer = nil, ''
local pending = {} -- request id -> cache key
local cache = {} -- key -> {state, id, cols, rows, png, err, used, bytes, answered}
local next_req, next_img = 0, 0x4D0000
local clock, total, limit = 0, 0, math.huge -- lookups so far, cached bytes, cap in bytes
-- Image ids are reused, since Neovim cannot delete the highlight group of each one.
-- Ids of dropped images are free at once (no extmark shows them). After a clear, the
-- old extmarks stay until the next redraw, so those ids wait GRACE_MS (retired).
local free, retired, retired_until = {}, {}, 0
-- An answer is drawn by the redraw that follows it. Until then it is not on screen
-- but must stay; after GRACE_MS it can go like any other entry.
local GRACE_MS = 1000
M._grace_ms = function(ms) -- for the tests
  GRACE_MS = ms
end
local building = false
M.on_update = function() end
--- Image ids drawn in some buffer right now; these are never dropped. Set by init.lua.
M.in_use = function()
  return {}
end

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

local function new_id()
  if #retired > 0 and vim.uv.now() >= retired_until then
    vim.list_extend(free, retired)
    retired = {}
  end
  if #free > 0 then
    return table.remove(free)
  end
  next_img = next_img + 1
  return next_img
end

local function forget(key, ids)
  local e = cache[key]
  if e.state == 'ready' then
    kitty.delete(e.id)
    vim.api.nvim_set_hl(0, e.hl, {})
    table.insert(ids, e.id)
  end
  total = total - (e.bytes or 0)
  cache[key] = nil
end

-- Past the cap, drop the least recently used entries down to 3/4 of it. Pending
-- entries, answers not drawn yet and images on screen stay.
local function evict()
  if total <= limit then
    return
  end
  local shown = M.in_use()
  local now = vim.uv.now()
  local old = {}
  for key, e in pairs(cache) do
    local new = e.answered and now - e.answered < GRACE_MS
    if e.bytes and not new and not (e.id and shown[e.id]) then
      table.insert(old, key)
    end
  end
  table.sort(old, function(a, b)
    return cache[a].used < cache[b].used
  end)
  for _, key in ipairs(old) do
    if total <= 0.75 * limit then
      break
    end
    forget(key, free)
  end
end

local function on_reply(line)
  local ok, reply = pcall(vim.json.decode, line)
  if not ok or type(reply) ~= 'table' then
    return
  end
  local key = pending[reply.id]
  pending[reply.id] = nil
  local entry = key and cache[key]
  if not entry or entry.state ~= 'pending' then
    return
  end
  if reply.ok then
    entry.state, entry.id = 'ready', new_id()
    entry.cols, entry.rows, entry.png = reply.cols, reply.rows, reply.png
    entry.hl = kitty.hl(entry.id)
    entry.lines = kitty.placeholder_rows(entry.cols, entry.rows)
    kitty.transmit(entry.id, entry.png, entry.cols, entry.rows)
  else
    entry.state, entry.err = 'error', reply.error or 'render error'
  end
  entry.bytes, entry.answered = #key + #(entry.png or entry.err), vim.uv.now()
  total = total + entry.bytes
  evict()
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
  limit = opts.cfg.cache_mb * 1024 * 1024
  clock = clock + 1
  local entry = cache[key]
  if entry then
    entry.used, entry.answered = clock, nil
    return entry
  end
  if not start() then
    return nil
  end
  next_req = next_req + 1
  cache[key] = { state = 'pending', used = clock }
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

-- Bytes held by the cache (for the tests).
function M.cache_bytes()
  return total
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
  for key in pairs(cache) do
    forget(key, retired)
  end
  retired_until = vim.uv.now() + GRACE_MS
  pending = {} -- late answers are for the old settings
end

-- Image ids handed out so far (for the tests).
function M.ids_used()
  return next_img - 0x4D0000
end

function M.stop()
  M.clear()
  if job then
    job:kill('sigterm')
    job = nil
  end
end

return M
