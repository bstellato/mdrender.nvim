# mdrender.nvim

Styled Markdown and rendered math in the Neovim buffer you are editing.
One plugin, no dependencies on other plugins.

- **Markdown** gets a GitHub-like look: headings with rules, bullets by level, task boxes,
  quote bars, bordered tables, code blocks with syntax highlighting.
- **Math** (`$...$`, `$$...$$` and fenced `math` blocks) is typeset with MathJax and drawn as images.
- **Editing stays normal.** The line under the cursor always shows the raw source.

## Requirements

- Neovim 0.11 or later (developed on 0.12), with `termguicolors` on.
- A terminal that supports the Kitty graphics protocol with Unicode placeholders:
  kitty, Ghostty, or the Herdr app. Without it you still get the Markdown styling; set
  `math.enabled = false`.
- Node.js and npm, for the math renderer. No LaTeX install is needed.

## Install

With lazy.nvim:

```lua
{
  'bstellato/mdrender.nvim',
  ft = 'markdown',
  build = 'cd node && npm install',
  opts = {},
}
```

The math renderer installs itself on first use if `node/node_modules` is missing. Run
`:MdRender build` to install or repair it by hand.

Do not run it together with another Markdown renderer such as `render-markdown.nvim`: both
would decorate the same text.

To try it without touching your config, from a clone of this repository:

```sh
cd node && npm install && cd ..
nvim --clean --cmd 'set rtp+=. termguicolors' -c 'lua require("mdrender").setup()' test/sample.md
```

## What it renders

| Element | Rendering |
|---|---|
| Headings | Accent colour, `#` marks hidden, a rule under levels 1 and 2 |
| Strong text, links, list numbers, inline code | Accent colour (links underlined, inline code on a grey background) |
| Bullets | `●`, `○`, `◆` by nesting level |
| Task items | `□` and `■` in the accent colour, with no bullet |
| Block quotes | A bar in the margin, dimmed italic text |
| Code blocks | Shaded background, language label, syntax highlighting |
| Tables | Drawn with box borders and aligned columns; cells wrap to fit the window |
| Horizontal rules | A full-width line |
| Inline math | An image one text row high, drawn over its source |
| Display math | A centred image, one row per source line |
| Broken math | The MathJax error at the end of the line |

Tables are laid out from scratch, so the source does not need to be aligned or have outer
pipes. When a table is wider than the window, the widest columns are narrowed and their
cells wrap; rows are then separated by rules. Column alignment follows the delimiter row.

Code blocks are highlighted by treesitter when a parser for the language is installed.
Otherwise the plugin uses the syntax files that ship with Neovim, which cover most
languages with simpler colouring.

## Settings

All settings with their defaults:

```lua
require('mdrender').setup({
  filetypes = { 'markdown' },
  max_width = 100,              -- rules and centred display math use at most this many columns

  -- Colour of headings, strong text, links, list numbers, inline code and task boxes.
  -- One string applies to both backgrounds; false follows the colour scheme.
  accent = { dark = '#0ea5e9', light = '#0284c7' },

  bullets = { '●', '○', '◆' },  -- list markers by nesting level (the last one repeats)
  tasks = { '□', '■' },         -- open and done task boxes

  highlights = {},              -- overrides, e.g. { Strong = { fg = '#ff8800', bold = true } }

  win_options = {               -- set on Markdown windows
    conceallevel = 2,
    concealcursor = '',
    linebreak = true,
    breakindent = true,
    breakindentopt = 'list:-1', -- wrapped list items keep their indent
  },

  math = {
    enabled = true,
    inline_size = 0.9,          -- inline font size, as a fraction of the row height
    display_size = 1.0,         -- display font size, same unit
    weight = 12,                -- outline added to the glyphs, in 1/1000 em (0 = plain TeX weight)
    baseline = 0.76,            -- text baseline in a row, from the top
    scale = 2,                  -- supersampling for sharp images
    cell = { 9, 20 },           -- cell size in pixels when the terminal does not report it
    macros = {},                -- MathJax macros, e.g. { reals = '\\mathbf{R}' }
  },
})
```

Settings can also come from a global variable, in which case no `setup()` call is needed:

```vim
let g:mdrender = #{max_width: 90, math: #{inline_size: 1.0}}
```

### Adjusting sizes and symbols while editing

