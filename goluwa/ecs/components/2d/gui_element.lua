local prototype = import("goluwa/prototype.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local UIDebug = import("goluwa/ecs/components/2d/ui_debug.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local META = prototype.CreateTemplate("gui_element")
META:StartStorable()
META:GetSet("Visible", true)
META:GetSet("Clipping", false)
META:GetSet("BorderRadius", 0)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("DrawColor", Color(0, 0, 0, 0))
META:GetSet("DrawAlpha", 1)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("transform")
end

function META:SetColor(c)
	if type(c) == "string" then
		self.Color = Color.FromHex(c)
	else
		self.Color = c
	end
end

function META:SetVisible(visible)
	self.Visible = visible
	self.Owner:CallLocalEvent("OnVisibilityChanged", visible)
end

function META:IsHovered(mouse_pos)
	local transform = self.Owner.transform

	if not transform then return false end

	local local_pos = transform:GlobalToLocal(mouse_pos)
	local clip_x1, clip_y1, clip_x2, clip_y2 = transform:GetVisibleLocalRect(0, 0, transform.Size.x, transform.Size.y)

	if not clip_x1 then return false end

	return local_pos.x >= clip_x1 and
		local_pos.y >= clip_y1 and
		local_pos.x <= clip_x2 and
		local_pos.y <= clip_y2
end

local draw_recursive_elements = {}
local draw_recursive_exit = {}
local draw_recursive_clipping = {}

function META:DrawRecursive()
	local stack_size = 1
	draw_recursive_elements[1] = self
	draw_recursive_exit[1] = false
	draw_recursive_clipping[1] = false

	while stack_size > 0 do
		local current = draw_recursive_elements[stack_size]
		local is_exit = draw_recursive_exit[stack_size]
		local clipping = draw_recursive_clipping[stack_size]
		draw_recursive_elements[stack_size] = nil
		draw_recursive_exit[stack_size] = nil
		draw_recursive_clipping[stack_size] = nil
		stack_size = stack_size - 1

		if is_exit then
			if clipping then render2d.PopClip() end

			UIDebug.OnDebugPostDraw(current.Owner)
			current.Owner:CallLocalEvent("OnPostDraw")
			render2d.PopMatrix()
		else
			if current:GetVisible() then
				local owner = current.Owner
				local transform = owner.transform

				if transform then
					local text_component = owner.text

					if
						(
							text_component and
							text_component.GetDisableViewportCulling and
							text_component:GetDisableViewportCulling()
						) or
						transform:GetVisibleLocalRect(0, 0, transform.Size.x, transform.Size.y)
					then
						local c = current.Color + current.DrawColor

						if c.a > 0 then
							clipping = current:GetClipping()
							local border_radius = current:GetBorderRadius()
							render2d.PushMatrix()
							render2d.SetWorldMatrix(transform:GetWorldMatrix())

							if clipping then
								if border_radius > 0 then
									render2d.PushClipRoundedRect(0, 0, transform.Size.x, transform.Size.y, border_radius)
								else
									render2d.PushClipRect(0, 0, transform.Size.x, transform.Size.y)
								end
							end

							render2d.SetColor(c.r, c.g, c.b, c.a * current.DrawAlpha)
							owner:CallLocalEvent("OnDraw")
							stack_size = stack_size + 1
							draw_recursive_elements[stack_size] = current
							draw_recursive_exit[stack_size] = true
							draw_recursive_clipping[stack_size] = clipping
							local children = owner:GetChildren()

							for i = #children, 1, -1 do
								local child = children[i]

								if child.gui_element then
									stack_size = stack_size + 1
									draw_recursive_elements[stack_size] = child.gui_element
									draw_recursive_exit[stack_size] = false
									draw_recursive_clipping[stack_size] = false
								end
							end
						end
					end
				end
			end
		end
	end
end

function META:OnFirstCreated()
	event.AddListener("Draw2D", "ecs_gui_system", function()
		self.Owner:GetRoot().gui_element:DrawRecursive()
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

return META:Register()
