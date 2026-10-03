local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local ffi = require("ffi")
-- facial expressions. a model's flex controllers (the sliders of a face poser) are set by name, and on an entity with an
-- animator they move the vertices of the face before the animator skins them. controllers are model specific, so the
-- editor gets them as dynamic properties
local Flex = objects.CreateTemplate("flex")
Flex.Is3D = true
-- polygon_3d's vertex is 17 floats, position first and normal after that
local VERTEX_FLOATS = 17
local FloatPtr = ffi.typeof("float *")

-- the weight a flex has at a controller weight: zero up to target0 and past target3, one between target1 and target2
local function flex_ramp(weight, target0, target1, target2, target3)
	if weight <= target0 or weight >= target3 then return 0 end

	if weight < target1 then return (weight - target0) / (target1 - target0) end

	if weight <= target2 then return 1 end

	return (target3 - weight) / (target3 - target2)
end

function Flex:Initialize()
	self.values = {}
	self.targets = {}
end

-- the skeleton the model of the entity came with, whose Flex has the controllers
function Flex:GetFlexNames()
	return self.skeleton and self.skeleton.Flex and self.skeleton.Flex.ControllerNames or {}
end

function Flex:GetFlexRange(name)
	local flex = self.skeleton.Flex
	local index = self.index[name]
	return flex.ControllerMin[index + 1], flex.ControllerMax[index + 1]
end

function Flex:GetFlexByName(name)
	return self.values[name] or 0
end

function Flex:SetFlexByName(name, value)
	local old = self.values[name]
	self.values[name] = value ~= 0 and value or nil

	if self.index and self.index[name] then
		self.controller[self.index[name]] = value
	end

	self.dirty = true

	if self.property_change_listeners then
		objects.NotifyPropertyListeners(self, {var_name = "flex " .. name}, old or 0, value)
	end
end

function Flex:ClearFlexes()
	for name in pairs(self.values) do
		self:SetFlexByName(name, 0)
	end
end

function Flex:GetDynamicProperties()
	local out = {}

	for _, name in ipairs(self:GetFlexNames()) do
		local min, max = self:GetFlexRange(name)
		out[#out + 1] = {
			var_name = "flex " .. name,
			type = "number",
			default = 0,
			min = min,
			max = max,
			slider = true,
			get = function(flex)
				return flex:GetFlexByName(name)
			end,
			set = function(flex, value)
				flex:SetFlexByName(name, value)
			end,
		}
	end

	return out
end

function Flex:OnSerialize()
	return {values = table.copy(self.values)}
end

function Flex:OnDeserialize(data)
	for name, value in pairs(data and data.values or {}) do
		self:SetFlexByName(name, value)
	end
end