`:MdRender set <setting> <value>` changes one setting and redraws at once. Tab completes the
setting names. Use it to find values you like, then copy them into your config.

```vim
:MdRender set math.inline_size 1.0
:MdRender set math.display_size 1.1
:MdRender set math.weight 0
:MdRender set math.cell 9.5,20
:MdRender set bullets ■,□,▸
:MdRender set tasks ☐,☑
:MdRender set accent.dark #ff8800
:MdRender set max_width 80
```

What each font-related knob does:

- **`math.inline_size`, `math.display_size`**: how big math is next to the text. Raise
  `inline_size` if math looks small. Formulas taller than a row are shrunk to fit, so very
  large values make tall formulas look inconsistent.
- **`math.weight`**: TeX fonts are thin next to terminal text. A larger value makes the math bolder.
- **`math.cell`**: only the width-to-height ratio matters, and only when the terminal does not
  report its cell size (the Herdr app does not). If inline math has side margins, raise the
  first number. If math looks slightly small, lower it.
- **`bullets`, `tasks`**: a terminal cannot scale one character, so "larger" means choosing a
  bigger glyph. How big a glyph looks depends on your font.

### Highlight groups

`highlights` overrides any group by its short name: `H1` to `H6`, `Strong`, `Link`,
`ListNumber`, `CodeInline`, `Code`, `CodeLang`, `Bullet`, `Task`, `TaskDone`, `Quote`,
`QuoteBar`, `Rule`, `TableBorder`, `TableHead`, `MathError`. The full group names are
`MdRender<Name>`.

Headings and strong text use a colour as well as bold because some terminals draw bold barely
heavier than normal text.

## Commands

| Command | Effect |
|---|---|
| `:MdRender` or `:MdRender toggle` | Turn rendering on or off in this buffer |
| `:MdRender enable` / `disable` | Same, explicitly |
| `:MdRender set <setting> <value>` | Change a setting and redraw |
| `:MdRender refresh` | Send the math images again |
| `:MdRender build` | Install the math renderer |

Use `refresh` if images vanish, for example after re-attaching a terminal session.

## How math works

A background Node process turns each formula into an SVG with MathJax and then a PNG with
resvg. Rendering takes about a millisecond per formula after startup, and results are cached.
Images are sent to the terminal as bytes, which also works where file-path transfer does not,
and are placed with Unicode placeholders so they scroll with the text.

Supported TeX is what MathJax supports: AMS math, `\text`, `\mathbf`, `\boldsymbol`,
`mathtools`, `cancel`, `braket`, colours, and your own macros through `math.macros`.

## Limits

- **Wrapping follows the raw source.** Neovim counts hidden text when it wraps a line, so a line
  with long formulas or links can break before the window edge.
- **Inline math is one row high.** Tall inline formulas such as fractions are shrunk.
- **Display math keeps one row per source line**, so the text below never jumps when the cursor
  enters the block. A formula written over many lines gets a tall block.
- **Tables are redrawn, so you edit them as source.** Moving the cursor into a table shows its
  raw rows; moving out draws it again. Inside cells, the drawn version understands strong and
  italic text, inline code, links and math, but not other inline markup.
- **Glyph and bold rendering depend on the terminal font.**
- No tmux support yet.

## Development

```sh
nvim --headless --clean --cmd 'set rtp+=.' test/sample.md -c 'luafile test/headless.lua'
```

This smoke test prints the number of decorations and transmitted images and any error
messages. `test/sample.md`, `test/wrap.md` and `test/tables.md` are the visual test files.

Layout:

| File | Role |
|---|---|
| `lua/mdrender/init.lua` | Settings, Markdown styling, placement of math |
| `lua/mdrender/math.lua` | Client for the Node renderer, image cache |
| `lua/mdrender/kitty.lua` | Image transfer and placeholders |
| `lua/mdrender/code.lua` | Code block highlighting from Neovim's syntax files |
| `node/render.js` | TeX to PNG with MathJax and resvg |
| `scripts/gen_diacritics.py` | Regenerates the placeholder table from the Unicode database |

## License

MIT. See [LICENSE](LICENSE).

The math renderer installs its dependencies from npm; they are not bundled here.
MathJax is under the Apache License 2.0 and resvg-js under the Mozilla Public License 2.0.
The placeholder table in `lua/mdrender/diacritics.lua` is generated from the Unicode
Character Database.
