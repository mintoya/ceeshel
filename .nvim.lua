-- Editor support for ceeshel, loaded by nvim's exrc.
local root = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))

-- Highlighting from grammar/: build the parser there first, with
--   tree-sitter generate && tree-sitter build -o cshl.so .
-- It's registered as its own language, so a global cshl parser is untouched.
local parser = root .. '/grammar/cshl.so'
if vim.uv.fs_stat(parser) then
  vim.treesitter.language.add('ceeshel', { path = parser, symbol_name = 'cshl' })
  vim.treesitter.language.register('ceeshel', 'cshl')
  local f = io.open(root .. '/grammar/queries/highlights.scm')
  if f then
    vim.treesitter.query.set('ceeshel', 'highlights', f:read('*a'))
    f:close()
  end
end

-- Errors: a `#lang ceeshel` file is a Racket module that lowers itself while
-- it expands, so racket-langserver reports ceeshel errors. Files without the
-- #lang line aren't Racket, so it doesn't attach to them.
vim.lsp.config.ceeshel = {
  cmd = { 'racket', '-l', 'racket-langserver' },
  filetypes = { 'cshl' },
  root_dir = function(bufnr, on_dir)
    local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ''
    if first:match('^#lang ceeshel') then on_dir(root) end
  end,
}
vim.lsp.enable('ceeshel')
