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

-- one bone that stays where it is, and a face: controller "open" drives flex 0 and "wink" flex 1
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

-- vertex 0 follows flex 0 on its own, vertex 1 is half way between flex 0 (side 0) and flex 1 (side 255)
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

T.Test3D("flex moves vertices by its weights before skinning", function(draw)
	local skeleton = create_flex_skeleton()
	local entity, primitive, poly = create_flex_entity(skeleton)
	local animator = entity:AddComponent("animator")
	local flex = entity:AddComponent("flex")
	local bind = ffi.cast("float*", poly.mesh.vertex_buffer.data)
	local bind_x, bind_y1, bind_y2 = bind[0], bind[17 + 1], bind[34 + 1]
	animator:Bind(skeleton)
	flex:SetFlexByName("open", 0.5)
	flex:Update()
	animator:Animate(0)
	draw()
	render.GetDevice():WaitIdle()
	local skinned = ffi.cast("float*", primitive:GetPolygon3D().mesh.vertex_buffer:GetBuffer():Map())
	T(math.abs(skinned[0] - (bind_x + 0.05)))["<"](1e-4)
	-- a pair takes the weight of its first flex on side 0 and of the second on side 255
	T(math.abs(skinned[17 + 1] - (bind_y1 + 0.1)))["<"](1e-4)
	T(math.abs(skinned[34 + 1] - bind_y2))["<"](1e-4)
	local target = flex.targets[1]
	flex:SetFlexByName("wink", 1)
	flex:Update()
	T(math.abs(target.scratch[34 + 1] - (bind_y2 + 0.2)))["<"](1e-4)
	-- past target3 a flex has no weight, and the bind pose is skinned again
	flex:SetFlexByName("open", 12)
	flex:SetFlexByName("wink", 0)
	flex:Update()
	T(target.skinned.bind_address == target.rest_address)["=="](true)
	T(math.abs(bind[0] - bind_x))["<"](1e-6)
	-- removing the component gives the animator its bind pose back
	flex:SetFlexByName("open", 1)
	flex:Update()
	T(target.skinned.bind_address ~= target.rest_address)["=="](true)
	entity:RemoveComponent("flex")
	T(target.skinned.bind_address == target.rest_address)["=="](true)
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
	T(changes[#changes])["=="]("flex open")
	T(flex:OnSerialize().values.open)["=="](0.75)
	flex:ClearFlexes()
	T(properties[1].get(flex))["=="](0)
	flex:OnDeserialize{values = {wink = 0.25}}
	T(properties[2].get(flex))["=="](0.25)
	-- values set before a model is bound are kept
	animator:Unbind()
	animator:Bind(skeleton)
	flex:Update()
	T(flex.controller[1])["=="](0.25)
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
		return flex.targets[1] ~= nil
	end, 30)

	local names = flex:GetFlexNames()
	T(#names)[">"](20)
	T(#flex:GetDynamicProperties())["=="](#names)
	-- the head is one of the models of the body
	local target = flex.targets[1]
	T(target.skinned.bind_address == target.rest_address)["=="](true)

	for _, name in ipairs(names) do
		flex:SetFlexByName(name, 1)
	end

	flex:Update()
	T(target.skinned.bind_address ~= target.rest_address)["=="](true)
	local largest = 0

	for i = 0, target.skinned.count - 1 do
		for c = 0, 2 do
			largest = math.max(largest, math.abs(target.scratch[i * 17 + c] - target.bind_data[i * 17 + c]))
		end
	end

	-- facial expressions move the face by centimeters
	T(largest)[">"](0.002)
	T(largest)["<"](0.1)
	entity:Remove()
end)
