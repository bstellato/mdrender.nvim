-- Syntax highlighting for fenced code blocks without a treesitter parser, using the
-- syntax files that ship with Neovim. The code is loaded into a hidden scratch buffer
-- with that syntax, and the resulting highlight groups are copied back as extmarks.
local M = {}

local api = vim.api
local cache = {} -- lang .. text -> list of {row, col_start, col_end, group}
local cached = 0
local scratch
local MAX_LINES = 400

local function has_syntax(name)
  return #api.nvim_get_runtime_file('syntax/' .. name .. '.vim', false) > 0
    or #api.nvim_get_runtime_file('syntax/' .. name .. '.lua', false) > 0
end

--- Syntax name for a fence label such as "python", "py" or "sh", or nil.
local function syntax_name(label)
  local lang = label:lower():match('^[%w_+#-]+')
  if not lang then
    return nil
  end
  if has_syntax(lang) then
    return lang
  end
  local ft = vim.filetype.match({ filename = 'x.' .. lang })
  if ft and has_syntax(ft) then
    return ft
  end
  return nil
end

--- True when treesitter can highlight this fence label itself (as an injection).
function M.has_parser(label)
  local lang = label:lower():match('^[%w_+#-]+')
  if not lang then
    return false
  end
  local names = { lang, vim.treesitter.language.get_lang(lang), vim.filetype.match({ filename = 'x.' .. lang }) }
  for _, name in pairs(names) do
    local ok, added = pcall(vim.treesitter.language.add, name)
    if ok and added then
      return true
    end
  end
  return false
end

--- Highlight spans for the code lines: a list of {row, col_start, col_end, group},
--- with 0-based rows relative to the first line and byte columns.
function M.highlight(label, lines)
  local syn = syntax_name(label)
  if not syn or #lines == 0 or #lines > MAX_LINES then
    return {}
  end
  local key = syn .. '\0' .. table.concat(lines, '\n')
  if cache[key] then
    return cache[key]
  end
  if not (scratch and api.nvim_buf_is_valid(scratch)) then
    scratch = api.nvim_create_buf(false, true)
    vim.bo[scratch].swapfile = false
  end
  local spans = {}
  api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  api.nvim_buf_call(scratch, function()
    vim.bo.syntax = syn
    vim.cmd('syntax sync fromstart')
    local names = {}
    for i, line in ipairs(lines) do
      local start, current
      for col = 1, #line + 1 do
        local id = col <= #line and vim.fn.synIDtrans(vim.fn.synID(i, col, 1)) or nil
        if id ~= current then
          if current and current ~= 0 then
            names[current] = names[current] or vim.fn.synIDattr(current, 'name')
            if names[current] ~= '' then
              table.insert(spans, { i - 1, start - 1, col - 1, names[current] })
            end
          end
          start, current = col, id
        end
      end
    end
  end)
  if cached > 200 then
    cache, cached = {}, 0
  end
  cache[key] = spans
  cached = cached + 1
  return spans
end

return M
