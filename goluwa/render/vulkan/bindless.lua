local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local render = import("goluwa/render/render.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local bindless = {}
bindless.SET_INDEX = 1
bindless.RELEASE_LOG_SIZE = 1024
-- a released index can still be read by frames in flight, so it is only handed out again this many frames later
local REUSE_DELAY_FRAMES = 8

local function create_slot(binding_index, capacity, name)
	return {
		binding_index = binding_index,
		capacity = capacity,
		name = name,
		registry = setmetatable({}, {__mode = "k"}),
		entries = {},
		free = {},
		pending = {},
		next_index = 0,
	}
end

local function create_state(device)
	local capacities = render.GetBindlessDescriptorCapacities()
	local layout = DescriptorSetLayout.New(
		device,
		{
			{
				binding_index = 0,
				type = "combined_image_sampler",
				stageFlags = "all",
				count = capacities.textures,
				update_unused_while_pending = true,
			},
			{
				binding_index = 1,
				type = "combined_image_sampler",
				stageFlags = "all",
				count = capacities.cubemaps,
				update_unused_while_pending = true,
			},
			{
				binding_index = 2,
				type = "sampled_image",
				stageFlags = "all",
				count = capacities.views,
				update_unused_while_pending = true,
			},
			{
				binding_index = 3,
				type = "sampler",
				stageFlags = "all",
				count = capacities.samplers,
				update_unused_while_pending = true,
			},
		}
	)
	local pool = DescriptorPool.New(
		device,
		{
			{
				type = "combined_image_sampler",
				count = capacities.textures + capacities.cubemaps,
			},
			{type = "sampled_image", count = capacities.views},
			{type = "sampler", count = capacities.samplers},
		},
		1
	)
	return {
		device = device,
		capacities = capacities,
		binding_counts = {
			[0] = capacities.textures,
			[1] = capacities.cubemaps,
			[2] = capacities.views,
			[3] = capacities.samplers,
		},
		layout = layout,
		pool = pool,
		set = pool:AllocateDescriptorSet(layout),
		textures = create_slot(0, capacities.textures, "texture"),
		cubemaps = create_slot(1, capacities.cubemaps, "cubemap"),
		views = create_slot(2, capacities.views, "texture view"),
		samplers = create_slot(3, capacities.samplers, "sampler"),
		releases = 0,
		release_log = {},
	}
end

function bindless.GetReleased(state, serial)
	if state.releases - serial >= bindless.RELEASE_LOG_SIZE then return false end

	return state.release_log[serial % bindless.RELEASE_LOG_SIZE]
end

function bindless.Get(device)
	local state = device.bindless

	if not state then
		state = create_state(device)
		device.bindless = state
	end

	return state
end

local function reclaim(slot, frame)
	local pending = slot.pending
	local i = 1

	while i <= #pending do
		local item = pending[i]

		if frame == nil or item.cleared and frame - item.frame >= REUSE_DELAY_FRAMES then
			item.reclaimed = true
			slot.free[#slot.free + 1] = item.index
			table.remove(pending, i)
		else
			i = i + 1
		end
	end
end

local function take_index(state, slot)
	if slot.pending[1] then reclaim(slot, system.GetFrameNumber()) end

	if slot.free[1] then return table.remove(slot.free) end

	if slot.next_index < slot.capacity then
		local index = slot.next_index
		slot.next_index = index + 1
		return index
	end

	if slot.pending[1] then
		state.device:WaitIdle()
		reclaim(slot, nil)
		return table.remove(slot.free)
	end

	error(
		"bindless " .. slot.name .. " registry is full: " .. slot.capacity .. " descriptors",
		3
	)
end

local write_entry

local function clear_index(state, slot, item)
	if item.reclaimed then return end

	local entries = slot.entries
	entries[item.index + 1] = entries[1]
	write_entry(state, slot, item.index)
	entries[item.index + 1] = nil
	item.cleared = true
end

local function release_index(state, slot, index, key)
	local item = {index = index, frame = system.GetFrameNumber()}
	slot.entries[index + 1] = nil
	slot.pending[#slot.pending + 1] = item
	state.releases = state.releases + 1
	state.release_log[state.releases % bindless.RELEASE_LOG_SIZE] = key

	if slot ~= state.views then
		state.device:DeferRelease(function()
			clear_index(state, slot, item)
		end)
	else
		item.cleared = true
	end
end

function write_entry(state, slot, index)
	local device = state.device
	local entries = slot.entries

	if slot == state.views then
		device:UpdateSampledImageDescriptorSetArray(state.set, slot.binding_index, entries, state.fallback_view, 1, index)
	elseif slot == state.samplers then
		device:UpdateSamplerDescriptorSetArray(state.set, slot.binding_index, entries, state.fallback_sampler, 1, index)
	else
		device:UpdateDescriptorSetArray(
			state.set,
			slot.binding_index,
			entries,
			state.fallback_view,
			state.fallback_sampler,
			1,
			index
		)
	end
end

function bindless.Acquire(state, slot, key, sub_key, entry)
	local by_key = slot.registry[key]
	local index = by_key and by_key[sub_key]

	if index then
		local current = slot.entries[index + 1]

		if current.view == entry.view and current.layout == entry.layout then
			return index
		end

		slot.entries[index + 1] = entry
		write_entry(state, slot, index)
		return index
	end

	index = take_index(state, slot)
	slot.entries[index + 1] = entry
	write_entry(state, slot, index)

	if not by_key then
		by_key = {}
		slot.registry[key] = by_key
	end

	by_key[sub_key] = index
	return index
end

function bindless.Release(state, tex)
	for _, slot in ipairs{state.textures, state.cubemaps, state.views} do
		local by_key = slot.registry[tex]

		if by_key then
			for _, index in pairs(by_key) do
				release_index(state, slot, index, tex)
			end

			slot.registry[tex] = nil
		end
	end
end

function bindless.RefreshView(state, tex, view)
	for _, slot in ipairs{state.textures, state.cubemaps, state.views} do
		local by_key = slot.registry[tex]

		if by_key then
			for _, index in pairs(by_key) do
				local entry = slot.entries[index + 1]
				local layout = tex.sampled_layout or "shader_read_only_optimal"

				if entry.view ~= view or entry.layout and entry.layout ~= layout then
					entry.view = view

					if entry.layout then entry.layout = layout end

					write_entry(state, slot, index)
				end
			end
		end
	end
end

event.AddListener("TextureRemoved", "bindless", function(tex)
	if render.shutting_down then return end

	local device = render.GetDevice()

	if not device:IsValid() or not device.bindless then return end

	bindless.Release(device.bindless, tex)
end)

event.AddListener("TextureViewChanged", "bindless", function(tex)
	local device = render.GetDevice()

	if not device or not device.bindless then return end

	bindless.RefreshView(device.bindless, tex, tex:GetView())
end)

table.insert(import("goluwa/render/vulkan/internal/checkpoints.lua").state_reporters, function()
	local state = render.GetDevice().bindless

	if not state then return end

	local lines = {
		"bindless registry (used / free / pending release), " .. state.releases .. " releases so far:",
	}

	for _, slot in ipairs{state.textures, state.cubemaps, state.views, state.samplers} do
		lines[#lines + 1] = string.format(
			"  %s: %d of %d used, %d free, %d pending",
			slot.name,
			slot.next_index - #slot.free - #slot.pending,
			slot.capacity,
			#slot.free,
			#slot.pending
		)
	end

	return table.concat(lines, "\n")
end)

return bindless
