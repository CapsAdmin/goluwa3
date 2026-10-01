local render3d = import("goluwa/render3d/render3d.lua")
local glass_tint = import("goluwa/render3d/glass_tint.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local BINDING_CAMERA = 3
-- The glass drawn from the sun, see glass_tint.lua, into a map for all of it
-- and one for each shadow cascade and the inset. One target holds what the
-- light is left with, the other how far from the sun the glass is. Every face is
-- drawn, so a pane that only has the face away from the sun still counts, and
-- the face nearest the sun wins, so a pane made of two faces is counted once.
local camera_block = {
	name = "glass_tint_camera",
	binding_index = BINDING_CAMERA,
	block = {render3d.camera_block},
	write = glass_tint.WriteCameraBlock,
	upload_scope = "frame",
}
local uniform_buffers = model_pipeline.GetPBRUniformBuffers()
table.insert(uniform_buffers, 1, camera_block)
local COLOR_FORMAT = {
	{"r16g16b16a16_sfloat", {"tint", "rgba"}},
	{"r32_sfloat", {"glass_depth", "r"}},
}
local DEPTH_FORMAT = "d32_sfloat"
local passes = {}

for slot = 0, 5 do
	passes[#passes + 1] = {
		name = glass_tint.SLOT_NAMES[slot],
		ColorFormat = COLOR_FORMAT,
		DepthFormat = DEPTH_FORMAT,
		FramebufferSize = {x = glass_tint.SIZE, y = glass_tint.SIZE},
		ClearColors = {{1, 1, 1, 1}, {1, 1, 1, 1}},
		dont_create_framebuffers = true,
		is_enabled = function()
			if not glass_tint.PrepareSlot(slot) then return false end

			local pipeline = render3d.pipelines[glass_tint.SLOT_NAMES[slot]]

			if not pipeline.framebuffers then pipeline:RecreateFramebuffers() end

			return true
		end,
		on_draw = function(self, cmd)
			cmd:SetViewport(0, 0, glass_tint.SIZE, glass_tint.SIZE, 0, 1)
			cmd:SetScissor(0, 0, glass_tint.SIZE, glass_tint.SIZE)
			glass_tint.SetDrawMatrix(glass_tint.GetSlotMatrix(slot))

			for _, draw in ipairs(glass_tint.GetSlotDraws(slot)) do
				render3d.SetWorldMatrix(draw.world_matrix, draw.prev_world_matrix)
				render3d.SetCurrentPolygon3D(draw.entry.polygon3d)
				render3d.SetMaterial(draw.material)
				render3d.pipelines.glass_tint_surface:UploadConstants()
				cmd:SetCullMode("none")
				draw.entry.polygon3d:Draw()
			end
		end,
		-- never drawn, the pass only begins and clears the targets the glass draws into
		fragment = {shader = "void main() { set_tint(vec4(1.0)); set_glass_depth(1.0); }"},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	}
end

passes[#passes + 1] = {
	name = "glass_tint_surface",
	draw_in_prerender = false,
	dont_create_framebuffers = true,
	ColorFormat = COLOR_FORMAT,
	DepthFormat = DEPTH_FORMAT,
	vertex = model_pipeline.CreateVertexStage{
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		get_projection_view_world_matrix = glass_tint.GetProjectionViewWorldMatrix,
	},
	fragment = {
		push_constants = {
			{
				name = "refraction",
				block = {{"amount", "float"}},
				write = function(self, block)
					block.amount = render3d.GetMaterial():GetRefraction()
					return block
				end,
			},
		},
		uniform_buffers = uniform_buffers,
		shader = model_pipeline.BuildPBRSurfaceGlsl("glass_tint_camera") .. [[
			void main() {
				float alpha = get_alpha();

				if (AlphaTest && alpha < factor_model.AlphaCutoff) discard;

				// what the surface lets through: the refracted share through the
				// albedo, the rest through what the surface leaves uncovered
				float covering = Translucent ? alpha : 1.0;
				vec3 transmitted = refraction.amount * 0.9 * get_albedo() + (1.0 - refraction.amount) * (1.0 - covering);
				set_tint(vec4(clamp(transmitted, vec3(0.0), vec3(1.0)), 1.0));
				set_glass_depth(gl_FragCoord.z);
			}
		]],
	},
	CullMode = "none",
	-- glass nearer the sun than a cascade's near plane is drawn at its depth 0
	DepthClamp = true,
	DepthTest = true,
	DepthWrite = true,
	DepthCompareOp = "less",
}
return passes
