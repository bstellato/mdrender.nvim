-- Markdown decorations: headings, lists, quotes, code, inline styles, rules, tables.
local api = vim.api

-- Blocks are separated by blank lines: in GFM a line right after a table is another
-- row, a line after a quote continues it, and `---` under a paragraph is a heading.
local doc = {
  '# Title',
  '',
  '## Sub',
  '### Third',
  '',
  '- one',
  '  - two',
  '    - three',
  '- [ ] open',
  '- [x] done',
  '',
  '1. first',
  '',
  '> quote',
  '',
  '`code` **bold** [link](https://example.com)',
  '',
  '---',
  '',
  '```lua',
  'local x = 1',
  '```',
  '',
  '```python',
  'x = 1',
  '```',
  '',
  '| a | b |',
  '|---|---|',
  '| 1 | 2 |',
  '',
  'end',
}
local last = #doc - 1

--- 0-based row of the first line equal to `text`.
local function R(text)
  for i, line in ipairs(doc) do
    if line == text then
      return i - 1
    end
  end
  error('no line ' .. text)
end

local function rule_below(row)
  return H.find(row, function(d)
    return d.virt_lines ~= nil and d.virt_lines[1][1][1]:find('─', 1, true) ~= nil
  end)
end

local function conceal(row, glyph)
  return H.find(row, function(d)
    return d.conceal == glyph
  end)
end

