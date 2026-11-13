if vim.g.loaded_mdrender then
  return
end
vim.g.loaded_mdrender = true

local actions = { 'enable', 'disable', 'toggle', 'refresh', 'build', 'set' }

vim.api.nvim_create_user_command('MdRender', function(cmd)
  local m = require('mdrender')
  local action = cmd.fargs[1] or 'toggle'
  if action == 'enable' then
    m.attach(0)
  elseif action == 'disable' then
    m.detach(0)
  elseif action == 'toggle' then
    m.toggle(0)
  elseif action == 'refresh' then
    m.refresh()
  elseif action == 'build' then
    m.build()
  elseif action == 'set' and cmd.fargs[2] and cmd.fargs[3] then
    m.set(cmd.fargs[2], table.concat(cmd.fargs, ' ', 3))
  elseif action == 'set' then
    vim.notify('Usage: MdRender set <setting> <value>, e.g. MdRender set math.inline_size 1.0', vim.log.levels.ERROR)
  else
    vim.notify('MdRender: unknown action ' .. action, vim.log.levels.ERROR)
  end
end, {
  nargs = '*',
  complete = function(_, line)
    local words = vim.split(line, '%s+')
    if #words <= 2 then
      return actions
    elseif words[2] == 'set' and #words == 3 then
      return require('mdrender').setting_names()
    end
    return {}
  end,
  desc = 'Markdown and math rendering: ' .. table.concat(actions, ', '),
})

-- With g:mdrender set (Vim script or Lua), no setup() call is needed.
if type(vim.g.mdrender) == 'table' then
  require('mdrender').setup()
end
