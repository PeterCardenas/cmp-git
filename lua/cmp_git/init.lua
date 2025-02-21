local Source = require("cmp_git.source")

local M = {}

---@type cmp_git.Source?
M.source = nil

---@param overrides cmp_git.Config Can be a partial config
function M.setup(overrides)
    M.source = Source.new(overrides)
    require("cmp").register_source("git", M.source)
end

return M
