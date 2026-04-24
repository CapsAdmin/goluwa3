local prototype = import("goluwa/prototype.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Rect = import("goluwa/structs/rect.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local META = prototype.CreateTemplate("render3d_model_preview")
local DEFAULT_VIEW_OFFSET = Vec3(1, 1, 1):GetNormalized()
local DEFAULT_LIGHT_DIRECTION = Vec3(1, 1, 1):GetNormalized()
local DEFAULT_CLEAR_COLOR = {0, 0, 0, 0}
local cached_final_matrix = Matrix44()
local active_preview = nil
local preview_pipeline = nil
local aabb_corners = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}
local opaque_blend = {
	src_color_blend_factor = "one",
	dst_color_blend_factor = "zero",
	color_blend_op = "add",
	src_alpha_blend_factor = "one",
	dst_alpha_blend_factor = "zero",
	alpha_blend_op = "add",
}
local translucent_blend = {
	src_color_blend_factor = "src_alpha",
	dst_color_blend_factor = "one_minus_src_alpha",
	color_blend_op = "add",
	src_alpha_blend_factor = "one",
	dst_alpha_blend_factor = "zero",
	alpha_blend_op = "add",
}
META:GetSet("Width", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Height", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Padding", 1.1)
META:GetSet("AmbientStrength", 0.3)
META:GetSet("LightStrength", 0.9)
META:GetSet("ViewOffset", DEFAULT_VIEW_OFFSET)
META:GetSet("LightDirection", DEFAULT_LIGHT_DIRECTION)

local function is_valid_entity(entity)
	return entity and entity.IsValid and entity:IsValid() or false
end

local function is_previewable_model_target(target)
	return type(target) == "table" and
		type(target.GetWorldMatrix) == "function" and
		type(target.BuildAABB) == "function"
end

local function get_previewable_model(target)
	local model = target

	if not is_previewable_model_target(model) then
		if not is_valid_entity(target) then return nil end

		model = target.model
	end

	if not model or not model.Primitives or not model.Primitives[1] then
		return nil
	end

	return model
end

local function populate_aabb_corners(aabb)
	aabb_corners[1].x, aabb_corners[1].y, aabb_corners[1].z = aabb.min_x, aabb.min_y, aabb.min_z
	aabb_corners[2].x, aabb_corners[2].y, aabb_corners[2].z = aabb.min_x, aabb.min_y, aabb.max_z
	aabb_corners[3].x, aabb_corners[3].y, aabb_corners[3].z = aabb.min_x, aabb.max_y, aabb.min_z
	aabb_corners[4].x, aabb_corners[4].y, aabb_corners[4].z = aabb.min_x, aabb.max_y, aabb.max_z
	aabb_corners[5].x, aabb_corners[5].y, aabb_corners[5].z = aabb.max_x, aabb.min_y, aabb.min_z
	aabb_corners[6].x, aabb_corners[6].y, aabb_corners[6].z = aabb.max_x, aabb.min_y, aabb.max_z
	aabb_corners[7].x, aabb_corners[7].y, aabb_corners[7].z = aabb.max_x, aabb.max_y, aabb.min_z
	aabb_corners[8].x, aabb_corners[8].y, aabb_corners[8].z = aabb.max_x, aabb.max_y, aabb.max_z
	return aabb_corners
end

local function upload_preview_constants(pipeline)
	local cmd = render.GetCommandBuffer()
	local material = render3d.GetMaterial()
	local translucent = material:GetTranslucent()
	cmd:SetCullMode(material:GetDoubleSided() and "none" or orientation.CULL_MODE)
	cmd:SetColorBlendEnable(0, translucent)
	cmd:SetColorBlendEquation(0, translucent and translucent_blend or opaque_blend)
	pipeline:UploadConstants()
end

local function create_preview_pipeline()
	return EasyPipeline.New{
		name = "model_preview",
		dont_create_framebuffers = true,
		ColorFormat = {{"r8g8b8a8_srgb", {"color", "rgba"}}},
		DepthFormat = "d32_sfloat",
		RasterizationSamples = "1",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			uv = true,
		},
		fragment = {
			uniform_buffers = {
				{
					name = "preview_data",
					block = {
						{
							"LightDirectionStrength",
							"vec4",
							function(self, block, key)
								local direction = active_preview:GetLightDirection()
								block[key][0] = direction.x
								block[key][1] = direction.y
								block[key][2] = direction.z
								block[key][3] = active_preview:GetLightStrength()
							end,
						},
						{
							"LightingParams",
							"vec4",
							function(self, block, key)
								block[key][0] = active_preview:GetAmbientStrength()
								block[key][1] = 0
								block[key][2] = 0
								block[key][3] = 0
							end,
						},
					},
				},
				{
					name = "model",
					block = model_pipeline.GetSurfaceMaterialBlock(),
				},
			},
			shader = [[
			]] .. model_pipeline.BuildSurfaceSamplingGlsl("model") .. [[

			void main() {
				vec4 albedo = get_surface_color();

				discard_surface_alpha(albedo);

				vec3 normal = normalize(in_normal);
				vec3 light_dir = normalize(preview_data.LightDirectionStrength.xyz);
				float diffuse = max(dot(normal, light_dir), 0.0) * preview_data.LightDirectionStrength.w;
				vec3 lit = albedo.rgb * (preview_data.LightingParams.x + diffuse);
				lit += get_surface_emissive(albedo.rgb);
				set_color(vec4(lit, albedo.a));
			}
		]],
		},
		CullMode = orientation.CULL_MODE,
		FrontFace = orientation.FRONT_FACE,
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "less_or_equal",
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = {"r", "g", "b", "a"},
		on_draw = function(self)
			active_preview:DrawActiveEntity(self)
		end,
	}
end

