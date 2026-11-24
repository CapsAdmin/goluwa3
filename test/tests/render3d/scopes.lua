local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scopes = import("goluwa/render3d/scopes.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local pvars = import("goluwa/cli/pvars.lua")
import("goluwa/render3d/passes/blit.lua")
local SIZE = 8
local LEFT = {0.25, 0.5, 0.75}
local RIGHT = {1, 0, 0.5}
local source_pass = {
	name = "scope_source_test",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"unused", "r"}}},
	FramebufferSize = {x = SIZE, y = SIZE},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_buffers = {{binding_index = 1}},
	block = {scopes.block},
	write = function(self, block)
		return scopes.WriteBlock(block)
	end,
	on_pre_draw = function(self, cmd, frame, desc)
		local buffer = scopes.GetWaveformBuffer(cmd)
		self:UpdateDescriptorSet("storage_buffer", desc, 1, 0, buffer, buffer:GetSize())
	end,
	shader = compute_helpers.GetColorHelpersGLSL() .. scopes.GetGLSL("compute", 1) .. string.format(
			[[
		void main() {
			ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
			scope_waveform(pos.x < %d ? vec3(%s, %s, %s) : vec3(%s, %s, %s), pos, ivec2(%d));
		}
	]],
			SIZE / 2,
			LEFT[1],
			LEFT[2],
			LEFT[3],
			RIGHT[1],
			RIGHT[2],
			RIGHT[3],
			SIZE
		),
}

T.Test3D("Graphics render3d scopes waveform counts each channel by column and level at every size while it is asked for", function(draw)
	render3d.Initialize{
		passes = {import("goluwa/render3d/passes/gbuffer.lua"), source_pass, scopes.resolve_pass},
	}
	local ok, err = pcall(function()
		for _, columns in ipairs{512, 128} do
			pvars.SetSession("r_scope_columns", tostring(columns))
			scopes.RequestWaveform()
			draw()
			T(scopes.IsWaveformActive())["=="](true)
			local image = scopes.GetWaveformTexture():Download()
			local levels = columns / 2

			local function at(column, value)
				return {image:GetPixelFloat(column, math.min(math.floor(value * levels), levels - 1))}
			end

			local left_column, right_column = 0, (SIZE - 1) * columns / SIZE
			T(at(left_column, LEFT[1])[1] > 0)["=="](true)
			T(at(left_column, LEFT[1])[2])["=="](0)
			T(at(left_column, LEFT[2])[2] > 0)["=="](true)
			T(at(left_column, LEFT[3])[3] > 0)["=="](true)
			T(at(right_column, RIGHT[1])[1] > 0)["=="](true)
			T(at(right_column, RIGHT[2])[2] > 0)["=="](true)
			T(at(right_column, RIGHT[3])[3] > 0)["=="](true)
			T(at(right_column, LEFT[1])[1])["=="](0)
			T(at((SIZE / 2 - 1) * columns / SIZE, LEFT[1])[1] > 0)["=="](true)
			T(at(SIZE / 2 * columns / SIZE, RIGHT[1])[1] > 0)["=="](true)
			draw()
			local again = scopes.GetWaveformTexture():Download()
			local y = math.floor(LEFT[1] * levels)
			T(again:GetPixelFloat(left_column, y))["~"](image:GetPixelFloat(left_column, y), 1e-3)
		end
	end)
	pvars.SetSession("r_scope_columns", "512")
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)
