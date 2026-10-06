local signals = {}
local directory = assert(os.getenv("E2E_DIR"), "E2E_DIR is not set")

function signals.Path(name)
	return directory .. name
end

function signals.Write(name, text)
	local path = signals.Path(name)
	local temporary = path .. ".tmp"
	local file = assert(io.open(temporary, "wb"))
	file:write(text or "")
	file:close()
	assert(os.rename(temporary, path))
end

function signals.Read(name)
	local file = io.open(signals.Path(name), "rb")

	if not file then return nil end

	local text = file:read("*a")
	file:close()
	return text
end

return signals
