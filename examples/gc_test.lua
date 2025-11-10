local setmetatable = require("helpers.setmetatable_gc")
local obj = setmetatable({}, {__gc = function(o)
    print("garbage collected")
end})