local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local checkpoints = {}
-- functions (address, precision) returning a line that says what lives at a faulting gpu address, or nil
checkpoints.address_describers = {}
-- functions returning a short text about engine state to include in the device lost report
checkpoints.state_reporters = {}
local report_lines

local function print(...)
	_G.print(...)

	if report_lines then
		local parts = {}

		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end

		report_lines[#report_lines + 1] = table.concat(parts, "\t")
	end
end

checkpoints.enabled = os.getenv("GOLUWA_CHECKPOINTS") ~= nil
local VkCheckpointDataArray = ffi.typeof("$[?]", vulkan.vk.VkCheckpointDataNV)
local start_time = system.GetTime()
local ids = {}
local names = {}
local set_checkpoint

function checkpoints.Set(cmd, name)
	local id = ids[name]

	if not id then
		id = #names + 1
		names[id] = name
		ids[name] = id
	end

	set_checkpoint = set_checkpoint or cmd.command_pool.device:GetExtension("vkCmdSetCheckpointNV")
	set_checkpoint(cmd.ptr[0], ffi.cast("void *", id))
end

function checkpoints.Instrument(meta, method_names)
	for _, method in ipairs(method_names) do
		local original = meta[method]
		meta[method] = function(self, ...)
			local level = 2
			local info = debug.getinfo(level, "Sl")

			while info and info.short_src:find("render/vulkan/", nil, true) do
				level = level + 1
				info = debug.getinfo(level, "Sl")
			end

			checkpoints.Set(
				self,
				method .. " " .. (
						info and
						(
							info.short_src .. ":" .. info.currentline
						)
						or
						"?"
					) .. (
						self.checkpoint_context and
						(
							" [" .. self.checkpoint_context .. "]"
						)
						or
						""
					)
			)
			return original(self, ...)
		end
	end
end

local VkDeviceFaultCounts = ffi.typeof("$[1]", vulkan.vk.VkDeviceFaultCountsEXT)
local VkDeviceFaultInfo = ffi.typeof("$[1]", vulkan.vk.VkDeviceFaultInfoEXT)
local VkDeviceFaultAddressInfoArray = ffi.typeof("$[?]", vulkan.vk.VkDeviceFaultAddressInfoEXT)
local VkDeviceFaultVendorInfoArray = ffi.typeof("$[?]", vulkan.vk.VkDeviceFaultVendorInfoEXT)

local function report_fault_info()
	local get = render.GetDevice():TryGetExtension("vkGetDeviceFaultInfoEXT")

	if not get then
		print("no fault info: the driver does not have VK_EXT_device_fault")
		return
	end

	local device = render.GetDevice().ptr[0]
	local counts = VkDeviceFaultCounts()
	counts[0].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_EXT
	local result = get(device, counts, nil)

	if result ~= 0 then
		print("vkGetDeviceFaultInfoEXT counts failed: " .. tostring(result))
		return
	end

	local addresses = VkDeviceFaultAddressInfoArray(math.max(counts[0].addressInfoCount, 1))
	local vendors = VkDeviceFaultVendorInfoArray(math.max(counts[0].vendorInfoCount, 1))
	local info = VkDeviceFaultInfo()
	info[0].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_EXT
	info[0].pAddressInfos = addresses
	info[0].pVendorInfos = vendors
	result = get(device, counts, info)

	if result ~= 0 then
		print("vkGetDeviceFaultInfoEXT failed: " .. tostring(result))
		return
	end

	print(
		string.format(
			"device fault: %q (%d address infos, %d vendor infos)",
			ffi.string(info[0].description),
			counts[0].addressInfoCount,
			counts[0].vendorInfoCount
		)
	)

	for i = 0, counts[0].addressInfoCount - 1 do
		local address = tonumber(addresses[i].reportedAddress)
		print(
			string.format(
				"  address type %d  0x%x  precision 0x%x",
				tonumber(addresses[i].addressType),
				address,
				tonumber(addresses[i].addressPrecision)
			)
		)

		if
			addresses[i].addressType == vulkan.vk.VkDeviceFaultAddressTypeEXT.VK_DEVICE_FAULT_ADDRESS_TYPE_READ_INVALID_EXT or
			addresses[i].addressType == vulkan.vk.VkDeviceFaultAddressTypeEXT.VK_DEVICE_FAULT_ADDRESS_TYPE_WRITE_INVALID_EXT
		then
			for _, describe in ipairs(checkpoints.address_describers) do
				local text = describe(address, tonumber(addresses[i].addressPrecision))

				if text then print("    " .. text) end
			end
		end
	end

	for i = 0, counts[0].vendorInfoCount - 1 do
		print(
			string.format(
				"  vendor %q  code 0x%x  data 0x%x",
				ffi.string(vendors[i].description),
				tonumber(vendors[i].vendorFaultCode),
				tonumber(vendors[i].vendorFaultData)
			)
		)
	end
end

local function report_xid()
	local pipe = io.popen(
		"journalctl -k --no-pager --since '-2min' 2>/dev/null | grep -i 'NVRM: Xid' | tail -n 12"
	)

	if not pipe then return end

	local text = pipe:read("*a")
	pipe:close()
	print(
		text ~= "" and
			"kernel log (nvidia Xid, last 2 minutes):\n" .. text or
			"no nvidia Xid in the kernel log of the last 2 minutes"
	)
end

local function report_checkpoints()
	local get = render.GetDevice():TryGetExtension("vkGetQueueCheckpointDataNV")

	if not get then
		print("no checkpoints: the driver does not have VK_NV_device_diagnostic_checkpoints")
		return
	end

	local queue = render.GetQueue().ptr[0]
	local count = ffi.new("uint32_t[1]")
	get(queue, count, nil)
	local data = VkCheckpointDataArray(count[0])

	for i = 0, count[0] - 1 do
		data[i].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_CHECKPOINT_DATA_NV
	end

	get(queue, count, data)
	print("the queue had reached " .. count[0] .. " checkpoints:")

	for i = 0, count[0] - 1 do
		print(
			string.format(
				"  stage 0x%x  %s",
				tonumber(data[i].stage),
				names[tonumber(ffi.cast("uintptr_t", data[i].pCheckpointMarker))] or "?"
			)
		)
	end
end

local function report_state()
	for _, report in ipairs(checkpoints.state_reporters) do
		local text = report()

		if text then print(text) end
	end
end

function checkpoints.Report()
	report_lines = {}
	print(
		string.format(
			"device lost in frame %d, %.2f s after the engine started",
			system.GetFrameNumber(),
			system.GetTime() - start_time
		)
	)
	print(
		checkpoints.enabled and
			"checkpoints: on" or
			"checkpoints: off, run with GOLUWA_CHECKPOINTS=1 to see the pass the queue was in"
	)
	local parts = {report_state, report_fault_info}

	if checkpoints.enabled then table.insert(parts, report_checkpoints) end

	if jit.os == "Linux" then table.insert(parts, report_xid) end

	for _, part in ipairs(parts) do
		local ok, err = pcall(part)

		if not ok then print("device lost report failed: " .. tostring(err)) end
	end

	local path = "./storage/logs/device_lost_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
	local file = io.open(path, "wb")

	if file then
		file:write(table.concat(report_lines, "\n"), "\n")
		file:close()
		_G.print("device lost report written to " .. path)
	end

	report_lines = nil
end

return checkpoints
