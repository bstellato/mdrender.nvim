-- mdrender.nvim: styled Markdown and rendered math in the buffer you edit.
local M = {}

local api = vim.api
local kitty = require('mdrender.kitty')
local mathr = require('mdrender.math')
local code = require('mdrender.code')

local ns = api.nvim_create_namespace('mdrender')
local group = api.nvim_create_augroup('mdrender', { clear = true })

M.config = {
  filetypes = { 'markdown' },
  max_width = 100, -- rules and centred display math use at most this many columns
  -- Colour of headings, strong text, links, list numbers and inline code, by background.
  -- Tailwind sky-500 and sky-600: a bright blue for dark backgrounds and a darker one
  -- for light backgrounds. A single string applies to both; false follows the colour scheme.
  accent = { dark = '#0ea5e9', light = '#0284c7' },
  -- Overrides for the MdRender* highlight groups, by short name,
  -- e.g. { Strong = { fg = '#ff8800', bold = true } }.
  highlights = {},
  -- Window options set on Markdown windows. Wrapped list items keep their indent.
  win_options = {
    conceallevel = 2,
    concealcursor = '',
    linebreak = true,
    breakindent = true,
    breakindentopt = 'list:-1',
  },
  bullets = { '●', '○', '◆' }, -- list markers by nesting level (the last one repeats)
  tasks = { '□', '■' }, -- open and done task boxes
  math = {
    enabled = true,
    inline_size = 0.9, -- font size of inline math, as a fraction of the cell height
    display_size = 1.0, -- same for display math
    weight = 12, -- outline added to the glyphs, in 1/1000 em (0 for the plain TeX weight)
    baseline = 0.76, -- text baseline position in a cell, from the top
    scale = 2, -- supersampling, for sharp images on high-density screens
    -- Cell size in pixels, used when the terminal does not report it. Only the ratio
    -- matters. If it is narrower than the real cell, inline math gets side margins; if it
    -- is wider, math is drawn slightly smaller.
    cell = { 9, 20 },
    macros = {}, -- MathJax macros, e.g. { reals = '\\mathbf{R}' }
    cache_mb = 32, -- image cache cap; past it, the least recently used images are dropped
  },
}

local state = {} -- buf -> {row, timer}
-- Up to Neovim 0.12, a line wraps by its raw width, hidden text included. From 0.13,
-- 'wrap' follows the concealed width.
local raw_wrap = vim.fn.has('nvim-0.13') == 0
local cell -- {cw, ch}
local fg_hex = '#000000'

-- Colours -------------------------------------------------------------------

local function channels(n)
  return bit.rshift(n, 16), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255)
end

local function blend(fg, bg, a)
  local r1, g1, b1 = channels(fg)
  local r2, g2, b2 = channels(bg)
  local function mix(x, y)
    return math.floor(x * a + y * (1 - a) + 0.5)
  end
  return mix(r1, r2) * 65536 + mix(g1, g2) * 256 + mix(b1, b2)
end

local function set_highlights()
  local dark = vim.o.background == 'dark'
  local normal = api.nvim_get_hl(0, { name = 'Normal', link = false })
  local fg = normal.fg or (dark and 0xe6edf3 or 0x1f2328)
  local bg = normal.bg or (dark and 0x0d1117 or 0xffffff)
  local function fg_of(name)
    return api.nvim_get_hl(0, { name = name, link = false }).fg
  end
  -- Some terminals draw bold barely heavier than normal text, so headings and strong
  -- text are also drawn in the accent colour.
  local choice = M.config.accent
  if type(choice) == 'table' then
    choice = dark and choice.dark or choice.light
  end
  local accent = choice and tonumber((choice:gsub('#', '')), 16)
  if not accent then
    accent = fg_of('Title')
    if not accent or accent == fg then
      accent = fg_of('Function') or fg_of('Special') or fg
    end
  end
  fg_hex = ('#%06x'):format(fg)

  local function hl(name, val)
    api.nvim_set_hl(0, 'MdRender' .. name, M.config.highlights[name] or val)
  end
  for level = 1, 6 do
    hl('H' .. level, { fg = level <= 2 and accent or blend(accent, bg, level == 6 and 0.6 or 0.85), bold = true })
  end
  hl('Strong', { fg = accent, bold = true })
  local code_bg = blend(fg, bg, 0.07)
  hl('Rule', { fg = blend(fg, bg, 0.25) })
  hl('Code', { bg = code_bg })
  hl('CodeInline', { fg = accent, bg = blend(fg, bg, 0.12) })
  hl('ListNumber', { fg = accent })
  hl('Link', { fg = accent, underline = true })
  hl('CodeLang', { fg = blend(fg, bg, 0.45), bg = code_bg, italic = true })
  hl('Bullet', { fg = blend(fg, bg, 0.6) })
  hl('Task', { fg = accent })
  hl('TaskDone', { fg = accent })
  hl('Quote', { fg = blend(fg, bg, 0.65), italic = true })
  hl('QuoteBar', { fg = blend(fg, bg, 0.35) })
  hl('TableBorder', { fg = blend(fg, bg, 0.35) })
  hl('TableHead', { fg = accent, bold = true })
  hl('MathError', { link = 'DiagnosticError' })
  -- Code that no syntax rule colours takes the normal text colour, not the scheme's
  -- raw-text colour.
  api.nvim_set_hl(0, '@markup.raw.block.markdown', { fg = fg })
