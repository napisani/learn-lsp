local M = {}

--- Return a blink.cmp provider spec for Vantage skill completion.
--- Users should add the returned provider to blink's sources.providers and enable
--- the provider for Vantage prompt buffers in their own blink configuration.
function M.provider(opts)
	opts = opts or {}
	return {
		name = opts.name or "Vantage Skills",
		module = "vantage.integrations.blink_skills",
		opts = opts.source_opts or {},
		async = true,
		min_keyword_length = 0,
	}
end

--- Explicit opt-in helper. Blink providers are normally configured during
--- blink.cmp setup, so this function returns the provider spec rather than
--- mutating blink's user configuration at runtime.
function M.setup(opts)
	local ok = pcall(require, "blink.cmp")
	if not ok then
		return false, "blink.cmp is not available"
	end
	return true, M.provider(opts)
end

return M
