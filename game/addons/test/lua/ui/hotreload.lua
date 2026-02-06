for k, v in pairs(package.loaded) do
	if k:find(".ui.", nil, true) then package.loaded[k] = nil end
end

runfile("lua/ui/app.lua")
