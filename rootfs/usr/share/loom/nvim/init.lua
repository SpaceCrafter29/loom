-- Loom :: neovim
--
-- No plugin manager, on purpose. This is the editor the system ships with, and
-- a system editor that cannot start because a lockfile is out of date is not an
-- editor. Add plugins in ~/.config/nvim/lua/ -- this file will not fight you.
--
-- The one thing worth understanding here is the console branch. On a bare TTY
-- neovim gets 16 colours and no more, so enabling termguicolors there makes
-- every modern colourscheme render as mud. We detect it and pick accordingly.

local on_console = (vim.env.TERM == "linux")

------------------------------------------------------------------------ colours
vim.opt.termguicolors = not on_console

if on_console then
  -- The legacy 16-colour scheme, which is the only one designed for cterm.
  pcall(vim.cmd.colorscheme, "vim")
  vim.opt.background = "dark"
  -- Terminus has no powerline glyphs; keep every UI character in ASCII.
  vim.opt.fillchars = { eob = " ", vert = "|", fold = "-" }
  vim.opt.listchars = { tab = "> ", trail = ".", nbsp = "+" }
else
  vim.opt.background = "dark"
  if not pcall(vim.cmd.colorscheme, "habamax") then
    pcall(vim.cmd.colorscheme, "default")
  end
  vim.opt.fillchars = { eob = " " }
  vim.opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
end

------------------------------------------------------------------------ editing
vim.g.mapleader = " "
vim.g.maplocalleader = ","

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.scrolloff = 6
vim.opt.sidescrolloff = 8
vim.opt.wrap = false
vim.opt.linebreak = true

vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.smartindent = true

vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.incsearch = true
vim.opt.hlsearch = true
vim.opt.inccommand = "split"

vim.opt.splitbelow = true
vim.opt.splitright = true

vim.opt.undofile = true
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.updatetime = 250
vim.opt.timeoutlen = 400

vim.opt.completeopt = { "menuone", "noselect", "popup" }
vim.opt.shortmess:append("cI")

-- The console has no clipboard. Inside a Wayland terminal, use the system one.
if not on_console and vim.fn.executable("wl-copy") == 1 then
  vim.opt.clipboard = "unnamedplus"
end

-- ripgrep is installed; :grep should use it.
if vim.fn.executable("rg") == 1 then
  vim.opt.grepprg = "rg --vimgrep --smart-case"
  vim.opt.grepformat = "%f:%l:%c:%m"
end

------------------------------------------------------------------------- keymaps
local map = vim.keymap.set

map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "clear search highlight" })
map("n", "<leader>w", "<cmd>write<CR>", { desc = "write" })
map("n", "<leader>q", "<cmd>quit<CR>", { desc = "quit" })
map("n", "<leader>e", "<cmd>Explore<CR>", { desc = "file explorer" })

-- Window movement without the <C-w> prefix; on a console this matters because
-- <C-w> is also what the kernel line discipline uses for word-erase.
map("n", "<C-h>", "<C-w>h")
map("n", "<C-j>", "<C-w>j")
map("n", "<C-k>", "<C-w>k")
map("n", "<C-l>", "<C-w>l")

map("n", "<leader>b", "<cmd>buffers<CR>:buffer ", { desc = "switch buffer" })
map("v", "<", "<gv", { desc = "outdent, keep selection" })
map("v", ">", ">gv", { desc = "indent, keep selection" })
map("n", "<leader>/", ":grep ", { desc = "grep (ripgrep)" })

-- Loom-specific: these are the files you will actually edit on this system.
map("n", "<leader>lc", "<cmd>edit /etc/loom/loom.conf<CR>", { desc = "loom.conf" })
map("n", "<leader>lz", "<cmd>edit ~/.config/zellij/config.kdl<CR>", { desc = "zellij config" })
map("n", "<leader>lt", "<cmd>edit ~/.config/tmux/tmux.conf<CR>", { desc = "tmux config" })

------------------------------------------------------------------- autocommands
local aug = vim.api.nvim_create_augroup("loom", { clear = true })

vim.api.nvim_create_autocmd("TextYankPost", {
  group = aug,
  desc = "briefly highlight yanked text",
  callback = function() vim.hl.on_yank({ timeout = 150 }) end,
})

vim.api.nvim_create_autocmd("BufWritePre", {
  group = aug,
  desc = "create missing parent directories on write",
  callback = function(ev)
    if ev.match:match("^%w+://") then return end
    vim.fn.mkdir(vim.fn.fnamemodify(ev.match, ":p:h"), "p")
  end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
  group = aug,
  desc = "restore the last cursor position",
  callback = function(ev)
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    local lines = vim.api.nvim_buf_line_count(ev.buf)
    if mark[1] > 0 and mark[1] <= lines then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Loom config files are shell, KDL and TOML; give them sane indentation.
vim.api.nvim_create_autocmd("FileType", {
  group = aug,
  pattern = { "sh", "bash", "lua", "toml", "yaml", "kdl", "fish" },
  callback = function()
    vim.opt_local.shiftwidth = 2
    vim.opt_local.tabstop = 2
    vim.opt_local.softtabstop = 2
  end,
})

------------------------------------------------------------------------ netrw
vim.g.netrw_banner = 0
vim.g.netrw_liststyle = 3
vim.g.netrw_winsize = 25

------------------------------------------------------------------- user overrides
-- Anything in ~/.config/nvim/lua/local.lua wins, and a syntax error in it will
-- not stop neovim from starting.
pcall(require, "local")