return {
  { 'window options are set on attach', function()
    H.open(doc, last)
    H.eq(2, vim.wo.conceallevel, 'conceallevel')
    H.eq('', vim.wo.concealcursor, 'concealcursor')
    H.ok(vim.wo.linebreak and vim.wo.breakindent, 'linebreak and breakindent')
  end },

  { 'headings: marker hidden, colour by level, rule under levels 1 and 2', function()
    H.open(doc, last)
    local h1 = R('# Title')
    H.ok(H.find(h1, function(d) return d.conceal == '' and d.col == 0 and d.end_col == 2 end), 'h1 marker hidden')
    H.ok(H.has_hl(h1, 'MdRenderH1'), 'h1 colour')
    H.ok(H.has_hl(R('## Sub'), 'MdRenderH2'), 'h2 colour')
    H.ok(H.has_hl(R('### Third'), 'MdRenderH3'), 'h3 colour')
    H.ok(rule_below(h1), 'rule under h1')
    H.ok(rule_below(R('## Sub')), 'rule under h2')
    H.ok(not rule_below(R('### Third')), 'no rule under h3')
  end },

  { 'bullets by nesting level', function()
    H.open(doc, last)
    H.ok(conceal(R('- one'), '●'), 'level 1 bullet')
    H.ok(conceal(R('  - two'), '○'), 'level 2 bullet')
    H.ok(conceal(R('    - three'), '◆'), 'level 3 bullet')
  end },

  { 'custom bullets from the config', function()
    H.m.config.bullets = { '*', '+' }
    H.open(doc, last)
    H.ok(conceal(R('- one'), '*'), 'level 1')
    H.ok(conceal(R('    - three'), '+'), 'last glyph repeats')
  end },

  { 'tasks replace their bullet', function()
    H.open(doc, last)
    local open, done = R('- [ ] open'), R('- [x] done')
    H.ok(H.find(open, function(d) return d.conceal == '□' and d.hl_group == 'MdRenderTask' end), 'open task')
    H.ok(H.find(done, function(d) return d.conceal == '■' and d.hl_group == 'MdRenderTaskDone' end), 'done task')
    H.ok(not conceal(open, '●'), 'no bullet on a task')
  end },

  { 'numbered lists, quotes, inline styles', function()
    H.open(doc, last)
    H.ok(H.has_hl(R('1. first'), 'MdRenderListNumber'), 'list number')
    local quote = R('> quote')
    H.ok(conceal(quote, '▎'), 'quote bar')
    H.ok(H.has_hl(quote, 'MdRenderQuote'), 'quote text')
    local styled = R('`code` **bold** [link](https://example.com)')
    H.ok(H.has_hl(styled, 'MdRenderCodeInline'), 'inline code')
    H.ok(H.has_hl(styled, 'MdRenderStrong'), 'strong')
    H.ok(H.find(styled, function(d) return d.hl_group == 'MdRenderLink' and d.col == 17 end), 'link text')
  end },

  { 'thematic break: drawn rule, raw on the cursor line', function()
    H.open(doc, last)
    local row = R('---')
    local rule = H.find(row, function(d) return d.virt_text_pos == 'overlay' end)
    H.ok(rule and H.vtext(rule):gsub('─', '') == '', 'rule drawn')
    H.cursor(row)
    H.ok(not H.find(row, function(d) return d.virt_text_pos == 'overlay' end), 'raw on the cursor line')
  end },

  { 'code blocks: background, language label, syntax for languages without a parser', function()
    H.open(doc, last)
    local fence = R('```lua')
    for row = fence, fence + 2 do
      H.ok(H.find(row, function(d) return d.line_hl_group == 'MdRenderCode' end), 'background on row ' .. row)
    end
    local label = H.find(fence + 1, function(d) return d.virt_text_pos == 'right_align' end)
    H.eq('lua ', label and H.vtext(label), 'language label')
    if not require('mdrender.code').has_parser('python') then
      H.ok(H.find(R('x = 1'), function(d) return d.priority == 110 and d.hl_group end), 'python coloured from syntax files')
    end
  end },

  { 'tables: source hidden, box drawn, raw with the cursor inside', function()
    H.open(doc, last)
    local top = R('| a | b |')
    for row = top, top + 2 do
      H.ok(H.find(row, function(d) return d.conceal_lines == '' end), 'row ' .. row .. ' hidden')
    end
    local box = H.find(top + 3, function(d) return d.virt_lines and d.virt_lines_above end)
    H.ok(box, 'table drawn above the next line')
    H.ok(box.virt_lines[1][1][1]:find('┌', 1, true), 'top border')
    local text = {}
    for _, line in ipairs(box.virt_lines) do
      for _, chunk in ipairs(line) do
        table.insert(text, chunk[1])
      end
    end
    text = table.concat(text)
    H.ok(text:find('a', 1, true) and text:find('2', 1, true), 'cells shown')
    H.cursor(top + 1)
    H.ok(not H.find(top + 1, function(d) return d.conceal_lines end), 'raw with the cursor inside')
  end },

  { 'tables: fit the window, wrap long cells, style markup in cells', function()
    vim.cmd('vsplit')
    api.nvim_win_set_width(0, 50)
    H.open({
      'Solver | Time | Notes',
      ':--|--:|:-:',
      'OSQP | 0.12 | **warm** `tol` [docs](https://x.org) and a very long note that has to wrap in a narrow window',
      '',
      'end',
    }, 4)
    local box = H.find(3, function(d) return d.virt_lines end)
    H.ok(box, 'table drawn')
    local width = 0
    local groups = {}
    for _, line in ipairs(box.virt_lines) do
      local w = 0
      for _, chunk in ipairs(line) do
        w = w + vim.fn.strdisplaywidth(chunk[1])
        if chunk[2] then
          groups[chunk[2]] = true
        end
      end
      width = math.max(width, w)
    end
    H.ok(width <= 50, 'fits the window: ' .. width)
    H.ok(groups.MdRenderStrong and groups.MdRenderCodeInline and groups.MdRenderLink, 'markup styled in cells')
    H.ok(#box.virt_lines > 5, 'long cell wrapped over several lines')
  end },

  { 'detach removes everything, toggle and the command bring it back', function()
    local buf = H.open(doc, last)
    H.ok(#H.marks(buf) > 0, 'decorated')
    H.m.detach(buf)
    H.eq(0, #H.marks(buf), 'marks after detach')
    H.eq(0, vim.wo.conceallevel, 'conceallevel after detach')
    H.m.toggle(buf)
    H.settle(buf)
    H.ok(#H.marks(buf) > 0, 'decorated after toggle')
    vim.cmd('MdRender disable')
    H.eq(0, #H.marks(buf), 'marks after :MdRender disable')
    vim.cmd('MdRender enable')
    H.settle(buf)
    H.ok(#H.marks(buf) > 0, 'decorated after :MdRender enable')
  end },

  { 'other filetypes are left alone', function()
    local buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(0, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { '# not markdown' })
    vim.bo[buf].filetype = 'text'
    H.m._render(buf)
    H.eq(0, #H.marks(buf), 'marks in a text buffer')
  end },
}
