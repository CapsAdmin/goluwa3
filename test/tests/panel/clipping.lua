local T = import("test/environment.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")

local function create_test_world()
	local old_world = Panel.World
	local world = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	world:SetName("TestWorld")
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

local function cleanup_test_world(old_world, world)
	if world and world.IsValid and world:IsValid() then world:Remove() end

	Panel.World = old_world
end

T.Test2D("panel gui_element clipping uses semantic clip api", function(width, height)
	local old_world, world = create_test_world()
	local parent = Panel.New{
		Parent = world,
		transform = true,
		gui_element = true,
	}
	parent.transform:SetPosition(Vec2(100, 100))
	parent.transform:SetSize(Vec2(80, 60))
	parent.gui_element:SetClipping(true)

	function parent:OnDraw()
		render2d.DrawRect(0, 0, self.transform.Size.x, self.transform.Size.y)
	end

	local child = Panel.New{
		Parent = parent,
		transform = true,
		gui_element = true,
	}
	child.transform:SetPosition(Vec2(-20, 0))
	child.transform:SetSize(Vec2(120, 60))
	local child_color = Color(1, 0, 0, 1)

	function child:OnDraw()
		render2d.SetColor(child_color:Unpack())
		render2d.DrawRect(0, 0, self.transform.Size.x, self.transform.Size.y)
	end

	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, width, height)
	world.gui_element:DrawRecursive()
	return function()
		local ok, err = xpcall(
			function()
				T.AssertScreenPixel{
					pos = {110, 120},
					color = {1, 0, 0, 1},
					tolerance = 0.1,
				}
				T.AssertScreenPixel{
					pos = {90, 120},
					color = {0, 0, 0, 1},
					tolerance = 0.1,
				}
			end,
			debug.traceback
		)
		cleanup_test_world(old_world, world)

		if not ok then error(err, 0) end
	end
end)

T.Test2D("panel scroll viewport masking uses semantic clip api", function(width, height)
	local old_world, world = create_test_world()
	local viewport = Panel.New{
		Parent = world,
		transform = true,
		gui_element = true,
	}
	viewport.transform:SetPosition(Vec2(200, 200))
	viewport.transform:SetSize(Vec2(80, 60))
	viewport.transform:SetScrollEnabled(true)
	local child = Panel.New{
		Parent = viewport,
		transform = true,
		gui_element = true,
	}
	child.transform:SetPosition(Vec2(-20, 0))
	child.transform:SetSize(Vec2(120, 60))
	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, width, height)
	local masked, clip_x1, clip_y1, clip_x2, clip_y2 = child.transform:BeginScrollViewportMask(0, 0, child.transform.Size.x, child.transform.Size.y)
	render2d.PushMatrix()
	render2d.SetWorldMatrix(child.transform:GetWorldMatrix())
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(0, 0, child.transform.Size.x, child.transform.Size.y)
	render2d.PopMatrix()
	child.transform:EndScrollViewportMask(masked, clip_x1, clip_y1, clip_x2, clip_y2)
	return function()
		local ok, err = xpcall(
			function()
				T(masked)["=="](true)
				T.AssertScreenPixel{
					pos = {210, 220},
					color = {0, 1, 0, 1},
					tolerance = 0.1,
				}
				T.AssertScreenPixel{
					pos = {190, 220},
					color = {0, 0, 0, 1},
					tolerance = 0.1,
				}
			end,
			debug.traceback
		)
		cleanup_test_world(old_world, world)

		if not ok then error(err, 0) end
	end
end)
