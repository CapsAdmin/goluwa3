local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local test_chart = import("goluwa/render3d/test_chart.lua")
local pvars = import("goluwa/cli/pvars.lua")
import("goluwa/render3d/passes/blit.lua")
local patches = test_chart.GetPatches()

local function linear_to_srgb(c)
	c = math.max(0, math.min(1, c))
	return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
end

local function reference_pass()
	local uvs = {}

	for i, patch in ipairs(patches) do
		uvs[i] = string.format("vec2(%.9f, %.9f)", patch.uv[1], patch.uv[2])
	end

	return {
		name = "test_chart_patches",
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"patch", "rgba"}}},
		FramebufferSize = {x = #patches + 2, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 1, z = 1},
		storage_images = {{binding_index = 0, dst_stage = "compute"}},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_patch;
		]],
		shader = test_chart.GetGLSL() .. [[
			void main() {
				int x = int(gl_GlobalInvocationID.x);
				vec2 uvs[]] .. #patches .. [[] = vec2[]] .. #patches .. [[](]] .. table.concat(uvs, ", ") .. [[);

				if (x < ]] .. #patches .. [[) imageStore(out_patch, ivec2(x, 0), vec4(test_chart(uvs[x]), 1.0));
				if (x == ]] .. #patches .. [[) imageStore(out_patch, ivec2(x, 0), vec4(test_chart(vec2(0.01, 0.01)), 1.0));
				if (x == ]] .. #patches + 1 .. [[) imageStore(out_patch, ivec2(x, 0), vec4(test_chart(vec2(0.0, 0.0)), 1.0));
			}
		]],
	}
end

T.Test("Graphics render3d test chart lists the classic chart, a stops ramp and the hues", function()
	T(#patches)["=="](24 + 15 + 12)
	local by_name = {}

	for _, patch in ipairs(patches) do
		by_name[patch.name] = patch
	end

	T(by_name["grey 0 stops"].linear[1])["~"](0.18, 1e-9)
	T(by_name["grey 6 stops"].linear[1])["~"](0.18 * 64, 1e-9)
	T(by_name["neutral 5"].linear[1])["~"](0.195, 5e-3)
	T(by_name["white"].linear[1])["~"](0.9, 0.02)

	for _, patch in ipairs(patches) do
		T(patch.uv[1] > 0 and patch.uv[1] < 1 and patch.uv[2] > 0 and patch.uv[2] < 1)["=="](true)
	end
end)

T.Test3D("Graphics render3d test chart glsl returns each patch at its centre and the surround elsewhere", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			reference_pass(),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local ok, err = pcall(function()
		draw()
		local downloaded = render3d.pipelines.test_chart_patches:GetFramebuffer(1):GetAttachment(1):Download()

		for i, patch in ipairs(patches) do
			local r, g, b = downloaded:GetPixelFloat(i - 1, 0)
			T(r, patch.name)["~"](patch.linear[1], 1e-6)
			T(g, patch.name)["~"](patch.linear[2], 1e-6)
			T(b, patch.name)["~"](patch.linear[3], 1e-6)
		end

		T(downloaded:GetPixelFloat(#patches, 0))["~"](0.05, 1e-6)
		T(downloaded:GetPixelFloat(#patches + 1, 0))["~"](0.05, 1e-6)
	end)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)

local function read_patch(texels, patch)
	local width, height = texels.width, texels.height
	local x, y = math.floor(patch.uv[1] * width), math.floor(patch.uv[2] * height)
	return {texels:GetPixelFloat(x, y)}
end

T.Test3D("Graphics render3d test chart reaches the display as exact scene values through the blit pass", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local ok, err = pcall(function()
		pvars.SetSession("r_test_chart", true)
		pvars.SetSession("r_grade_lut", "")

		local function shoot(tonemapper)
			pvars.SetSession("r_tonemapper", tonemapper)
			draw()
			draw()
			return render3d.pipelines.blit_compute:GetFramebuffer():GetAttachment(1):Download()
		end

		local by_name = {}

		for _, patch in ipairs(patches) do
			by_name[patch.name] = patch
		end

		local texels = shoot("neutral")

		for _, name in ipairs{
			"dark skin",
			"foliage",
			"orange",
			"neutral 5",
			"black",
			"grey -4 stops",
			"grey 0 stops",
			"grey 2 stops",
		} do
			local patch = by_name[name]
			local shown = read_patch(texels, patch)

			for i = 1, 3 do
				T(linear_to_srgb(shown[i]) * 255, name .. " channel " .. i)["~"](linear_to_srgb(patch.linear[i]) * 255, 2)
			end
		end

		local grey = by_name["grey 0 stops"]

		for tonemapper, code in pairs{slog3 = 420 / 1023, logc = 0.391, cineon = 0.4573196} do
			local shown = read_patch(shoot(tonemapper), grey)

			for i = 1, 3 do
				T(linear_to_srgb(shown[i]), tonemapper .. " grey patch raw log value")["~"](code, 2 / 255)
			end
		end
	end)
	pvars.SetSession("r_test_chart", false)
	pvars.SetSession("r_tonemapper", "neutral")
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)
