local T = import("test/environment.lua")
local SceneView = import("goluwa/render3d/scene_view.lua")
local Environment = import("goluwa/render3d/environment.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function create_cube()
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local entity = Entity.New{Name = "scene_view_cube"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "scene_view_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(poly)
	visual_primitive:SetMaterial(
		Material.New{
			ColorMultiplier = Color(1, 0.2, 0.2, 1),
			MetallicMultiplier = 0,
			DoubleSided = true,
		}
	)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	entity.visual:SetVisible(false)
	return entity
end

local function luma(r, g, b)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

T.Test3D("Scene view with AutoRender is drawn by the next frame and only when it changed", function(draw)
	local entity = create_cube()
	local view = SceneView.New{Width = 128, Height = 128, Supersample = 1, AutoRender = true}
	local renders = 0

	function view.OnDrawGeometry()
		renders = renders + 1
		SceneView.DrawVisual(entity.visual)
	end

	local orbit = OrbitCamera.New(view:GetCamera())
	orbit:Fit(Vec3(0, 0, 0), 0.9, 1)
	orbit:Apply()
	local ok, err = xpcall(
		function()
			T(view:HasRendered())["=="](false)
			draw()
			T(view:HasRendered())["=="](true)
			T(renders)["=="](1)
			T.AssertTexturePixel{
				tex = view:GetTexture(),
				pos = {64, 64},
				color = function(r, g, b, a)
					return r > g * 2 and r > b * 2 and a > 0.9
				end,
			}
			draw()
			T(renders)["=="](1)
			view:Invalidate()
			draw()
			T(renders)["=="](2)
			view:SetExposureCompensation(-1)
			draw()
			T(renders)["=="](3)
		end,
		debug.traceback
	)
	view:Remove()
	entity:Remove()

	if not ok then error(err, 0) end
end)

T.Test3D("Scene view without AutoRender is never drawn by a frame", function(draw)
	local view = SceneView.New{Width = 64, Height = 64, Supersample = 1}
	local renders = 0

	function view.OnDrawGeometry()
		renders = renders + 1
	end

	view:Invalidate()
	draw()
	T(renders)["=="](0)
	T(view:HasRendered())["=="](false)
	T(view:RenderNow())["=="](true)
	T(view:HasRendered())["=="](true)
	view:Remove()
end)

T.Test3D("Scene views of one size share their passes, other sizes get their own", function()
	local before = SceneView.GetBundleCount()
	local a = SceneView.New{Width = 72, Height = 72, Supersample = 1}
	local b = SceneView.New{Width = 72, Height = 72, Supersample = 1}
	local c = SceneView.New{Width = 88, Height = 72, Supersample = 1}
	a:RenderNow()
	b:RenderNow()
	T(SceneView.GetBundleCount())["=="](before + 1)
	c:RenderNow()
	T(SceneView.GetBundleCount())["=="](before + 2)
	a:Remove()
	b:Remove()
	c:Remove()
end)

T.Test3D("Scene view background comes from the environment and is transparent otherwise", function()
	local view = SceneView.New{Width = 64, Height = 64, Supersample = 1}
	local ok, err = xpcall(
		function()
			view:RenderNow()
			T.AssertTexturePixel{tex = view:GetTexture(), pos = {8, 8}, color = {0, 0, 0, 0}, tolerance = 0.05}
			view:SetTransparentSky(false)
			view:RenderNow()
			T.AssertTexturePixel{
				tex = view:GetTexture(),
				pos = {8, 8},
				color = function(r, g, b, a)
					return a > 0.9 and luma(r, g, b) > 0.01
				end,
			}
		end,
		debug.traceback
	)
	view:Remove()

	if not ok then error(err, 0) end
end)

T.Test3D("Every environment preset bakes and shows its sky", function()
	local names = Environment.GetPresetNames()
	T(#names >= 2)["=="](true)
	T(names[1])["=="]("Studio")
	T(Environment.GetPreset("Studio") == Environment.GetShared())["=="](true)
	local view = SceneView.New{Width = 64, Height = 64, Supersample = 1, TransparentSky = false}
	local ok, err = xpcall(
		function()
			for _, name in ipairs(names) do
				local environment = Environment.GetPreset(name)
				T(Environment.GetPreset(name) == environment)["=="](true)
				view:SetEnvironment(environment)
				T(view:RenderNow())["=="](true)
				T(environment:IsReady())["=="](true)
				T.AssertTexturePixel{
					tex = view:GetTexture(),
					pos = {32, 32},
					color = function(r, g, b, a)
						return a > 0.9 and luma(r, g, b) > 0.003
					end,
				}
			end
		end,
		debug.traceback
	)
	view:Remove()

	if not ok then error(err, 0) end
end)

T.Test3D("Environment from an atmosphere shader puts the sun where it was asked", function()
	local view = SceneView.New{Width = 64, Height = 64, Supersample = 1, TransparentSky = false}
	local ok, err = xpcall(
		function()
			-- looking along -z and 10 degrees up, azimuth 270 is the sun right in front of the camera
			local orbit = OrbitCamera.New(view:GetCamera())
			orbit.Yaw, orbit.Pitch, orbit.Distance = 0, math.rad(10), 1
			orbit:Apply()

			local function center_pixel(azimuth)
				local environment = Environment.New{
					Shader = import("goluwa/render3d/atmospheres/nishita.lua"),
					SunElevation = 10,
					SunAzimuth = azimuth,
					Intensity = 1,
				}
				view:SetEnvironment(environment)
				view:RenderNow()
				local r, g, b = view:GetTexture():GetPixel(32, 32)
				environment:Remove()
				return r / 255, g / 255, b / 255
			end

			local r, g, b = center_pixel(270)
			T(r > 0.97 and g > 0.97 and b > 0.97)["=="](true)
			r, g, b = center_pixel(90)
			T(r < 0.9 and g < 0.95 and b < 0.95)["=="](true)
		end,
		debug.traceback
	)
	view:Remove()

	if not ok then error(err, 0) end
end)
