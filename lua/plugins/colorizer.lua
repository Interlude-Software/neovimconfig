return {
	"NvChad/nvim-colorizer.lua",
	event = { "BufReadPost", "BufNewFile" },
	config = function()
		require("colorizer").setup({
			filetypes = { "*" },
			user_default_options = {
				RGB = true,
				RRGGBB = true,
				names = true,
				RRGGBBAA = true,
				css = true,
				css_fn = true,
				mode = "background",
			},
		})
		vim.cmd("ColorizerAttachToBuffer")
	end,
}
