local process = import("goluwa/bindings/process.lua")
local codec = import("goluwa/codec.lua")

local gif = library()
gif.file_extensions = {"gif"}
gif.magic_headers = {"GIF87a", "GIF89a"}

local function read_all_err(proc)
	local parts = {}

	while true do
		local chunk, err = proc:read_err()

		if chunk == nil then
			if err and err ~= "Resource temporarily unavailable" then parts[#parts + 1] = err end
			break
		end

		if chunk == "" then break end
		parts[#parts + 1] = chunk
	end

	return table.concat(parts)
end

function gif.Decode(data)
	local base = assert(os.tmpname())
	os.remove(base)

	local input_path = base .. ".gif"
	local output_path = base .. ".png"
	local file = assert(io.open(input_path, "wb"))
	file:write(data)
	file:close()

	local proc, err = process.spawn({
		command = "convert",
		args = {input_path .. "[0]", output_path},
		stdout = "pipe",
		stderr = "pipe",
	})

	if not proc then
		os.remove(input_path)
		error("unable to spawn convert: " .. tostring(err))
	end

	local exit_code = proc:wait()
	local stderr = read_all_err(proc)
	proc:close()

	if exit_code ~= 0 then
		os.remove(input_path)
		os.remove(output_path)
		error((stderr ~= "" and stderr or ("convert exited with code %d"):format(exit_code)))
	end

	local ok, decoded = pcall(codec.DecodeFile, output_path, "png")
	local decode_err = ok and nil or decoded

	os.remove(input_path)
	os.remove(output_path)

	if not ok then error(decode_err) end
	return decoded
end

return gif