function Flex:SetSkeleton(skeleton)
	self.skeleton = skeleton
	self.index = nil
	self.controller = nil
	self.desc = nil

	if skeleton and skeleton.Flex then
		self.index = {}
		self.controller = ffi.new("float[?]", #skeleton.Flex.ControllerNames)
		self.desc = ffi.new("float[?]", skeleton.Flex.DescCount)

		for i, name in ipairs(skeleton.Flex.ControllerNames) do
			self.index[name] = i - 1
			self.controller[i - 1] = self.values[name] or 0
		end
	end

	objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
end

-- gives the skinned vertex arrays of the animator that have a face a bind vertex array of their own to flex
function Flex:Bind(animator)
	self:Unbind()
	self.animator = animator
	self.bound = animator.skinned

	for _, skinned in ipairs(animator.skinned) do
		local flexes = skinned.skin.Flexes

		if flexes[1] then
			local buffer = skinned.bind_vertex_buffer
			self.targets[#self.targets + 1] = {
				skinned = skinned,
				flexes = flexes,
				weights = {},
				slots = {},
				slot = 0,
				rest_address = skinned.bind_address,
				byte_size = buffer.byte_size,
				bind_data = ffi.cast(FloatPtr, buffer.data),
				scratch = ffi.new("float[?]", buffer.byte_size / 4),
			}
		end
	end

	self.dirty = next(self.values) ~= nil
end

function Flex:Unbind()
	for _, target in ipairs(self.targets) do
		target.skinned.bind_address = target.rest_address

		for _, slot in pairs(target.slots) do
			slot.buffer:Remove()
		end
	end

	if self.animator then self.animator.dirty = true end

	self.targets = {}
	self.animator = nil
	self.bound = nil
end

function Flex:OnRemove()
	self:Unbind()
end

-- computes the weights of the flexes from the flex controllers and writes the flexed vertices of the models with a face
-- to their own bind vertex array, which skinning then reads in place of the bind pose
function Flex:Apply()
	self.dirty = false
	self.skeleton.Flex:Compute(self.controller, self.desc)
	local desc = self.desc

	for _, target in ipairs(self.targets) do
		local flexes = target.flexes
		local weights = target.weights
		local active = false

		for i, entry in ipairs(flexes) do
			local t = entry.Targets
			local w1 = flex_ramp(desc[entry.Desc], t[1], t[2], t[3], t[4])
			local w2 = entry.Pair ~= 0 and flex_ramp(desc[entry.Pair], t[1], t[2], t[3], t[4]) or w1
			weights[i * 2 - 1] = w1
			weights[i * 2] = w2

			if w1 ~= 0 or w2 ~= 0 then active = true end
		end

		if not active then
			target.skinned.bind_address = target.rest_address
		else
			local scratch = target.scratch
			ffi.copy(scratch, target.bind_data, target.byte_size)
			local count = target.skinned.count

			for i, entry in ipairs(flexes) do
				local w1, w2 = weights[i * 2 - 1], weights[i * 2]

				if w1 ~= 0 or w2 ~= 0 then
					local indices, deltas, sides = entry.Indices, entry.Deltas, entry.Sides
					local paired = entry.Pair ~= 0

					for k = 0, entry.Count - 1 do
						local vertex = indices[k]

						if vertex < count then
							local w = paired and w1 + (w2 - w1) * sides[k] / 255 or w1
							local o = vertex * VERTEX_FLOATS
							local d = k * 6
							scratch[o] = scratch[o] + deltas[d] * w
							scratch[o + 1] = scratch[o + 1] + deltas[d + 1] * w
							scratch[o + 2] = scratch[o + 2] + deltas[d + 2] * w
							scratch[o + 3] = scratch[o + 3] + deltas[d + 3] * w
							scratch[o + 4] = scratch[o + 4] + deltas[d + 4] * w
							scratch[o + 5] = scratch[o + 5] + deltas[d + 5] * w
						end
					end
				end
			end

			-- frames in flight may still read the vertex array of the previous change, so every change writes the next one
			target.slot = (target.slot + 1) % skinning.RING
			local slot = target.slots[target.slot]

			if not slot then
				local buffer = render.CreateBuffer{
					byte_size = target.byte_size,
					buffer_usage = {"storage_buffer", "shader_device_address"},
					memory_property = {"host_visible", "host_coherent"},
					label = "flexed bind vertices",
				}
				slot = {buffer = buffer, mapped = ffi.cast(FloatPtr, buffer:Map()), address = buffer:GetDeviceAddress()}
				target.slots[target.slot] = slot
			end

			ffi.copy(slot.mapped, scratch, target.byte_size)
			target.skinned.bind_address = slot.address
		end
	end

	self.animator.dirty = true
end

function Flex:Update()
	local skeleton = self.Owner.visual.Skeleton

	if skeleton ~= self.skeleton then self:SetSkeleton(skeleton) end

	local animator = self.Owner.animator

	if not (skeleton and skeleton.Flex and animator and animator.skeleton == skeleton) then
		return
	end

	-- the animator makes new skinned vertex arrays every time it binds a model
	if animator.skinned ~= self.bound then self:Bind(animator) end

	if self.dirty then self:Apply() end
end

function Flex:OnFirstCreated()
	event.AddListener("Update", "flex", function()
		for _, flex in ipairs(Flex.Instances) do
			flex:Update()
		end
	end)
end

function Flex:OnLastRemoved()
	event.RemoveListener("Update", "flex")
end

return Flex:Register()
