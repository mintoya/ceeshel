local root = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))
vim.opt.runtimepath:prepend(root)
vim.filetype.add({ extension = { cshl = 'cshl' } })

local function run(argv)
  local result = vim.system(argv, { cwd = root, text = true }):wait()
  if result.code ~= 0 then
    error((result.stderr or '') .. (result.stdout or ''))
  end
end

local function newer(source, output)
  local a, b = vim.uv.fs_stat(source), vim.uv.fs_stat(output)
  if not a then return false end
  if not b then return true end
  return a.mtime.sec > b.mtime.sec
    or (a.mtime.sec == b.mtime.sec and a.mtime.nsec > b.mtime.nsec)
end

local function build(force)
  local generated = root .. '/tree-sitter/src/parser.c'
  if force or newer(root .. '/grammar.js', generated) then
    run({ 'tree-sitter', 'generate', '--abi', '14', '--output', 'tree-sitter/src' })
  end
  -- A versioned name and library path avoid Neovim's loaded-language and
  -- dlopen caches, including an older globally installed cshl parser.
  local parser_source = table.concat(vim.fn.readfile(generated), '\n')
  local query = table.concat(vim.fn.readfile(root .. '/queries/cshl/highlights.scm'), '\n')
  local language = 'ceeshel_' .. vim.fn.sha256(root .. parser_source .. query):sub(1, 16)
  local parser_path = root .. '/zig-out/nvim/' .. language .. '.so'
  if force or not vim.uv.fs_stat(parser_path) then
    vim.fn.mkdir(vim.fs.dirname(parser_path), 'p')
    local temporary = parser_path .. '.tmp'
    run({ 'cc', '-shared', '-fPIC', '-O2', '-I', root .. '/tree-sitter/src', generated, '-o', temporary })
    assert(vim.uv.fs_rename(temporary, parser_path))
  end
  local ok, err = vim.treesitter.language.add(language, { path = parser_path, symbol_name = 'cshl' })
  assert(ok, err)
  vim.treesitter.query.set(language, 'highlights', query)
  assert(vim.treesitter.query.get(language, 'highlights'))
  vim.treesitter.language.register(language, 'cshl')
  return language
end

local function start(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'cshl' then return end
  local ok, err = pcall(function()
    local language = build(false)
    vim.treesitter.stop(buf)
    vim.treesitter.start(buf, language)
  end)
  if not ok then vim.notify('CSHL highlighting: ' .. tostring(err), vim.log.levels.ERROR) end
end

local group = vim.api.nvim_create_augroup('CshlProject', { clear = true })
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'cshl',
  callback = function(event) start(event.buf) end,
})
vim.api.nvim_create_user_command('CshlRebuildParser', function()
  local ok, err = pcall(function()
    build(true)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do start(buf) end
    vim.notify('CSHL parser rebuilt and highlighting refreshed.')
  end)
  if not ok then vim.notify('CSHL parser: ' .. tostring(err), vim.log.levels.ERROR) end
end, { force = true })

vim.schedule(function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):match('%.cshl$') then
      vim.bo[buf].filetype = 'cshl'
      start(buf)
    end
  end
end)
