os.execute("mkdir -p bin")
os.execute("cd bin/ && git clone https://github.com/LuaJIT/LuaJIT.git")
os.execute("cd bin/LuaJIT && git checkout v2.1")
os.execute("cd bin/LuaJIT && export MACOSX_DEPLOYMENT_TARGET=99.99  && make clean && "..
    " make PREFIX=$(pwd)/bin/LuaJIT BUILDVM=1 " ..
    "XCFLAGS='-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_TABLE_BUMP -DLUA_USE_ASSERT -DLUA_USE_APICHECK -O0' " ..
    "CCDEBUG='-g -O0' BUILDMODE=static")
