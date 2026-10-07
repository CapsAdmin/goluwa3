local objects = import("goluwa/objects/objects.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Rect = import("goluwa/structs/rect.lua")
local META = objects.CreateTemplate("render3d_model_preview")
local DEFAULT_VIEW_OFFSET = Vec3(1, 1, 1):GetNormalized()
local DEFAULT_LIGHT_DIRECTION = Vec3(1, 1, 1):GetNormalized()
local DEFAULT_CLEAR_COLOR = {0, 0, 0, 0}
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
META:GetSet("Width", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Height", 256, {callback = "InvalidateFramebuffer"})
META:GetSet("Padding", 1.1)
META:GetSet("AmbientStrength", 0.3)
META:GetSet("LightStrength", 0.9)
META:GetSet("ViewOffset", DEFAULT_VIEW_OFFSET)
META:GetSet("LightDirection", DEFAULT_LIGHT_DIRECTION)

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
	pipeline:UploadConstants()
	cmd:SetCullMode(material:GetCullMode())
	cmd:SetColorBlendEnable(0, material:GetTranslucent())
	cmd:SetColorBlendEquation(0, material:GetBlendEquation())
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
			tangent = true,
			uv = true,
		},
		fragment = {
			uniform_buffers = {
				{
					name = "preview_data",
					block = {
						{"LightDirectionStrength", "vec4"},
						{"LightingParams", "vec4"},
						{"ViewDirection", "vec4"},
					},
					write = function(self, block)
						local direction = active_preview:GetLightDirection()
						block.LightDirectionStrength[0] = direction.x
						block.LightDirectionStrength[1] = direction.y
						block.LightDirectionStrength[2] = direction.z
						block.LightDirectionStrength[3] = active_preview:GetLightStrength()
						block.LightingParams[0] = active_preview:GetAmbientStrength()
						block.LightingParams[1] = 0
						block.LightingParams[2] = 0
						block.LightingParams[3] = 0
						local view = active_preview:GetViewOffset():GetNormalized()
						block.ViewDirection[0] = view.x
						block.ViewDirection[1] = view.y
						block.ViewDirection[2] = view.z
						block.ViewDirection[3] = 0
						return block
					end,
				},
				{
					name = "model",
					block = model_pipeline.GetSurfaceMaterialBlock(),
					write = model_pipeline.WriteSurfaceMaterialBlock,
				},
			},
			shader = [[
			]] .. model_pipeline.BuildSurfaceSamplingGlsl() .. [[

			void main() {
				vec4 albedo = get_surface_color();

				discard_surface_alpha(albedo);

				vec3 normal = get_surface_normal(in_normal, in_tangent, in_uv);
				vec3 light_dir = normalize(preview_data.LightDirectionStrength.xyz);
				vec3 view_dir = normalize(preview_data.ViewDirection.xyz);
				float metallic = clamp(model.MetallicMultiplier, 0.0, 1.0);
				float roughness = clamp(model.RoughnessMultiplier, 0.05, 1.0);
				float n_dot_l = max(dot(normal, light_dir), 0.0);
				float diffuse = n_dot_l * preview_data.LightDirectionStrength.w;
				float shininess = mix(200.0, 6.0, roughness);
				float highlight = pow(max(dot(normal, normalize(light_dir + view_dir)), 0.0), shininess) * n_dot_l * (1.0 - roughness * 0.75);
				vec3 specular_color = mix(vec3(0.04), albedo.rgb, metallic);
				vec3 lit = albedo.rgb * (preview_data.LightingParams.x + diffuse);
				lit += specular_color * highlight * preview_data.LightDirectionStrength.w;
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
		ColorWriteMask = "rgba",
		on_draw = function(self)
			active_preview:DrawTarget(self)
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
	self.target = nil
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

-- a framebuffer is sampled upside down by render2d, so this draws the upright image
function META:Draw(x, y, w, h)
	render2d.PushTexture(self:GetTexture())
	render2d.PushColorUV(0, 1, 1, 0, 0)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopColorUV()
	render2d.PopTexture()
end

function META:SetTarget(visual)
	self.target = visual
end

function META:GetTarget()
	return self.target
end

function META:GetLocalAABB(visual)
	local aabb = visual.AABB

	if aabb.min_x > aabb.max_x then aabb = visual:BuildAABB() end

	return aabb
end

function META:ConfigureCamera(visual)
	local local_aabb = self:GetLocalAABB(visual)
	local world_matrix = visual:GetWorldMatrix()
	local center = world_matrix:TransformVector(
		Vec3(
			(local_aabb.min_x + local_aabb.max_x) / 2,
			(local_aabb.min_y + local_aabb.max_y) / 2,
			(local_aabb.min_z + local_aabb.max_z) / 2
		)
	)
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
		local offset = world_pos - center
		max_right = math.max(max_right, math.abs(offset:GetDot(right)))
		max_up = math.max(max_up, math.abs(offset:GetDot(up)))
		max_depth = math.max(max_depth, math.abs(offset:GetDot(forward)))
	end

	local half_height = math.max(max_up, max_right / aspect)
	half_height = math.max(half_height * self:GetPadding(), 1e-4)
	local distance = math.max(max_depth + half_height * 2, 1)
	local position = center - forward * distance
	self.camera:SetViewport(Rect(0, 0, self:GetWidth(), self:GetHeight()))
	self.camera:SetOrthoMode(true)
	self.camera:SetOrthoHalfHeight(half_height)
	self.camera:SetNearZ(0.01)
	self.camera:SetFarZ(distance + max_depth + half_height * 4)
	self.camera:SetPosition(position)
	self.camera:SetRotation(rotation)
	return self.camera
end

function META:DrawTarget(pipeline)
	local visual = self.target
	local world_matrix = visual:GetWorldMatrix()

	for _, entry in ipairs(visual:GetRenderEntries()) do
		render3d.SetWorldMatrix(entry.transform and entry.transform:GetWorldMatrix() or world_matrix)
		render3d.SetCurrentPolygon3D(entry.polygon3d)
		render3d.SetMaterial(visual:GetResolvedMaterial(entry))
		upload_preview_constants(pipeline)
		entry.polygon3d:Draw()
	end
end

function META:RenderTarget(visual)
	self:SetTarget(visual)

	if not visual:GetRenderEntries()[1] then
		error("model preview requires a visual with something to draw", 2)
	end

	self:EnsureFramebuffer()
	self:ConfigureCamera(visual)
	local pipeline = get_preview_pipeline()
	local cmd = self.framebuffer:GetCommandBuffer()
	local previous_world = render3d.GetWorldMatrix()
	local previous_material = render3d.GetMaterial()
	local pushed_camera = false
	active_preview = self
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
	render3d.SetCurrentPolygon3D(nil)
	render3d.SetMaterial(previous_material)
	active_preview = nil

	if not ok then error(err, 0) end

	return self:GetTexture()
end

function META:Refresh()
	if not self.target then return self:GetTexture() end

	return self:RenderTarget(self.target)
end

META:Register()
return META
