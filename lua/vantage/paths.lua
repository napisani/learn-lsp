local M = {}

-- Resolve a (possibly workspace-relative) file path to the path nvim should
-- open. Absolute paths are returned unchanged; relative paths are joined to the
-- workspace root when one is known. Shared by quickfix-producing commands.
function M.resolve(workspace_root, file_path)
	file_path = file_path or ""
	if file_path:sub(1, 1) == "/" or file_path:match("^%a:[/\\]") then
		return file_path
	end
	if workspace_root and workspace_root ~= "" then
		return workspace_root .. "/" .. file_path
	end
	return file_path
end

-- Normalize a path for stable comparison against buffer names.
function M.normalize(path)
	if not path or path == "" then
		return ""
	end
	local resolved = vim.loop.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
	return (resolved:gsub("/+$", ""))
end

return M
