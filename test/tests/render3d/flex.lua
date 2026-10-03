local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local render = import("goluwa/render/render.lua")
local ffi = require("ffi")

local function create_flex_skeleton()
	local skeleton = Skeleton.New{
		BoneNames = {"root"},
		Parents = {-1},
		BindLocal = ffi.new("float[7]", {0, 0, 0, 0, 0, 0, 1}),
		InverseBind = ffi.new("float[12]", {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}),
	}
	skeleton.Flex = {
		ControllerNames = {"open", "wink"},
		ControllerMin = {0, 0},
		ControllerMax = {1, 1},
		DescCount = 2,
		Compute = function(flex, src, dest)
			dest[0] = src[0]
			dest[1] = src[1]
		end,
	}
	return skeleton
end

local function create_flex_entity(skeleton)
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	poly.Skin = {
		BoneIndices = ffi.new("uint8_t[?]", count * 4),
		BoneWeights = ffi.new("float[?]", count * 4),
		Flexes = {
			{
				Desc = 0,
				Pair = 0,
				Targets = {0, 1, 10, 11},
				Count = 1,
				Indices = ffi.new("uint32_t[1]", {0}),
				Deltas = ffi.new("float[6]", {0.1, 0, 0, 0, 0, 0}),
				Sides = ffi.new("uint8_t[1]", {0}),
			},
			{
				Desc = 0,
				Pair = 1,
				Targets = {0, 1, 10, 11},
				Count = 2,
				Indices = ffi.new("uint32_t[2]", {1, 2}),
				Deltas = ffi.new("float[12]", {0, 0.2, 0, 0, 0, 0, 0, 0.2, 0, 0, 0, 0}),
				Sides = ffi.new("uint8_t[2]", {0, 255}),
			},
		},
	}

	for i = 0, count - 1 do
		poly.Skin.BoneWeights[i * 4] = 1
	end

	local entity = Entity.New{Name = "flexed"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local primitive_entity = Entity.New{Name = "flexed_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(poly)
	primitive:SetMaterial(Material.New{})
	entity.visual.Skeleton = skeleton
	return entity, primitive, poly
end

local function read_vertices(primitive, count)
	local mapped = ffi.cast("float*", primitive:GetPolygon3D().mesh.vertex_buffer:GetBuffer():Map())
	local copy = ffi.new("float[?]", count * 17)
	ffi.copy(copy, mapped, count * 17 * 4)
	return copy
end

T.Test3D("flex moves vertices by its weights before skinning", function(draw)
	local skeleton = create_flex_skeleton()
	local entity, primitive, poly = create_flex_entity(skeleton)
	local animator = entity:AddComponent("animator")
	local flex = entity:AddComponent("flex")
	local bind = ffi.cast("float*", poly.mesh.vertex_buffer.data)
	local count = poly.mesh.vertex_buffer:GetVertexCount()
	local bind_x, bind_y1, bind_y2 = bind[0], bind[17 + 1], bind[34 + 1]
	animator:Bind(skeleton)
	flex:SetFlexByName("open", 0.5)
	flex:Update()
	animator:Animate(0)
	draw()
	render.GetDevice():WaitIdle()
	local skinned = read_vertices(primitive, count)
	T(math.abs(skinned[0] - (bind_x + 0.05)))["<"](1e-4)
	T(math.abs(skinned[17 + 1] - (bind_y1 + 0.1)))["<"](1e-4)
	T(math.abs(skinned[34 + 1] - bind_y2))["<"](1e-4)
	flex:SetFlexByName("wink", 1)
	animator:Animate(0)
	draw()
	render.GetDevice():WaitIdle()
	skinned = read_vertices(primitive, count)
	T(math.abs(skinned[34 + 1] - (bind_y2 + 0.2)))["<"](1e-4)
	flex:SetFlexByName("open", 12)
	flex:SetFlexByName("wink", 0)
	animator:Animate(0)
	draw()
	render.GetDevice():WaitIdle()
	skinned = read_vertices(primitive, count)
	T(math.abs(skinned[0] - bind_x))["<"](1e-4)
	T(math.abs(skinned[17 + 1] - bind_y1))["<"](1e-4)
	T(math.abs(bind[0] - bind_x))["<"](1e-6)
	animator:Unbind()
	entity:Remove()
end)

T.Test3D("flex lists the controllers of the model as dynamic properties", function()
	local skeleton = create_flex_skeleton()
	local entity = create_flex_entity(skeleton)
	local animator = entity:AddComponent("animator")
	local flex = entity:AddComponent("flex")
	T(#flex:GetDynamicProperties())["=="](0)
	local changes = {}

	flex:AddPropertyListener(function(_, key)
		changes[#changes + 1] = key
	end)

	animator:Bind(skeleton)
	flex:Update()
	T(changes[#changes])["=="]("DynamicProperties")
	local properties = flex:GetDynamicProperties()
	T(#properties)["=="](2)
	T(properties[1].var_name)["=="]("flex open")
	properties[1].set(flex, 0.75)
	T(properties[1].get(flex))["=="](0.75)
	T(animator:GetRig():GetFlex("open"))["=="](0.75)
	T(changes[#changes])["=="]("flex open")
	T(flex:OnSerialize().values.open)["=="](0.75)
	flex:ClearFlexes()
	T(properties[1].get(flex))["=="](0)
	flex:OnDeserialize{values = {wink = 0.25}}
	T(properties[2].get(flex))["=="](0.25)
	animator:Unbind()
	animator:Bind(skeleton)
	flex:Update()
	T(animator:GetRig():GetFlex("wink"))["=="](0.25)
	entity:Remove()
end)

T.Test3D("source engine faces are flexed by their controllers", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/player/alyx.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	local entity = Entity.New{Name = "alyx"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual:SetModelPath("models/player/alyx.mdl")
	entity:AddComponent("animator")
	local flex = entity:AddComponent("flex")

	T.WaitUntil(function()
		return entity.animator:GetRig() ~= nil
	end, 30)

	flex:Update()
	local rig = entity.animator:GetRig()
	local names = flex:GetFlexNames()
	T(#names)[">"](20)
	T(#flex:GetDynamicProperties())["=="](#names)
	local head

	for _, skinned in ipairs(rig.skinned) do
		if skinned.morph then head = skinned end
	end

	T(head ~= nil)["=="](true)

	for _, name in ipairs(names) do
		flex:SetFlexByName(name, 1)
	end

	rig:Update()
	T(head.morph_active)["=="](true)
	local moved = {}
	local largest = 0

	for i, entry in ipairs(head.skin.Flexes) do
		local w1, w2 = rig.morph_weights[head.weight_offset + i * 2 - 2],
		rig.morph_weights[head.weight_offset + i * 2 - 1]

		for k = 0, entry.Count - 1 do
			local w = w1 + (w2 - w1) * entry.Sides[k] / 255
			local vertex = entry.Indices[k]
			local offset = moved[vertex] or {0, 0, 0}
			moved[vertex] = offset

			for c = 1, 3 do
				offset[c] = offset[c] + entry.Deltas[k * 6 + c - 1] * w
			end

			largest = math.max(largest, math.sqrt(offset[1] ^ 2 + offset[2] ^ 2 + offset[3] ^ 2))
		end
	end

	T(largest)[">"](0.002)
	T(largest)["<"](0.1)
	entity:Remove()
end)
