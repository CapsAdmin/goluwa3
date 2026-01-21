local prototype = require("prototype")
local render = require("render.render")
local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Texture = require("render.texture")
local Fence = require("render.vulkan.internal.fence")
local META = prototype.CreateTemplate("render_texture_atlas")
META:GetSet("Padding", 1)
META:GetSet("MipMapLevels", 1)

function META.New(page_width, page_height, filtering, format)
	page_height = page_height or page_width
	return META:CreateObject(
		{
			dirty_textures = {},
			pages = {},
			textures = {},
			width = page_width,
			height = page_height,
			filtering = filtering,
			format = format or "r8g8b8a8_unorm",
		}
	)
end

local function insert_rect(node, w, h)
	if node.left and node.right then
		return insert_rect(node.left, w, h) or insert_rect(node.right, w, h)
	elseif not node.used and (node.w >= w and node.h >= h) then
		if w == node.w and h == node.h then
			node.used = true
			return node
		end

		if node.w - w > node.h - h then
			node.left = {x = node.x, y = node.y, w = w, h = node.h}
			node.right = {
				x = node.x + w,
				y = node.y,
				w = node.w - w,
				h = node.h,
			}
		else
			node.left = {x = node.x, y = node.y, w = node.w, h = h}
			node.right = {x = node.x, y = node.y + h, w = node.w, h = node.h - h}
		end

		return insert_rect(node.left, w, h)
	end
end

function META:FindFreePage(w, h)
	w = w + self.Padding
	h = h + self.Padding

	for _, page in ipairs(self.pages) do
		local found = insert_rect(page.tree, w, h)

		if found then return page, found end
	end

	local tree = {x = 0, y = 0, w = self.width, h = self.height}
	local node = insert_rect(tree, w, h)

	if node then
		local size = Vec2(self.width, self.height) + self.Padding
		local page = {
			texture = Texture.New(
				{
					width = size.x,
					height = size.y,
					format = self.format,
					mip_map_levels = self.MipMapLevels,
					sampler = {
						min_filter = self.filtering,
						mag_filter = self.filtering,
					},
				}
			),
			textures = {},
			tree = tree,
		}
		list.insert(self.pages, page)
		return page, node
	end
end

local function sort(a, b)
	return (a.w + a.h) > (b.w + b.h)
end

function META:Build()
	list.sort(self.dirty_textures, sort)

	for _, data in ipairs(self.dirty_textures) do
		local page, node = self:FindFreePage(data.w, data.h)

		if not page then error("texture " .. tostring(data) .. " is too big", 2) end

		local x, y, w, h = node.x, node.y, node.w, node.h
		data.page_x = x
		data.page_y = y
		data.page_w = data.w
		data.page_h = data.h
		data.page = page
		data.page_uv = {
			x,
			y,
			data.w,
			data.h,
			page.texture:GetWidth(),
			page.texture:GetHeight(),
		}
		page.textures[data] = data
		page.dirty = true
	end

	self.dirty_textures = {}
	local cmd_pool = render.GetCommandPool()
	local cmd = cmd_pool:AllocateCommandBuffer()
	cmd:Begin()
	local transitioned_textures = {}

	for _, page in ipairs(self.pages) do
		if page.dirty then
			-- Transition page texture to transfer_dst
			cmd:PipelineBarrier(
				{
					srcStage = "all_commands",
					dstStage = "transfer",
					imageBarriers = {
						{
							image = page.texture:GetImage(),
							oldLayout = page.texture:GetImage().layout or "shader_read_only_optimal",
							newLayout = "transfer_dst_optimal",
							srcAccessMask = "none",
							dstAccessMask = "transfer_write",
						},
					},
				}
			)

			for _, data in pairs(page.textures) do
				if not data.uploaded then
					if data.buffer then

					-- For now, buffer uploads still use staging and its own cmd submission
					-- unless we want to integrate it here. Let's stick to CopyFrom for performance.
					-- Wait, buffer is probably slower.
					elseif data.texture then
						local other = data.texture
						-- Transition src to transfer_src
						cmd:PipelineBarrier(
							{
								srcStage = "all_commands",
								dstStage = "transfer",
								imageBarriers = {
									{
										image = other:GetImage(),
										oldLayout = other:GetImage().layout or "shader_read_only_optimal",
										newLayout = "transfer_src_optimal",
										srcAccessMask = "memory_read",
										dstAccessMask = "transfer_read",
									},
								},
							}
						)
						cmd:CopyImageToImage(
							other:GetImage(),
							page.texture:GetImage(),
							data.w,
							data.h,
							0,
							0,
							data.page_x,
							data.page_y
						)
						-- Transition src back later or now? Let's do it now to be safe.
						cmd:PipelineBarrier(
							{
								srcStage = "transfer",
								dstStage = "all_commands",
								imageBarriers = {
									{
										image = other:GetImage(),
										oldLayout = "transfer_src_optimal",
										newLayout = "shader_read_only_optimal",
										srcAccessMask = "transfer_read",
										dstAccessMask = "memory_read",
									},
								},
							}
						)
						data.uploaded = true
					end
				end
			end

			-- Transition page texture back to shader_read
			if page.texture:GetMipMapLevels() > 1 then
				page.texture:GenerateMipmaps("transfer_dst_optimal", cmd)
			else
				cmd:PipelineBarrier(
					{
						srcStage = "transfer",
						dstStage = "all_commands",
						imageBarriers = {
							{
								image = page.texture:GetImage(),
								oldLayout = "transfer_dst_optimal",
								newLayout = "shader_read_only_optimal",
								srcAccessMask = "transfer_write",
								dstAccessMask = "memory_read",
							},
						},
					}
				)
			end

			page.dirty = false
		end
	end

	cmd:End()
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
	self.dirty_textures = {}
end

function META:GetTextures()
	local out = {}

	for _, v in ipairs(self.pages) do
		list.insert(out, v.texture)
	end

	return out
end

function META:DebugDraw()
	local x, y = 0, 0

	for _, page in ipairs(self.pages) do
		render2d.SetColor(1, 0, 0, 1)
		render2d.SetTexture(nil)
		render2d.DrawRect(x, y, page.texture:GetSize().x, page.texture:GetSize().y)
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(page.texture)
		render2d.DrawRect(x, y, page.texture:GetSize().x, page.texture:GetSize().y)

		if x + page.texture:GetSize().x * 2 > render.GetRenderImageSize().x then
			x = 0
			y = y + page.texture:GetSize().y
		else
			x = x + page.texture:GetSize().x
		end
	end
end

function META:Insert(id, data)
	if id then self.textures[id] = data end

	list.insert(self.dirty_textures, data)
end

function META:Draw(id, x, y, w, h)
	local data = self.textures[id]

	if data then
		w = w or data.page_w
		h = h or data.page_h
		render2d.SetTexture(data.page.texture)
		render2d.SetUV(unpack(data.page_uv))
		render2d.DrawRect(x, y, w, h)
		render2d.SetUV()
	end
end

function META:GetUV(id)
	local data = self.textures[id]

	if data then return unpack(data.page_uv) end
end

function META:GetPageTexture(id)
	local data = self.textures[id]

	if data then return data.page.texture end
end

return META:Register()
