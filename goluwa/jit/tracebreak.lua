if os.getenv("LUAJIT_NO_TRACEBREAK") == "true" then return function() end end

return coroutine.running
