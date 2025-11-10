local test = require("test.gambarina")
local threads = require("threads")

test("thread returns incremented value", function()
    local thread = threads.new(function(input) 
        assert(input == 1)
        return input + 1
    end)

    thread:run(1)
    local ret = thread:join()

    ok(eq(ret, 2), "thread should return input + 1")
end)

test("thread handles errors", function()
    local thread = threads.new(function(input) 
        error("Intentional Error")
    end)

    thread:run(1)
    local ret, err = thread:join()
    
    ok(err ~= nil, "should return error")
    ok(err:find("Intentional Error") ~= nil, "error should contain message")
end)
