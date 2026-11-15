-- A large Markdown file with many formulas, for timing the renderer:
--   nvim -l test/gen_large.lua [sections] > /tmp/large.md
-- From Lua, dofile('test/gen_large.lua')(sections) returns the lines.
local function generate(n)
  local out = {}
  local function p(s) out[#out + 1] = s end
  for i = 1, n do
    p(('# Section %d'):format(i))
    p('')
    for j = 1, 3 do
      p(('## Subsection %d.%d'):format(i, j))
      p('')
      p(('Let $x_{%d} \\in \\mathbf{R}^{%d}$ and $A_{%d} \\succeq 0$. The **objective** is $f(x) = \\frac{1}{2} x^T A_{%d} x + q^T x$, with `code` and a [link](https://example.com) and *emphasis*.')
        :format(i, j, i, j))
      p(('We also use $\\|x\\|_%d \\le \\epsilon_{%d}$ and $\\lambda_{\\max}(A) = %d$ in this paragraph about step %d.'):format(j, i, i + j, i))
      p('')
      p('$$')
      p(('\\begin{array}{ll} \\text{minimize} & \\sum_{k=1}^{%d} f_k(x_k) \\\\'):format(i))
      p(('\\text{subject to} & A x = b_{%d}, \\quad x \\ge 0 \\end{array}'):format(j))
      p('$$')
      p('')
      p(('- item with $\\alpha_{%d}$'):format(i))
      p('  - nested item')
      p('- [ ] a task')
      p('- [x] done task')
      p('')
    end
    if i % 5 == 0 then
      p('| a | b | c |')
      p('|---|:-:|--:|')
      p(('| $x_{%d}$ | **bold** | 3 |'):format(i))
      p('| text | `code` | 4 |')
      p('')
    end
    if i % 7 == 0 then
      p('```python')
      p('import cvxpy as cp')
      p(('x = cp.Variable(%d)'):format(i))
      p('```')
      p('')
    end
    p('> A quote with $y_{' .. i .. '}$.')
    p('')
    p('---')
    p('')
  end
  return out
end

if arg and arg[0] then
  io.stdout:write(table.concat(generate(tonumber(arg[1]) or 400), '\n') .. '\n')
end
return generate
