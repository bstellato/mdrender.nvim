-- Smoke test: nvim --headless --clean -u NONE -l is not used; run with:
--   nvim --headless --clean --cmd 'set rtp+=.' test/sample.md -c 'luafile test/headless.lua'
vim.o.termguicolors = true
local sent = {}
local real = vim.api.nvim_ui_send
vim.api.nvim_ui_send = function(d) table.insert(sent, d) end
require('mdrender').setup({})
vim.wait(3000, function() return false end, 50)
local ns = vim.api.nvim_get_namespaces().mdrender
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
local kinds = {}
for _, m in ipairs(marks) do
  local d = m[4]
  local k = d.virt_lines and 'virt_lines' or d.virt_text and ('virt_text:' .. d.virt_text_pos) or d.conceal_lines and 'conceal_lines'
    or d.conceal and 'conceal' or d.line_hl_group and 'line_hl' or d.hl_group and 'hl' or '?'
  kinds[k] = (kinds[k] or 0) + 1
end
io.write('marks: ' .. #marks .. '\n' .. vim.inspect(kinds) .. '\n')
local transmits, placements = 0, 0
for _, s in ipairs(sent) do
  if s:find('a=t,f=100,t=d', 1, true) then transmits = transmits + 1 end
  if s:find('a=p,U=1', 1, true) then placements = placements + 1 end
end
io.write(('images transmitted: %d, placements: %d\n'):format(transmits, placements))
for _, m in ipairs(marks) do
  local d = m[4]
  if d.virt_text and d.virt_text_pos == 'eol' then io.write('eol@' .. m[2] .. ': ' .. d.virt_text[1][1] .. '\n') end
end
io.write('messages: ' .. vim.fn.execute('messages') .. '\n')
vim.cmd('qa!')