end

local function update_cell()
  local w, h = kitty.cell_size()
  if not w then
    w, h = M.config.math.cell[1], M.config.math.cell[2]
  end
  cell = { w, h }
end

-- Queries -------------------------------------------------------------------

local queries
local function get_queries()
  if not queries then
    queries = {
      block = vim.treesitter.query.parse('markdown', [[
        (atx_heading) @heading
        (thematic_break) @rule
        (fenced_code_block) @code
        (block_quote) @quote
        [(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet
        [(list_marker_dot) (list_marker_parenthesis)] @number
        (task_list_marker_unchecked) @task
        (task_list_marker_checked) @task_done
        (pipe_table) @table
      ]]),
      inline = vim.treesitter.query.parse('markdown_inline', [[
        (latex_block) @math
        (code_span) @code
        (strong_emphasis) @strong
        [(emphasis_delimiter) (code_span_delimiter)] @hidden
        (inline_link) @link
      ]]),
    }
  end
  return queries
end

-- Rendering -----------------------------------------------------------------

local function last_row(node)
  local r1, _, r2, c2 = node:range()
  return r1, (c2 == 0 and r2 > r1) and r2 - 1 or r2
end

-- Rows to decorate: what the buffer's windows show, plus a screen of margin on each
-- side so that short scrolls reveal text that is already styled. A list of
-- non-overlapping {first, last} pairs (0-based, end-exclusive), in order.
local function visible_ranges(buf)
  local ranges = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    -- During a redraw botline can still describe the old view; topline is current.
    local bot = math.max(info.botline, info.topline - 1 + info.height)
    table.insert(ranges, { math.max(0, info.topline - 1 - info.height), bot + info.height })
  end
  table.sort(ranges, function(a, b)
    return a[1] < b[1]
  end)
  local merged = {}
  for _, r in ipairs(ranges) do
    local last = merged[#merged]
    if last and r[1] <= last[2] then
      last[2] = math.max(last[2], r[2])
    else
      table.insert(merged, r)
    end
  end
  return merged
end

-- Decorate the rows in `ranges`, once the parser has parsed them. In a screen update
-- (`in_redraw`) code that needs a scratch buffer is skipped; then it returns true, and
-- the caller draws again after the update.
local function draw(buf, parser, ranges, in_redraw)
  local incomplete = false
  if not api.nvim_buf_is_valid(buf) or not state[buf] then
    return
  end
  local win = vim.fn.bufwinid(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if win == -1 then
    return
  end
  state[buf].drawn = ranges
  -- Captures of a tree within the ranges. Trees outside them are skipped (after a
  -- scroll through the file there is one inline tree per paragraph parsed so far),
  -- and a node that spans two ranges is returned once.
  local function captures(query, tree)
    local root = tree:root()
    local t1, _, t2 = root:range()
    local seen = {}
    return coroutine.wrap(function()
      for _, r in ipairs(ranges) do
        if t1 < r[2] and t2 >= r[1] then
          for id, node in query:iter_captures(root, buf, r[1], r[2]) do
            local key = id .. ':' .. node:id()
            if not seen[key] then
              seen[key] = true
              coroutine.yield(id, node)
            end
          end
        end
      end
    end)
  end

  -- Some themes clear every highlight group without firing ColorScheme. Notice it
  -- here and define the groups again.
  if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'MdRenderRule' })) then
    set_highlights()
    mathr.restore_highlights()
  end

  -- Lines are read on demand: only the decorated ones are ever needed.
  local nlines = api.nvim_buf_line_count(buf)
  local lines = setmetatable({}, {
    __index = function(t, i)
      local line = api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
      rawset(t, i, line)
      return line
    end,
  })
  local cur = api.nvim_win_get_cursor(win)[1] - 1
  local info = vim.fn.getwininfo(win)[1]
  local win_width = math.max(20, info.width - info.textoff)
  local width = math.min(win_width, M.config.max_width)
  local cfg = M.config.math
  local math_on = cfg.enabled and vim.o.termguicolors
  local q = get_queries()

  local function mark(row, col, opts)
    pcall(api.nvim_buf_set_extmark, buf, ns, row, col, opts)
  end
  local function dw(s)
    return vim.fn.strdisplaywidth(s)
  end

  -- Width corrections for text that is hidden or replaced: row -> {c0, c1, shown}
  local adjust = {}
  local function add_adjust(row, c0, c1, shown)
    adjust[row] = adjust[row] or {}
    table.insert(adjust[row], { c0, c1, shown })
  end
  local function shown_width(row, c0, c1)
    local line = lines[row + 1]
    local w = dw(line:sub(c0 + 1, c1))
    if row ~= cur then
      for _, a in ipairs(adjust[row] or {}) do
        if a[1] >= c0 and a[2] <= c1 then
          w = w - dw(line:sub(a[1] + 1, a[2])) + a[3]
        end
      end
    end
    return w
  end

  local function lookup(tex, display, min_rows)
    return mathr.get({
      tex = tex, display = display, fg = fg_hex,
      cw = cell[1], ch = cell[2], max_cols = width - 2, min_rows = min_rows, cfg = cfg,
    })
  end

  local function math_error(row, entry)
    mark(row, 0, {
      virt_text = { { '  ⚠ ' .. entry.err, 'MdRenderMathError' } },
      virt_text_pos = 'eol',
    })
  end

  -- Screen row of the character at byte column c of a line. Under raw wrapping it is
  -- counted within the line (from 1), which also works for lines outside the window.
  local function screen_row(row, c)
    if not raw_wrap then
      return vim.fn.screenpos(win, row + 1, c + 1).row
    end
    local vcol = vim.fn.virtcol({ row + 1, c + 1 }, 0, win)
    return api.nvim_win_text_height(win, { start_row = row, end_row = row, start_vcol = 0, end_vcol = vcol }).all
  end
  -- The first byte column in lo..hi on a screen row past `top`, by bisection (hi is on one).
  local function next_row_col(row, lo, hi, top)
    while lo < hi do
      local mid = math.floor((lo + hi) / 2)
      if screen_row(row, mid) > top then
        hi = mid
      else
        lo = mid + 1
      end
    end
    return lo
  end
  -- Under raw wrapping a long source line takes several screen rows whatever is drawn
  -- over it. wrap_cols(row) lists the byte columns where the screen rows after the
  -- first one start (empty when the line fits, or when hidden text does not wrap).
  local wraps = {}
  local function wrap_cols(row)
    if not wraps[row] then
      local last, cols = #lines[row + 1] - 1, {}
      if raw_wrap and last >= 0 then
        for top = 1, screen_row(row, last) - 1 do
          cols[top] = next_row_col(row, cols[top - 1] or 0, last, top)
        end
      end
      wraps[row] = cols
    end
    return wraps[row]
  end
  -- Screen rows taken by the lines r1..r2.
  local function screen_rows(r1, r2)
    local n = 0
    for row = r1, r2 do
      n = n + 1 + #wrap_cols(row)
    end
    return n
  end

  -- Display math over the source lines r1..r2 (c1: start column on r1, c2: end column on r2).
  -- The image has at least one row per screen row of the source, so the source is
  -- replaced in place and the text below never moves; extra rows go below as virtual lines.
  -- Rows are drawn at a fixed window column, not as inline text: hidden source text
  -- still counts when Neovim wraps a line, and inline rows would wrap with it.
  local function place_display(r1, c1, r2, c2, entry)
    local n = 0
    local indent = dw(lines[r1 + 1]:sub(1, c1))
    local col = math.max(indent, math.floor((width - entry.cols) / 2))
    for row = r1, r2 do
      local line = lines[row + 1]
      local sc = row == r1 and c1 or math.min(c1, #line)
      local ec = row == r2 and c2 or #line
      if ec > sc then
        mark(row, sc, { end_col = ec, conceal = '' })
      end
      -- One image row on each screen row of the line.
      local starts = { sc }
      vim.list_extend(starts, wrap_cols(row))
      for _, c in ipairs(starts) do
        n = n + 1
        if entry.lines[n] then
          mark(row, c, { virt_text = { { entry.lines[n], entry.hl } }, virt_text_win_col = col })
        end
      end
    end
    if entry.rows > n then
      local extra = {}
      for j = n + 1, entry.rows do
        table.insert(extra, { { string.rep(' ', col) }, { entry.lines[j], entry.hl } })
      end
      mark(r2, 0, { virt_lines = extra })
    end
  end

  -- Inline math. Neovim wraps lines by their raw width: hidden text still counts, and
  -- inline virtual text adds to it. So the image is drawn over the first cells of the
  -- source and only the rest is hidden; the line then wraps exactly like the raw text.
  -- Overlays do not wrap. When the cells under the image straddle a screen-line break,
  -- the image goes over the source after the break instead, if that part is wide enough.
  -- Falls back to inline cells when the image is wider than the source it can cover.
  local function place_inline(r1, c1, r2, c2, entry)
    local line = lines[r1 + 1]
    local s = r1 == r2 and c1 or nil
    while s do
      -- s..b: the source cells under the image.
      local b, w = s, 0
      while b < c2 and w < entry.cols do
        local len = vim.str_utf_end(line, b + 1) + 1
        w = w + dw(line:sub(b + 1, b + len))
        b = b + len
      end
      if w ~= entry.cols then
        break
      end
      local top = screen_row(r1, s)
      if screen_row(r1, b - 1) == top then
        if s > c1 then
          mark(r1, c1, { end_col = s, conceal = '' })
        end
        mark(r1, s, { virt_text = { { entry.lines[1], entry.hl } }, virt_text_pos = 'overlay' })
        if c2 > b then
          mark(r1, b, { end_col = c2, conceal = '' })
        end
        return
      end
      -- Without raw wrapping, hiding the source before the break would move the break.
      s = raw_wrap and next_row_col(r1, s + 1, b - 1, top) or nil
    end
    mark(r1, c1, { end_row = r2, end_col = c2, conceal = '' })
    mark(r1, c1, { virt_text = { { entry.lines[1], entry.hl } }, virt_text_pos = 'inline' })
  end

  -- Inline pass: math, inline code, and width corrections.
  parser:for_each_tree(function(tree, ltree)
    if ltree:lang() ~= 'markdown_inline' then
      return
    end
    for id, node in captures(q.inline, tree) do
      local name = q.inline.captures[id]
      local r1, c1, r2, c2 = node:range()
      if name == 'code' then
        mark(r1, c1, { end_row = r2, end_col = c2, hl_group = 'MdRenderCodeInline' })
      elseif name == 'strong' then
        mark(r1, c1, { end_row = r2, end_col = c2, hl_group = 'MdRenderStrong' })
      elseif name == 'hidden' then
        add_adjust(r1, c1, c2, 0)
      elseif name == 'link' then
        local text = node:named_child(0)
        if text then
          local tr1, tc1, tr2, tc2 = text:range()
          mark(tr1, tc1, { end_row = tr2, end_col = tc2, hl_group = 'MdRenderLink' })
          if r1 == r2 then
            add_adjust(r1, c1, c2, dw(lines[r1 + 1]:sub(tc1 + 1, tc2)))
          end
        end
      elseif name == 'math' and math_on then
        local src = vim.treesitter.get_node_text(node, buf)
        local delim = src:match('^%$+') or '$'
        local tex = vim.trim(src:sub(#delim + 1, -#delim - 1))
        local standalone = lines[r1 + 1]:sub(1, c1):match('^%s*$') and lines[r2 + 1]:sub(c2 + 1):match('^%s*$')
        local display = #delim >= 2 and standalone ~= nil
        if tex ~= '' and not (cur >= r1 and cur <= r2) then
          local entry = lookup(tex, display, display and screen_rows(r1, r2) or nil)
          if entry and entry.state == 'error' then
            math_error(r2, entry)
          elseif entry and entry.state == 'ready' then
            if display then
              place_display(r1, c1, r2, c2, entry)
            else
              place_inline(r1, c1, r2, c2, entry)
              if r1 == r2 then
                add_adjust(r1, c1, c2, entry.cols)
              end
            end
          end
        end
      end
    end
  end)

  -- Tables are drawn, not decorated: the source rows are hidden and a laid-out copy is
  -- shown as virtual lines, with cells wrapped to fit the window. This works for any
  -- pane width and for tables whose source is not aligned. With the cursor inside the
  -- table, the raw source is shown.

  -- Split a cell's text into styled atoms: {text, hl, width, space?, solid?}.
  local function cell_atoms(text, base_hl)
    local atoms = {}
    local function add_text(str, hl)
      for word, space in str:gmatch('([^%s]*)(%s*)') do
        if word ~= '' then
          table.insert(atoms, { word, hl, dw(word) })
        end
        if space ~= '' then
          table.insert(atoms, { ' ', hl, 1, space = true })
        end
      end
    end
    local i, plain = 1, ''
    local function flush()
      if plain ~= '' then
        add_text(plain, base_hl)
        plain = ''
      end
    end
    local rules = {
      { '^%$([^$\n]+)%$', function(tex)
        local entry = math_on and lookup(vim.trim(tex), false)
        if entry and entry.state == 'ready' then
          table.insert(atoms, { entry.lines[1], entry.hl, entry.cols, solid = true })
        else
          add_text('$' .. tex .. '$', base_hl)
        end
      end },
      { '^`([^`\n]+)`', function(c)
        table.insert(atoms, { c, 'MdRenderCodeInline', dw(c) })
      end },
      { '^%*%*(.-)%*%*', function(t)
        add_text(t, 'MdRenderStrong')
      end },
      { '^%*([^*\n]+)%*', function(t)
        add_text(t, '@markup.italic')
      end },
      { '^%[([^%]\n]+)%]%([^)\n]*%)', function(t)
        add_text(t, 'MdRenderLink')
      end },
      { '^\\([|\\`*_$])', function(c)
        plain = plain .. c
      end, keep = true },
    }
    while i <= #text do
      local matched = false
      for _, rule in ipairs(rules) do
        local s, e, cap = text:find(rule[1], i)
        if s then
          if not rule.keep then
            flush()
          end
          rule[2](cap)
          i, matched = e + 1, true
          break
        end
      end
      if not matched then
        plain = plain .. text:sub(i, i)
        i = i + 1
      end
    end
    flush()
    return atoms
  end

  -- Break atoms into lines of at most `w` cells. Returns a list of {chunks, width}.
  local function wrap_atoms(atoms, w)
    local out, cur, cw = {}, {}, 0
    local function newline()
      while #cur > 0 and cur[#cur].space do
        cw = cw - cur[#cur][3]
        table.remove(cur)
      end
      table.insert(out, { cur, cw })
      cur, cw = {}, 0
    end
    for _, atom in ipairs(atoms) do
      if atom.space then
        if cw > 0 and cw + 1 <= w then
          table.insert(cur, atom)
          cw = cw + 1
        end
      else
        if cw > 0 and cw + atom[3] > w then
          newline()
        end
        if atom[3] > w and not atom.solid then
          -- A word longer than the column: split it by characters.
          local piece, pw = '', 0
          for _, ch in ipairs(vim.fn.split(atom[1], '\\zs')) do
            local c = dw(ch)
            if pw + c > w and pw > 0 then
              table.insert(cur, { piece, atom[2], pw })
              cw = cw + pw
              newline()
              piece, pw = '', 0
            end
            piece, pw = piece .. ch, pw + c
          end
          atom = { piece, atom[2], pw }
        end
        table.insert(cur, atom)
        cw = cw + atom[3]
      end
    end
    if #cur > 0 or #out == 0 then
      newline()
    end
    return out
  end

  local function table_block(node)
    local r1, r2 = last_row(node)
    if cur >= r1 and cur <= r2 then
      return
    end
    -- The drawn table hangs off a neighbouring line; without one, leave the source.
    local anchor, above
    if r2 + 1 < nlines then
      anchor, above = r2 + 1, true
    elseif r1 > 0 then
      anchor, above = r1 - 1, false
    else
      return
    end

    -- Cells of each row: split on unescaped pipes, drop the outer empty cells.
    local function split(line)
      local cells, cell, i = {}, '', 1
      line = vim.trim(line)
      while i <= #line do
        local ch = line:sub(i, i)
        if ch == '\\' and i < #line then
          cell = cell .. line:sub(i, i + 1)
          i = i + 1
        elseif ch == '|' then
          table.insert(cells, vim.trim(cell))
          cell = ''
        else
          cell = cell .. ch
        end
        i = i + 1
      end
      table.insert(cells, vim.trim(cell))
      if line:sub(1, 1) == '|' then
        table.remove(cells, 1)
      end
      if line:sub(-1) == '|' and line:sub(-2) ~= '\\|' then
        table.remove(cells)
      end
      return cells
    end

    local header = split(lines[r1 + 1])
    local ncol = #header
    if ncol == 0 or r2 < r1 + 1 then
      return
    end
    local align = {}
    for k, d in ipairs(split(lines[r1 + 2])) do
      local left, right = d:match('^:') ~= nil, d:match(':$') ~= nil
      align[k] = (left and right) and 'center' or (right and 'right' or 'left')
    end

    -- Atoms and natural column widths.
    local rows, widths = {}, {}
    for k = 1, ncol do
      widths[k] = 3
    end
    for row = r1, r2 do
      if row ~= r1 + 1 then
        local cells, atoms = split(lines[row + 1]), {}
        for k = 1, ncol do
          atoms[k] = cell_atoms(cells[k] or '', row == r1 and 'MdRenderTableHead' or nil)
          local w = 0
          for _, atom in ipairs(atoms[k]) do
            w = w + atom[3]
          end
          widths[k] = math.max(widths[k], w)
        end
        table.insert(rows, atoms)
      end
    end

    -- Narrow the widest columns until the table fits the window.
    local indent = #(lines[r1 + 1]:match('^%s*'))
    local function total()
      local t = indent + 3 * ncol + 1
      for k = 1, ncol do
        t = t + widths[k]
      end
      return t
    end
    while total() > win_width do
      local widest = 1
      for k = 2, ncol do
        if widths[k] > widths[widest] then
          widest = k
        end
      end
      if widths[widest] <= 6 then
        break
      end
      widths[widest] = widths[widest] - 1
    end

    local B = 'MdRenderTableBorder'
    local pad = string.rep(' ', indent)
    local function border(l, m, r)
      local parts = {}
      for k = 1, ncol do
        parts[k] = string.rep('─', widths[k] + 2)
      end
      return { { pad .. l .. table.concat(parts, m) .. r, B } }
    end
    -- Wrap every cell; when some row needs several lines, separate all rows with rules.
    local wrapped_rows, multiline = {}, false
    for n, atoms in ipairs(rows) do
      wrapped_rows[n] = {}
      for k = 1, ncol do
        wrapped_rows[n][k] = wrap_atoms(atoms[k], widths[k])
        multiline = multiline or #wrapped_rows[n][k] > 1
      end
    end
    local out = { border('┌', '┬', '┐') }
    for n, wrapped in ipairs(wrapped_rows) do
      local height = 1
      for k = 1, ncol do
        height = math.max(height, #wrapped[k])
      end
      for h = 1, height do
        local chunks = { { pad .. '│ ', B } }
        for k = 1, ncol do
          local line = wrapped[k][h] or { {}, 0 }
          local gap = math.max(0, widths[k] - line[2])
          local before = align[k] == 'right' and gap or (align[k] == 'center' and math.floor(gap / 2) or 0)
          if before > 0 then
            table.insert(chunks, { string.rep(' ', before) })
          end
          for _, atom in ipairs(line[1]) do
            table.insert(chunks, { atom[1], atom[2] })
          end
          if gap - before > 0 then
            table.insert(chunks, { string.rep(' ', gap - before) })
          end
          table.insert(chunks, { k < ncol and ' │ ' or ' │', B })
        end
        table.insert(out, chunks)
      end
      if n < #rows and (n == 1 or multiline) then
        table.insert(out, border('├', '┼', '┤'))
      end
    end
    table.insert(out, border('└', '┴', '┘'))

    for row = r1, r2 do
      mark(row, 0, { end_row = row, end_col = #lines[row + 1], conceal_lines = '' })
    end
    mark(anchor, 0, { virt_lines = out, virt_lines_above = above })
  end

  -- Block pass.
  parser:for_each_tree(function(tree, ltree)
    if ltree:lang() ~= 'markdown' then
      return
    end
    for id, node in captures(q.block, tree) do
      local name = q.block.captures[id]
      local r1, c1, _, c2 = node:range()
      local line = lines[r1 + 1] or ''
      if name == 'heading' then
        local marker = node:child(0)
        local level = marker and tonumber(marker:type():match('atx_h(%d)_marker'))
        if level then
          local _, mc1, _, mc2 = marker:range()
          mark(r1, mc1, { end_col = math.min(mc2 + 1, #line), conceal = '' })
          mark(r1, 0, { end_col = #line, hl_group = 'MdRenderH' .. level })
          if level <= 2 then
            mark(r1, 0, { virt_lines = { { { string.rep('─', width), 'MdRenderRule' } } } })
          end
        end
      elseif name == 'rule' then
        if r1 ~= cur then
          mark(r1, 0, { virt_text = { { string.rep('─', width), 'MdRenderRule' } }, virt_text_pos = 'overlay' })
        end
      elseif name == 'code' then
        local _, r2 = last_row(node)
        local lang
        for child in node:iter_children() do
          if child:type() == 'info_string' then
            lang = vim.trim(vim.treesitter.get_node_text(child, buf))
          end
        end
        if lang == 'math' and math_on then
          local a, b = r1 + 1, r2 - 1
          if b >= a and not (cur >= r1 and cur <= r2) then
            local tex = vim.trim(table.concat(vim.list_slice(lines, a + 1, b + 1), '\n'))
            local entry = tex ~= '' and lookup(tex, true, screen_rows(a, b))
            if entry and entry.state == 'error' then
              math_error(b, entry)
            elseif entry and entry.state == 'ready' then
              local sc = #(lines[a + 1]:match('^%s*'))
              place_display(a, math.min(sc, c1), b, #lines[b + 1], entry)
            end
          end
        else
          for row = r1, r2 do
            mark(row, 0, { line_hl_group = 'MdRenderCode' })
          end
          if lang and lang ~= '' and r2 > r1 + 1 then
            mark(r1 + 1, 0, { virt_text = { { lang .. ' ', 'MdRenderCodeLang' } }, virt_text_pos = 'right_align' })
          end
          -- Languages without a treesitter parser are coloured from Neovim's syntax files.
          if lang and lang ~= '' and r2 > r1 + 1 and not code.has_parser(lang) then
            local body = {}
            for row = r1 + 1, r2 - 1 do
              body[#body + 1] = lines[row + 1]:sub(c1 + 1)
            end
            local spans = code.highlight(lang, body, in_redraw)
            incomplete = incomplete or spans == nil
            for _, span in ipairs(spans or {}) do
              mark(r1 + 1 + span[1], c1 + span[2], { end_col = c1 + span[3], hl_group = span[4], priority = 110 })
            end
          end
        end
      elseif name == 'quote' then
        local _, r2 = last_row(node)
        for row = r1, r2 do
          local l = lines[row + 1]
          local pre = l:match('^(%s*)>')
          if pre then
            mark(row, #pre, { end_col = #pre + 1, conceal = '▎', hl_group = 'MdRenderQuoteBar' })
            if #l > #pre + 1 then
              mark(row, #pre + 1, { end_col = #l, hl_group = 'MdRenderQuote' })
            end
          end
        end
      elseif name == 'bullet' then
        local s = line:find('[-+*]', c1 + 1)
        if s and line:sub(s + 1):match('^%s+%[[ xX]%]') then
          -- Task item: the checkbox replaces the bullet.
          mark(r1, s - 1, { end_col = s + #line:sub(s + 1):match('^%s+'), conceal = '' })
        elseif s then
          local depth, parent = 0, node:parent()
          while parent do
            if parent:type() == 'list' then
              depth = depth + 1
            end
            parent = parent:parent()
          end
          local bullets = M.config.bullets
          local glyph = bullets[math.min(math.max(depth, 1), #bullets)]
          mark(r1, s - 1, { end_col = s, conceal = glyph, hl_group = 'MdRenderBullet' })
        end
      elseif name == 'number' then
        local a, b = line:find('%d+[.)]', c1 + 1)
        if a then
          mark(r1, a - 1, { end_col = b, hl_group = 'MdRenderListNumber' })
        end
      elseif name == 'task' or name == 'task_done' then
        local done = name == 'task_done'
        mark(r1, c1, { end_col = c2, conceal = M.config.tasks[done and 2 or 1], hl_group = done and 'MdRenderTaskDone' or 'MdRenderTask' })
      elseif name == 'table' then
        table_block(node)
      end
    end
  end)
  return incomplete
end

-- Parse the visible rows and draw them. The parse is asynchronous, as in Neovim's
-- highlighter: when parsing the new text takes longer than a slice, the call returns
-- and the drawing happens later, with the old decorations shown meanwhile. (After an
-- edit most of the time goes to Neovim's injection scan, which does not yield.)
local function render(buf, sync)
  local st = state[buf]
  if not api.nvim_buf_is_valid(buf) or not st then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not ok or not parser then
    return
  end
  local ranges = visible_ranges(buf)
  if #ranges == 0 then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return
  end
  -- A render that finishes after a newer one has started draws nothing: its view is
  -- out of date.
  st.gen = (st.gen or 0) + 1
  local gen = st.gen
  if sync then
    -- Within a screen update the rows must be ready before they are drawn.
    for _, r in ipairs(ranges) do
      parser:parse({ r[1], 0, r[2], 0 })
    end
    if draw(buf, parser, ranges, true) then
      vim.schedule(function()
        render(buf)
      end)
    end
    return
  end
  -- One range at a time: Neovim 0.11 does not take a list of ranges.
  local i = 0
  local function step(err)
    if state[buf] ~= st or st.gen ~= gen then
      return
    end
    if err then
      -- The parse timed out ('redrawtime'): keep the decorations already shown.
      return
    end
    i = i + 1
    if i > #ranges then
      draw(buf, parser, ranges)
    else
      parser:parse({ ranges[i][1], 0, ranges[i][2], 0 }, step)
    end
  end
  step()
end

-- True when the rows top..bot (0-based, inclusive) are inside the decorated ranges.
local function covered(st, top, bot)
  for _, r in ipairs(st.drawn or {}) do
    if r[1] <= top and bot < r[2] then
      return true
    end
  end
  return false
end

-- Hooks for the tests (test/run.lua) and test/bench.lua, not part of the API.
M._render = render

local function schedule(buf, ms)
  local st = state[buf]
  if not st then
    return
  end
  if st.timer then
    st.timer:stop()
  else
    st.timer = vim.uv.new_timer()
  end
  st.timer:start(ms, 0, vim.schedule_wrap(function()
    render(buf)
  end))
end

local function render_all(ms)
  for buf in pairs(state) do
    schedule(buf, ms or 10)
  end
end

-- Attach / detach -----------------------------------------------------------

local function set_window(win)
  for name, value in pairs(M.config.win_options) do
    vim.wo[win][0][name] = value
  end
end

function M.attach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if state[buf] then
    return
  end
  if not pcall(vim.treesitter.start, buf, 'markdown') then
    vim.notify('mdrender: the markdown treesitter parser is missing', vim.log.levels.WARN)
    return
  end
  state[buf] = { row = -1 }
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    set_window(win)
  end
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWinEnter' }, {
    group = group, buffer = buf,
    callback = function(ev)
      if ev.event == 'BufWinEnter' then
        set_window(api.nvim_get_current_win())
      end
      schedule(buf, 80)
    end,
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group, buffer = buf,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      if state[buf] and state[buf].row ~= row then
        state[buf].row = row
        schedule(buf, 5)
      end
    end,
  })
  api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
    group = group, buffer = buf,
    callback = function()
      M.detach(buf)
    end,
  })
  render(buf)
end

function M.detach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local st = state[buf]
  if not st then
    return
  end
  if st.timer then
    st.timer:stop()
    st.timer:close()
  end
  state[buf] = nil
  pcall(api.nvim_clear_autocmds, { group = group, buffer = buf })
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win][0].conceallevel = 0
    end
  end
end

function M.toggle(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if state[buf] then
    M.detach(buf)
  else
    M.attach(buf)
  end
end

--- Send the math images again and redraw (use after re-attaching a terminal).
function M.refresh()
  mathr.retransmit()
  render_all()
end

--- Change one setting while Neovim runs, e.g. M.set('math.inline_size', '1.0').
--- Strings are converted to match the current value: numbers, booleans, and
--- comma-separated lists such as '9,20' or '●,○,◆'.
function M.set(path, value)
  local keys = vim.split(path, '.', { plain = true })
  local tbl = M.config
  for i = 1, #keys - 1 do
    tbl = type(tbl) == 'table' and tbl[keys[i]] or nil
  end
  local key = keys[#keys]
  if type(tbl) ~= 'table' or tbl[key] == nil then
    vim.notify('mdrender: unknown setting ' .. path, vim.log.levels.ERROR)
    return
  end
  if type(value) == 'string' then
    local function convert(v, like)
      if type(like) == 'number' then
        return tonumber(v)
      elseif type(like) == 'boolean' or v == 'true' or v == 'false' then
        return v == 'true'
      end
      return v
    end
    local old = tbl[key]
    if type(old) == 'table' and vim.islist(old) then
      local list = vim.split(value, ',', { plain = true, trimempty = true })
      for i, v in ipairs(list) do
        list[i] = convert(vim.trim(v), old[1])
      end
      value = list
    elseif type(old) == 'table' then
      vim.notify('mdrender: set ' .. path .. '.<key> instead', vim.log.levels.ERROR)
      return
    else
      value = convert(value, old)
    end
    if value == nil then
      vim.notify('mdrender: bad value for ' .. path, vim.log.levels.ERROR)
      return
    end
  end
  tbl[key] = value
  set_highlights()
  update_cell()
  mathr.clear()
  for buf in pairs(state) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      set_window(win)
    end
  end
  render_all()
end

--- Dotted names of all settings, for command completion.
function M.setting_names()
  local names = {}
  local function walk(tbl, prefix)
    for k, v in pairs(tbl) do
      if type(k) == 'string' then
        if type(v) == 'table' and not vim.islist(v) and next(v) ~= nil then
          walk(v, prefix .. k .. '.')
        else
          names[#names + 1] = prefix .. k
        end
      end
    end
  end
  walk(M.config, '')
  table.sort(names)
  return names
end

function M.build()
  mathr.build(render_all)
end

function M.setup(opts)
  -- Settings can also come from the global variable g:mdrender.
  M.config = vim.tbl_deep_extend('force', M.config, vim.g.mdrender or {}, opts or {})
  set_highlights()
  update_cell()
  mathr.in_use = function()
    local ids = {}
    local function scan(chunks)
      for _, c in ipairs(chunks or {}) do
        local id = type(c[2]) == 'string' and c[2]:match('^MdRenderImg(%d+)$')
        if id then
          ids[tonumber(id)] = true
        end
      end
    end
    for buf in pairs(state) do
      if api.nvim_buf_is_valid(buf) then
        for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
          scan(m[4].virt_text)
          for _, l in ipairs(m[4].virt_lines or {}) do
            scan(l)
          end
        end
      end
    end
    return ids
  end
  mathr.on_update = function()
    render_all(20)
  end
  if M.config.math.enabled and not vim.o.termguicolors then
    vim.notify('mdrender: math images need termguicolors', vim.log.levels.WARN)
  end

  api.nvim_create_autocmd('FileType', {
    group = group, pattern = M.config.filetypes,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  -- Colours depend on the scheme and on 'background': rebuild them and the math images.
  local function recolor()
    set_highlights()
    mathr.clear()
    render_all()
  end
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = recolor })
  api.nvim_create_autocmd('OptionSet', {
    group = group, pattern = 'background',
    callback = vim.schedule_wrap(recolor),
  })
  api.nvim_create_autocmd('WinScrolled', {
    group = group,
    callback = function()
      render_all(5)
    end,
  })
  -- A jump past the decorated rows (G, a search, 5000gg) is drawn within the same
  -- screen update, before the rows show: otherwise one frame shows raw Markdown.
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf, top, bot)
      local st = state[buf]
      if st and not covered(st, top, bot) then
        -- Should anything fail inside the screen update, draw right after it instead.
        if not pcall(render, buf, true) then
          vim.schedule(function()
            render(buf)
          end)
        end
      end
      return false
    end,
  })
  api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = group,
    callback = function()
      update_cell()
      render_all()
    end,
  })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = mathr.stop })

  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.tbl_contains(M.config.filetypes, vim.bo[buf].filetype) then
      M.attach(buf)
    end
  end
end

return M
