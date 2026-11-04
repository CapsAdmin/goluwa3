local event = import("goluwa/event.lua")
local clip_redirect = {}

function clip_redirect.Resolve(kind, sequence, clips, context)
	local redirect = event.Call("RedirectSourceClip", kind, sequence, clips, context)

	if redirect and clips[redirect.Sequence] then
		return redirect.Sequence, redirect
	end

	return sequence
end

return clip_redirect
