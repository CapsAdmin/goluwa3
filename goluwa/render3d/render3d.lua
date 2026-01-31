local ffi = require("ffi")
local render = require("render.render")
local EasyPipeline = require("render.easy_pipeline")
local event = require("event")
local ecs = require("ecs.ecs")
local orientation = require("render3d.orientation")
local Material = require("render3d.material")
local Matrix44 = require("structs.matrix44")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Rect = require("structs.rect")
local Camera3D = require("render3d.camera3d")
local GetBlueNoiseTexture = require("render.textures.blue_noise")
local Light = require("ecs.components.3d.light")
local Framebuffer = require("render.framebuffer")
local system = require("system")
local render3d = library()
package.loaded["render3d.render3d"] = render3d
local atmosphere = require("render3d.atmosphere")
local lightprobes = require("render3d.lightprobes")

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
	local pipelines = list.flatten(
		{
			require("render3d.passes.gbuffer"),
			require("render3d.passes.ssr"),
			require("render3d.passes.lighting"),
			require("render3d.passes.smaa"),
			require("render3d.passes.blit"),
		}
	)

	for i, config in ipairs(pipelines) do
		render3d.pipelines_i[i] = EasyPipeline.New(config)
		render3d.pipelines[config.name] = render3d.pipelines_i[i]
		--
		render3d.pipelines_i[i].name = config.name
		render3d.pipelines_i[i].post_draw = config.post_draw
	end

	local size = render.GetRenderImageSize()
	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))

	event.AddListener("PreRenderPass", "render3d", function(cmd)
		if not render3d.pipelines.gbuffer then return end

		for _, pipeline in ipairs(render3d.pipelines_i) do
			if pipeline.name ~= "blit" then pipeline:Draw(cmd) end
		end
	end)

	event.AddListener("Draw", "render3d", function(cmd, dt)
		render3d.Draw(cmd, dt)
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

function render3d.Draw(cmd, dt)
	if not render3d.pipelines.blit then return end

	-- render to the screen
	render3d.pipelines.blit:Draw(cmd)

	for _, pipeline in ipairs(render3d.pipelines_i) do
		if pipeline.post_draw then pipeline:post_draw(cmd, dt) end
	end

	render3d.prev_view_matrix = render3d.camera:BuildViewMatrix():Copy()
	render3d.prev_projection_matrix = render3d.camera:BuildProjectionMatrix():Copy()
end

function render3d.UploadGBufferConstants(cmd)
	if not render3d.pipelines.gbuffer then return end

	cmd:SetCullMode(render3d.GetMaterial():GetDoubleSided() and "none" or orientation.CULL_MODE)
	render3d.pipelines.gbuffer:UploadConstants(cmd)
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
	return ecs.GetComponents("light") -- TODO, optimize
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
	if render.target and render.target.config.offscreen then return end

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
	local Mesh = require("render.mesh")

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
