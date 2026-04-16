local render3d = library()
import.loaded["goluwa/render3d/render3d.lua"] = render3d
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local event = import("goluwa/event.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Rect = import("goluwa/structs/rect.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local GetBlueNoiseTexture = import("goluwa/render/textures/blue_noise.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local system = import("goluwa/system.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local lightprobes = import("goluwa/render3d/lightprobes.lua")
local Light = import("goluwa/ecs/components/3d/light.lua")
local prototype = import("goluwa/prototype.lua")

do
	render3d.debug_block = {
		{
			"debug_cascade_colors",
			"int",
			function(self, block, key)
				block[key] = render3d.debug_cascade_colors and 1 or 0
			end,
		},
		{
			"debug_mode",
			"int",
			function(self, block, key)
				block[key] = render3d.debug_mode or 1
			end,
		},
		{
			"near_z",
			"float",
			function(self, block, key)
				block[key] = render3d.camera:GetNearZ()
			end,
		},
		{
			"far_z",
			"float",
			function(self, block, key)
				block[key] = render3d.camera:GetFarZ()
			end,
		},
	}
	local debug_modes = {"none", "normals", "irradiance", "ambient_occlusion", "ssr", "probe"}
	render3d.debug_mode = render3d.debug_mode or 1

	function render3d.SetDebugMode(mode_name)
		for i, name in ipairs(debug_modes) do
			if name == mode_name then
				render3d.debug_mode = i
				return true
			end
		end

		return false
	end

	function render3d.GetDebugModes()
		return debug_modes
	end

	function render3d.CycleDebugMode()
		render3d.debug_mode = render3d.debug_mode % #debug_modes + 1
		return debug_modes[render3d.debug_mode]
	end

	function render3d.GetDebugModeName()
		return debug_modes[render3d.debug_mode]
	end

	render3d.debug_mode_glsl = [[
		int debug_mode = lighting_data.debug_mode - 1;

		if (debug_mode == 1) {
			color = N * 0.5 + 0.5;
		} else if (debug_mode == 2) {
			color = irradiance;
		} else if (debug_mode == 3) {
			color = vec3(ambient_occlusion);
		} else if (debug_mode == 4) {
			color = texture(TEXTURE(lighting_data.ssr_tex), in_uv).rgb;
		} else if (debug_mode == 5) {
			// Probe debug - show probe cubemap contribution
			color = get_reflection(N, 0, V, world_pos);
		}
	]]
end

render3d.camera_block = {
	{
		"inv_view",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildViewMatrix():GetInverse():CopyToFloatPointer(block[key])
		end,
	},
	{
		"inv_projection",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildProjectionMatrix():GetInverse():CopyToFloatPointer(block[key])
		end,
	},
	{
		"view",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildViewMatrix():CopyToFloatPointer(block[key])
		end,
	},
	{
		"projection",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block[key])
		end,
	},
	{
		"camera_position",
		"vec3",
		function(self, block, key)
			render3d.camera:GetPosition():CopyToFloatPointer(block[key])
		end,
	},
}
render3d.common_block = {
	{
		"time",
		"float",
		function(self, block, key)
			block[key] = system.GetElapsedTime()
		end,
	},
}
render3d.gbuffer_block = {
	{
		"albedo_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1))
		end,
	},
	{
		"normal_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(2))
		end,
	},
	{
		"mra_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(3))
		end,
	},
	{
		"emissive_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(4))
		end,
	},
	{
		"depth_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
		end,
	},
}
render3d.last_frame_block = {
	{
		"last_frame_tex",
		"int",
		function(self, block, key)
			if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
				block[key] = -1
				return
			end

			local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
			block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(prev_idx):GetAttachment(1))
		end,
	},
}

function render3d.Initialize()
	render3d.pipelines = {}
	render3d.pipelines_i = {}
	local i = 1
	local pipelines = list.flatten{
		import("goluwa/render3d/passes/gbuffer.lua"),
		import("goluwa/render3d/passes/ssr.lua"),
		import("goluwa/render3d/passes/lighting.lua"),
		--import("goluwa/render3d/passes/smaa.lua"),
		import("goluwa/render3d/passes/blit.lua"),
	}

	for i, config in ipairs(pipelines) do
		render3d.pipelines_i[i] = EasyPipeline.New(config)
		render3d.pipelines_i[i]:SetTextureSamplerConfigResolver(render.GetSamplerFilterConfig)
		render3d.pipelines[config.name] = render3d.pipelines_i[i]
		--
		render3d.pipelines_i[i].name = config.name
		render3d.pipelines_i[i].post_draw = config.post_draw
	end

	local size = render.GetRenderImageSize()
	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))

	event.AddListener("PreRenderPass", "render3d", function()
		if not render3d.pipelines.gbuffer then return end

		for _, pipeline in ipairs(render3d.pipelines_i) do
			if pipeline.name ~= "blit" then pipeline:Draw() end
		end
	end)

	event.AddListener("Draw", "render3d", function(dt)
		render3d.Draw(dt)
	end)

	event.Call("Render3DInitialized")
