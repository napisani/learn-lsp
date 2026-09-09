-- Single place that knows the shape of a backend response envelope
-- ({ok, result, error}) and how to extract a message from `error`, which may
-- be either a plain string or a {message = ...} table.
local M = {}

function M.error_message(response)
	if response and response.error then
		if type(response.error) == "table" and response.error.message then
			return response.error.message
		end
		return response.error
	end
	return "Unknown backend error."
end

function M.error_markdown(response)
	return "## Error\n\n" .. tostring(M.error_message(response))
end

--- Unwraps a backend response, returning `result, nil` on success or
--- `nil, error_markdown` on failure. When `expected_kind` is given, a
--- present-but-wrong-kind result also fails, using `invalid_kind_message`
--- (defaulting to a generic "invalid <kind> response" message) as the body.
function M.unwrap(response, expected_kind, invalid_kind_message)
	if not response or not response.ok then
		return nil, M.error_markdown(response)
	end

	if expected_kind and (not response.result or response.result.kind ~= expected_kind) then
		local message = invalid_kind_message or ("Backend returned an invalid " .. expected_kind .. " response.")
		return nil, "## Error\n\n" .. message
	end

	return response.result, nil
end

return M
