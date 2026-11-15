#!/bin/sh
# Run the test suite from the repository root. MDRENDER_TEST=<pattern> filters tests.
cd "$(dirname "$0")/.." && exec nvim --headless --clean -n --cmd 'set rtp+=.' -c 'luafile test/run.lua'