end

function render3d.ResetState()
	render3d.camera = Camera3D.New()
	render3d.world_matrix = Matrix44()
	render3d.prev_view_matrix = Matrix44()
	render3d.prev_projection_matrix = Matrix44()
	render3d.current_material = render3d.GetDefaultMaterial()
	render3d.environment_texture = nil
	render3d.debug_cascade_colors = false
	render3d.debug_mode = 1
end

function render3d.Draw(dt)
	if not render3d.pipelines.blit then return end

	local cmd = render.GetCommandBuffer()
	-- render to the screen
	render3d.pipelines.blit:Draw(cmd)

	for _, pipeline in ipairs(render3d.pipelines_i) do
		if pipeline.post_draw then pipeline:post_draw(cmd, dt) end
	end

	render3d.prev_view_matrix = render3d.camera:BuildViewMatrix():Copy()
	render3d.prev_projection_matrix = render3d.camera:BuildProjectionMatrix():Copy()
end

function render3d.UploadGBufferConstants()
	if not render3d.pipelines.gbuffer then return end

	local cmd = render.GetCommandBuffer()
	local double_sided = render3d.GetMaterial():GetDoubleSided()
	local cull_mode = double_sided and "none" or orientation.CULL_MODE
	-- GBuffer is already bound during geometry submission, so apply cull mode
	-- directly for the current draw.
	cmd:SetCullMode(cull_mode)
	render3d.pipelines.gbuffer:UploadConstants()
end

do
	render3d.camera = render3d.camera or Camera3D.New()
	render3d.world_matrix = render3d.world_matrix or Matrix44()
	render3d.prev_view_matrix = render3d.prev_view_matrix or Matrix44()
	render3d.prev_projection_matrix = render3d.prev_projection_matrix or Matrix44()

	function render3d.GetCamera()
		return render3d.camera
	end

	function render3d.SetWorldMatrix(world)
		render3d.world_matrix = world
	end

	function render3d.GetWorldMatrix()
		return render3d.world_matrix
	end

	local pvm_cached = Matrix44()

	function render3d.GetProjectionViewWorldMatrix()
		-- ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
		-- Row-major: v * W * V * P
		render3d.world_matrix:GetMultiplied(render3d.camera:BuildViewMatrix(), pvm_cached)
		pvm_cached:GetMultiplied(render3d.camera:BuildProjectionMatrix(), pvm_cached)
		return pvm_cached
	end
end

function render3d.GetLights()
	return Light.Instances
end

-- Debug state for cascade visualization
render3d.debug_cascade_colors = false

function render3d.SetDebugCascadeColors(enabled)
	render3d.debug_cascade_colors = enabled
end

function render3d.GetDebugCascadeColors()
	return render3d.debug_cascade_colors
end

event.AddListener("WindowFramebufferResized", "render3d", function(wnd, size)
	if render.target:IsValid() and render.target.config.offscreen then return end

	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))
end)

function render3d.SetMaterial(mat)
	render3d.current_material = mat
end

function render3d.GetMaterial()
	return render3d.current_material or render3d.GetDefaultMaterial()
end

do
	local default = Material.New()

	function render3d.GetDefaultMaterial()
		return default
	end
end

function render3d.SetEnvironmentTexture(texture)
	render3d.environment_texture = texture
end

function render3d.GetEnvironmentTexture()
	return render3d.environment_texture
end

do -- mesh
	local Mesh = import("goluwa/render/mesh.lua")

	function render3d.CreateMesh(vertices, indices, index_type, index_count)
		return Mesh.New(
			render3d.pipelines.gbuffer:GetVertexAttributes(),
			vertices,
			indices,
			index_type,
			index_count
		)
	end
end

if HOTRELOAD then render3d.Initialize() end

return render3d
