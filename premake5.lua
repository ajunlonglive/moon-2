workspace "Server"
    configurations { "Debug", "Release" }
    flags{"NoPCH","RelativeLinks"}
    cppdialect "C++17"
    location "./"
    architecture "x64"
    staticruntime "on"

    filter "configurations:Debug"
        defines { "DEBUG" }
        symbols "On"

    filter "configurations:Release"
        defines { "NDEBUG" }
        optimize "On"
        --symbols "On" --带上调试信息

    filter {"system:windows"}
        characterset "MBCS"
        systemversion "latest"
        warnings "Extra"

    filter { "system:linux" }
        warnings "High"

    filter { "system:macosx" }
        warnings "High"

project "lua"
    location "build/projects/%{prj.name}"
    objdir "build/obj/%{prj.name}/%{cfg.buildcfg}"
    targetdir "build/bin/%{cfg.buildcfg}"
    kind "StaticLib"
    language "C"
    includedirs {"./third/lua"}
    files { "./third/lua/**.h", "./third/lua/**.c"}
    removefiles("./third/lua/luac.c")
    removefiles("./third/lua/lua.c")
    filter { "system:windows" }
        disablewarnings { "4244","4324","4702","4310", "4701"}
        -- defines {"LUA_BUILD_AS_DLL"}
    filter { "system:linux" }
        defines {"LUA_USE_LINUX"}
        -- links{"dl"}
    filter { "system:macosx" }
        defines {"LUA_USE_MACOSX"}
        -- links{"dl"}
    -- filter{"configurations:*"}
    --     postbuildcommands{"{COPY} %{cfg.buildtarget.abspath} %{wks.location}"}

project "moon"
    location "build/projects/%{prj.name}"
    objdir "build/obj/%{prj.name}/%{cfg.buildcfg}"
    targetdir "build/bin/%{cfg.buildcfg}"

    kind "ConsoleApp"
    language "C++"
    includedirs {"./","./moon-src","./moon-src/core","./third","./third/lua","./third/mimalloc/include"}
    files {"./moon-src/**.h", "./moon-src/**.hpp","./moon-src/**.cpp" }
    links{
        "lua",
        "lualib",
        "crypt",
        "pb",
        "sharetable",
        "clonefunc",
        "mongo",
        -- "mimalloc",
    }
    defines {
        "ASIO_STANDALONE" ,
        "ASIO_NO_DEPRECATED",
        --"MOON_ENABLE_MIMALLOC"
    }

    filter { "system:windows" }
        defines {"_WIN32_WINNT=0x0601"}
        linkoptions { '/STACK:"8388608"' }
    filter {"system:linux"}
        links{"dl","pthread","stdc++fs"}
        linkoptions {"-static-libstdc++ -static-libgcc", "-Wl,-rpath=./","-Wl,--as-needed"}
    filter {"system:macosx"}
        links{"dl","pthread"}
        linkoptions {"-Wl,-rpath,./"}
    filter "configurations:Debug"
        targetsuffix "-d"
    filter{"configurations:*"}
        postbuildcommands{"{COPY} %{cfg.buildtarget.abspath} %{wks.location}"}


--[[
    lua C/C++模块
    @dir： 模块源文件所在路径，相对于当前目录的路径
    @name: LUAMOD name
    @normaladdon : 平台通用的附加项
    @winddowsaddon : windows下的附加项
    @linuxaddon : linux下的附加项
    @macaddon : macosx下的附加项

    使用：
    模块编写规范：使用 LUAMOD_API 导出符号(windows)

    注意：
    默认使用C编译器编译，可以使用 *addon 参数进行更改
]]
local function add_lua_module(dir, name, normaladdon, windowsaddon, linuxaddon, macaddon )
    project(name)
        location("build/projects/%{prj.name}")
        objdir "build/obj/%{prj.name}/%{cfg.buildcfg}"--编译生成的中间文件目录
        targetdir "build/bin/%{cfg.buildcfg}"--目标文件目录

        kind "StaticLib" -- 静态库 StaticLib， 动态库 SharedLib
        includedirs {"./", "./third","./third/lua"} --头文件搜索目录
        files { dir.."/**.h",dir.."/**.hpp", dir.."/**.c",dir.."/**.cpp"} --需要编译的文件， **.c 递归搜索匹配的文件
        --targetprefix "" -- linux 下需要去掉动态库 'lib' 前缀
        language "C"
        defines{"SOL_ALL_SAFETIES_ON"}

        if type(normaladdon)=="function" then
            normaladdon()
        end
        filter { "system:windows" }
            --links{"lua"} -- windows 版需要链接 lua 库
            --defines {"LUA_BUILD_AS_DLL","LUA_LIB"} -- windows下动态库导出宏定义
            if type(windowsaddon)=="function" then
                windowsaddon()
            end
        filter {"system:linux"}
            if type(linuxaddon)=="function" then
                linuxaddon()
            end
        filter {"system:macosx"}
            -- links{"lua"}
            if type(macaddon)=="function" then
                macaddon()
            end
        --filter{"configurations:*"}
            --postbuildcommands{"{COPY} %{cfg.buildtarget.abspath} %{wks.location}/clib"}
end

----------------------Lua C/C++ Modules------------------------

add_lua_module("./third/sharetable", "sharetable")
add_lua_module("./third/clonefunc", "clonefunc")--for hotfix
add_lua_module("./third/lcrypt", "crypt")
add_lua_module("./third/pb", "pb")--protobuf
add_lua_module("./third/lmongo", "mongo")

add_lua_module("./lualib-src", "lualib", function()
    language "C++"
    includedirs {"./moon-src", "./moon-src/core"}
    defines {"_WIN32_WINNT=0x0601"}

    ---json
    defines{ "YYJSON_DISABLE_WRITER" }
    files { "./third/yyjson/**.h", "./third/yyjson/**.c"}

    ---kcp
    files { "./third/kcp/**.h", "./third/kcp/**.c"}

    ---navmesh begin
    includedirs {
        "./third/recastnavigation/Detour/Include",
        "./third/recastnavigation/DetourCrowd/Include",
        "./third/recastnavigation/DetourTileCache/Include",
        "./third/recastnavigation/Recast/Include"
    }

    files {
        "./third/recastnavigation/Detour/**.h",
        "./third/recastnavigation/Detour/**.cpp",
        "./third/recastnavigation/DetourCrowd/**.h",
        "./third/recastnavigation/DetourCrowd/**.cpp",
        "./third/recastnavigation/DetourTileCache/**.h",
        "./third/recastnavigation/DetourTileCache/**.cpp",
        "./third/recastnavigation/Recast/**.h",
        "./third/recastnavigation/Recast/**.cpp",
        "./third/fastlz/**.h",
        "./third/fastlz/**.c"
    }
    ---navmesh end
end)
