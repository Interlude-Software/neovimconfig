return {
  "williamboman/mason.nvim",
  opts = {
    registries = {
      "github:mason-org/mason-registry",
      "github:Crashdummyy/mason-registry",  -- Required for roslyn
    },
  },
  config = function(_, opts)
    require("mason").setup(opts)

    -- Auto-install the tools the config depends on. Names resolve across both
    -- registries above (roslyn lives in the Crashdummyy one).
    local ensure = { "roslyn", "netcoredbg", "clangd", "codelldb", "clang-format" }
    local registry = require("mason-registry")

    local function install_missing()
      for _, name in ipairs(ensure) do
        local ok, pkg = pcall(registry.get_package, name)
        if ok and not pkg:is_installed() then
          pkg:install()
        end
      end
    end

    -- refresh() pulls the registries first (needed on a clean machine), then installs.
    if registry.refresh then
      registry.refresh(install_missing)
    else
      install_missing()
    end
  end,
}
