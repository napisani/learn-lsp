if vim.g.loaded_vantage_nvim then
	return
end

vim.g.loaded_vantage_nvim = true
require("vantage").setup({})