local function get_preview_pipeline()
	if not preview_pipeline then preview_pipeline = create_preview_pipeline() end

	return preview_pipeline
end

function META.New(config)
	local self = META:CreateObject()
	self.camera = Camera3D.New()

	if config then
		for k, v in pairs(config) do
			local setter = self["Set" .. k]

			if setter then setter(self, v) else self[k] = v end
		end
	end

	return self
end

function META:InvalidateFramebuffer()
	if self.framebuffer then
		self.framebuffer:Remove()
		self.framebuffer = nil
	end
end

function META:OnRemove()
	self:InvalidateFramebuffer()
	self.camera = nil
	self.entity = nil
end

function META:EnsureFramebuffer()
	if self.framebuffer then return self.framebuffer end

	self.framebuffer = Framebuffer.New{
		width = self:GetWidth(),
		height = self:GetHeight(),
		format = "r8g8b8a8_srgb",
		depth = true,
		clear_color = DEFAULT_CLEAR_COLOR,
	}
	return self.framebuffer
end

function META:GetFramebuffer()
	return self:EnsureFramebuffer()
end

function META:GetTexture()
	return self:EnsureFramebuffer():GetColorTexture()
end

function META:SetTarget(target)
	self.target = target
	self.entity = is_valid_entity(target) and target or nil
	return target
end

function META:SetEntity(entity)
	return self:SetTarget(entity)
end

function META:GetTarget()
	return self.target or self.entity
end

function META:GetEntity()
	return self.entity
end

function META:GetLocalAABB(target)
	local model = get_previewable_model(target)

	if not model then return nil end

	local aabb = model.AABB

	if not aabb or aabb.min_x > aabb.max_x then aabb = model:BuildAABB() end

	return aabb
end

function META:ConfigureCamera(target)
	local model = get_previewable_model(target)

	if not model then
		error("model preview requires an entity with a model component", 2)
	end

	local local_aabb = self:GetLocalAABB(target)
	local world_matrix = model:GetWorldMatrix()

	if not world_matrix then error("model preview requires a world matrix", 2) end

	local target = world_matrix:TransformVector(Vec3(0, 0, 0))
	local forward = (-self:GetViewOffset()):GetNormalized()
	local yaw = math.atan2(-forward.x, -forward.z)
	local pitch = math.asin(math.max(-1, math.min(1, forward.y)))
	local rotation = Quat()
	rotation:Identity()
	rotation:RotateYaw(yaw)
	rotation:RotatePitch(pitch)
	forward = rotation:GetForward()
	local right = rotation:GetRight()
	local up = rotation:GetUp()
	local max_right = 0
	local max_up = 0
	local max_depth = 0
	local aspect = self:GetWidth() / self:GetHeight()

	for _, corner in ipairs(populate_aabb_corners(local_aabb)) do
		local world_pos = world_matrix:TransformVector(corner)
		local offset = world_pos - target
		max_right = math.max(max_right, math.abs(offset:GetDot(right)))
		max_up = math.max(max_up, math.abs(offset:GetDot(up)))
		max_depth = math.max(max_depth, math.abs(offset:GetDot(forward)))
	end

	local half_height = math.max(max_up, max_right / aspect)
	half_height = math.max(half_height * self:GetPadding(), 0.1)
	local distance = math.max(max_depth + half_height * 2, 1)
	local position = target - forward * distance
	self.camera:SetViewport(Rect(0, 0, self:GetWidth(), self:GetHeight()))
	self.camera:SetOrthoMode(true)
	self.camera:SetOrthoHalfHeight(half_height)
	self.camera:SetNearZ(0.01)
	self.camera:SetFarZ(distance + max_depth + half_height * 4)
	self.camera:SetPosition(position)
	self.camera:SetRotation(rotation)
	return self.camera
end

function META:DrawActiveEntity(pipeline)
	local model = get_previewable_model(self:GetTarget())

	if not model then return end

	local world_matrix = model:GetWorldMatrix()

	if not world_matrix then return end

	for _, prim in ipairs(model.Primitives) do
		local polygon = prim.polygon3d

		if polygon then
			local final_matrix = world_matrix
			local material = model.MaterialOverride or prim.material or render3d.GetDefaultMaterial()

			if prim.local_matrix then
				final_matrix = prim.local_matrix:GetMultiplied(world_matrix, cached_final_matrix)
			end

			render3d.SetWorldMatrix(final_matrix)
			render3d.SetMaterial(material)
			upload_preview_constants(pipeline)
			polygon:Draw()
		end
	end
end

function META:RenderTarget(target)
	target = self:SetTarget(target)

	if not get_previewable_model(target) then
		error("model preview requires a drawable model target", 2)
	end

	self:EnsureFramebuffer()
	self:ConfigureCamera(target)
	local pipeline = get_preview_pipeline()
	local cmd = self.framebuffer:GetCommandBuffer()
	local previous_world = render3d.GetWorldMatrix()
	local previous_material = render3d.GetMaterial()
	local pushed_camera = false
	active_preview = self
	pipeline:SetSamplerConfig(render.GetSamplerFilterConfig())
	local ok, err = xpcall(
		function()
			render3d.PushCamera(self.camera)
			pushed_camera = true
			pipeline:Draw(cmd, self.framebuffer)
		end,
		debug.traceback
	)

	if pushed_camera then render3d.PopCamera() end

	render3d.SetWorldMatrix(previous_world)
	render3d.SetMaterial(previous_material)
	active_preview = nil

	if not ok then error(err, 0) end

	return self:GetTexture()
end

function META:RenderEntity(entity)
	return self:RenderTarget(entity)
end

function META:Refresh()
	local target = self:GetTarget()

	if not target then return self:GetTexture() end

	return self:RenderTarget(target)
end

META:Register()
return META
