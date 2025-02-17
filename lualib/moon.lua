require("base.io")
require("base.os")
require("base.string")
require("base.table")
require("base.math")
require("base.util")
require("base.class")

local core = require("mooncore")
local seri = require("seri")

local pairs = pairs
local type = type
local error = error
local tremove = table.remove
local traceback = debug.traceback

local co_create = coroutine.create
local co_running = coroutine.running
local co_yield = coroutine.yield
local co_resume = coroutine.resume
local co_close = coroutine.close

local _send = core.send
local _now = core.now
local _addr = core.id
local _timeout = core.timeout
local _newservice = core.new_service
local _queryservice = core.queryservice
local _decode = core.decode
local _scan_services = core.scan_services

---@class moon : core
local moon = core

moon.PTYPE_SYSTEM = 1
moon.PTYPE_TEXT = 2
moon.PTYPE_LUA = 3
moon.PTYPE_ERROR = 4
moon.PTYPE_DEBUG = 5
moon.PTYPE_SHUTDOWN = 6
moon.PTYPE_TIMER = 7
moon.PTYPE_SOCKET_TCP = 8
moon.PTYPE_SOCKET_UDP = 9
moon.PTYPE_SOCKET_WS = 10
moon.PTYPE_SOCKET_MOON = 11

--moon.codecache = require("codecache")

-- LOG_ERROR = 1
-- LOG_WARN = 2
-- LOG_INFO = 3
-- LOG_DEBUG = 4
moon.DEBUG = function()
    return core.loglevel() == 4 -- LOG_DEBUG
end
moon.error = function(...) core.log(1, ...) end
moon.warn = function(...) core.log(2, ...) end
moon.info = function(...) core.log(3, ...) end
moon.debug = function(...) core.log(4, ...) end

moon.pack = seri.pack
moon.unpack = seri.unpack

--export global variable
local _g = _G

---rewrite lua print
_g["print"] = moon.info


moon.exports = {}
setmetatable(
    moon.exports,
    {
        __newindex = function(_, name, value)
            rawset(_g, name, value)
        end,
        __index = function(_, name)
            return rawget(_g, name)
        end
    }
)

-- disable create unexpected global variable
setmetatable(
    _g,
    {
        __newindex = function(_, name, value)
            if name:sub(1, 4) ~= 'sol.' then --ignore sol2 registed library
                local msg = string.format('USE "moon.exports.%s = <value>" INSTEAD OF SET GLOBAL VARIABLE', name)
                moon.error(traceback(msg, 2))
            else
                rawset(_g, name, value)
            end
        end
    }
)

local uuid = 0
local session_id_coroutine = {}
local protocol = {}
local session_watcher = {}
local timer_routine = {}

local function coresume(co, ...)
    local ok, err = co_resume(co, ...)
    if not ok then
        err = traceback(co, tostring(err))
        co_close(co)
        error(err)
    end
    return ok, err
end

--- map current running coroutine with a integer sesssion id, used to resume it later.
---@param receiver? integer @ receiver's service id
---@return integer @ session id
function moon.make_session(receiver)
    uuid = uuid + 1
    if uuid == 0x7FFFFFFF then
        uuid = 1
    end

    if nil ~= session_id_coroutine[uuid] then
        error("sessionid is used!")
    end

    if receiver then
        session_watcher[uuid] = receiver
    end

    session_id_coroutine[uuid] = co_running()
    return uuid
end

local make_session = moon.make_session

--- Cancel wait session response
function moon.cancel_session(sessionid)
    session_id_coroutine[sessionid] = false
end

---
---向指定服务发送消息,消息内容会根据协议类型进行打包
---@param PTYPE string @protocol type. e. "lua"
---@param receiver integer @receiver's service id
function moon.send(PTYPE, receiver, ...)
    local p = protocol[PTYPE]
    if not p then
        error(string.format("moon send unknown PTYPE[%s] message", PTYPE))
    end
    _send(receiver, p.pack(...), "", 0, p.PTYPE)
end

---向指定服务发送消息，消息内容不进行协议打包
---@param PTYPE string @协议类型
---@param receiver integer @接收者服务id
---@param header string @Message Header
---@param data? string|buffer_ptr|integer @消息内容
---@param sessionid? integer
function moon.raw_send(PTYPE, receiver, header, data, sessionid)
    local p = protocol[PTYPE]
    if not p then
        error(string.format("moon send unknown PTYPE[%s] message", PTYPE))
    end

    header = header or ''
    sessionid = sessionid or 0
    _send(receiver, data, header, sessionid, p.PTYPE)
end

---@async
--- Create a service
---@param stype string @service type, options 'lua'
---@param config table @service's config in key-value format
--- - name: string. service's name.
--- - file: string. service's bootstrap file(lua script).
--- - unique: boolean. Identifies whether the service is unique. Unique service can use moon.queryservice(name) get service's id.
--- - threadid: integer. Create service in the specified worker thread。Default 0, add to the thread with least number of services。
---@return integer @ return service's id, if values is 0, means create service failed
function moon.new_service(stype, config)
    local sessionid = make_session()
    _newservice(stype, sessionid, config)
    return math.tointeger(co_yield())
end

---kill self
function moon.quit()
    local running = co_running()
    for k, co in pairs(session_id_coroutine) do
        if type(co) == "thread" and co ~= running then
            co_close(co)
            session_id_coroutine[k] = false
        end
    end

    for k, co in pairs(timer_routine) do
        if type(co) == "thread" and co ~= running then
            co_close(co)
            timer_routine[k] = false
        end
    end

    moon.kill(_addr)
end

---根据服务name获取服务id,注意只能查询创建时配置unique=true的服务
---@param name string
---@return integer @ 0 表示服务不存在
function moon.queryservice(name)
    if type(name) == 'string' then
        return _queryservice(name)
    end
    return name
end

function moon.env_packed(name, ...)
    return core.env(name, seri.packs(...))
end

function moon.env_unpacked(name)
    return seri.unpack(core.env(name))
end

--- Get server timestamp in seconds
--- @return integer
function moon.time()
    return _now(1000)
end

--- Return command line arguments.
--- e. `moon main.lua arg1 arg2 arg3` return `{arg1, arg2, arg3}`
---@return string[]
function moon.args()
    return load(moon.env("ARG"))()
end

-------------------------协程操作封装--------------------------

local co_num = 0

local co_pool = setmetatable({}, { __mode = "kv" })

local function invoke(co, fn, ...)
    co_num = co_num + 1
    fn(...)
    co_num = co_num - 1
    co_pool[#co_pool + 1] = co
end

local function routine(fn, ...)
    local co = co_running()
    invoke(co, fn, ...)
    while true do
        invoke(co, co_yield())
    end
end

---Creates a new coroutine(from coroutine pool) and start it immediately.
---If `func` lacks call `coroutine.yield`, will run syncronously.
---@param fn fun(...)
---@return thread
function moon.async(fn, ...)
    local co = tremove(co_pool) or co_create(routine)
    coresume(co, fn, ...)
    return co
end

function moon.wakeup(co, ...)
    local args = { ... }
    moon.timeout(0, function()
        local ok, err = co_resume(co, table.unpack(args))
        if not ok then
            err = traceback(co, tostring(err))
            co_close(co)
            moon.error(err)
        end
    end)
end

---return count of running coroutine and total coroutine in coroutine pool
function moon.coroutine_num()
    return co_num, #co_pool
end

------------------------------------------

---@return string
function moon.scan_services(workerid)
    local sessionid = make_session()
    _scan_services(workerid, sessionid)
    return co_yield()
end

---@async
--- Send message to target service (id=receiver), and use `coroutine.yield()` wait response
---  - If success, return values are params of `moon.response(id,response, params...)`
---  - If failed, return `false` and `error message(string)`
---@param PTYPE string @protocol type
---@param receiver integer @receiver service's id
---@return ...
---@nodiscard
function moon.co_call(PTYPE, receiver, ...)
    local p = protocol[PTYPE]
    if not p then
        error(string.format("moon call unknown PTYPE[%s] message", PTYPE))
    end

    if receiver == 0 then
        error("moon co_call receiver == 0")
    end

    local sessionid = make_session(receiver)
    _send(receiver, p.pack(...), "", sessionid, p.PTYPE)
    return co_yield()
end

--- Response message to the sender of `moon.co_call`
---@param PTYPE string @protocol type
---@param receiver integer @receiver service's id
---@param sessionid integer
function moon.response(PTYPE, receiver, sessionid, ...)
    if sessionid == 0 then return end
    local p = protocol[PTYPE]
    if not p then
        error("handle unknown message")
    end

    if receiver == 0 then
        error("moon response receiver == 0")
    end

    _send(receiver, p.pack(...), '', sessionid, p.PTYPE)
end

------------------------------------
---@param msg message_ptr
---@param PTYPE string
local function _default_dispatch(msg, PTYPE)
    local p = protocol[PTYPE]
    if not p then
        error(string.format("handle unknown PTYPE: %s. sender %u", PTYPE, _decode(msg, "S")))
    end

    local sender, session, sz, len = _decode(msg, "SEC")
    if session > 0 and PTYPE ~= moon.PTYPE_ERROR then
        session_watcher[session] = nil
        local co = session_id_coroutine[session]
        if co then
            session_id_coroutine[session] = nil
            --print(coroutine.status(co))
            if p.unpack then
                coresume(co, p.unpack(sz, len))
            else
                coresume(co, msg)
            end
            --print(coroutine.status(co))
            return
        end

        if co ~= false then
            error(string.format("%s: response [%u] can not find co.", moon.name, session))
        end
    else
        local dispatch = p.dispatch
        if not dispatch then
            error(string.format("[%s] dispatch PTYPE [%u] is nil", moon.name, p.PTYPE))
            return
        end

        if not p.israw then
            local co = tremove(co_pool) or co_create(routine)
            assert(p.unpack, tostring(p.PTYPE))
            coresume(co, dispatch, sender, session, p.unpack(sz, len))
        else
            dispatch(msg)
        end
    end
end

core.callback(_default_dispatch)

function moon.register_protocol(t)
    local PTYPE = t.PTYPE
    if protocol[PTYPE] then
        print("Warning attemp register duplicated PTYPE", t.name)
    end
    protocol[PTYPE] = t
    protocol[t.name] = t
end

local reg_protocol = moon.register_protocol

---@param PTYPE string
---@param fn fun(sender:integer, session:integer, ...)
function moon.dispatch(PTYPE, fn)
    local p = protocol[PTYPE]
    if fn then
        p.dispatch = fn
    end
end

---@param PTYPE string
---@param fn fun(m:message_ptr)
function moon.raw_dispatch(PTYPE, fn)
    local p = protocol[PTYPE]
    if fn then
        p.dispatch = fn
        p.israw = true
    end
end

reg_protocol {
    name = "lua",
    PTYPE = moon.PTYPE_LUA,
    pack = moon.pack,
    unpack = moon.unpack,
    dispatch = function()
        error("PTYPE_LUA dispatch not implemented")
    end
}

reg_protocol {
    name = "text",
    PTYPE = moon.PTYPE_TEXT,
    pack = function(...)
        return ...
    end,
    unpack = moon.tostring,
    dispatch = function()
        error("PTYPE_TEXT dispatch not implemented")
    end
}

reg_protocol {
    name = "error",
    PTYPE = moon.PTYPE_ERROR,
    israw = true,
    pack = function(...)
        return ...
    end,
    dispatch = function(msg)
        local sessionid, content, data = _decode(msg, "EHZ")
        if data and #data > 0 then
            content = content .. ":" .. data
        end
        local co = session_id_coroutine[sessionid]
        if co then
            session_id_coroutine[sessionid] = nil
            coresume(co, false, content)
            return
        end
    end
}

local system_command = {}

system_command._service_exit = function(sender, msg)
    local data = _decode(msg, "Z")
    for k, v in pairs(session_watcher) do
        if v == sender then
            local co = session_id_coroutine[k]
            if co then
                session_id_coroutine[k] = nil
                coresume(co, false, data)
                return
            end
        end
    end
end

moon.system = function(cmd, fn)
    system_command[cmd] = fn
end

reg_protocol {
    name = "system",
    PTYPE = moon.PTYPE_SYSTEM,
    israw = true,
    pack = function(...)
        return ...
    end,
    dispatch = function(msg)
        local sender, header = _decode(msg, "SH")
        local func = system_command[header]
        if func then
            func(sender, msg)
        end
    end
}

reg_protocol {
    name = "tcp",
    PTYPE = moon.PTYPE_SOCKET_TCP,
    pack = function(...)
        return ...
    end,
    unpack = moon.tostring,
    dispatch = function()
        error("PTYPE_SOCKET_TCP dispatch not implemented")
    end
}

reg_protocol {
    name = "udp",
    PTYPE = moon.PTYPE_SOCKET_UDP,
    pack = function(...) return ... end,
    dispatch = function(_)
        error("PTYPE_SOCKET_UDP dispatch not implemented")
    end
}

reg_protocol {
    name = "websocket",
    PTYPE = moon.PTYPE_SOCKET_WS,
    pack = function(...) return ... end,
    dispatch = function(_)
        error("PTYPE_SOCKET_WS dispatch not implemented")
    end
}

reg_protocol {
    name = "moonsocket",
    PTYPE = moon.PTYPE_SOCKET_MOON,
    pack = function(...) return ... end,
    dispatch = function()
        error("PTYPE_SOCKET_MOON dispatch not implemented")
    end
}

local cb_shutdown

reg_protocol {
    name = "shutdown",
    PTYPE = moon.PTYPE_SHUTDOWN,
    israw = true,
    dispatch = function()
        if cb_shutdown then
            cb_shutdown()
        else
            local name = moon.name
            --- bootstrap or not unique service
            if name == "bootstrap" or 0 == moon.queryservice(moon.name) then
                moon.quit()
            end
        end
    end
}

---注册进程退出信号回掉,注册此回掉后, 除非调用moon.quit, 否则服务不会退出。
---在回掉函数中可以处理异步逻辑（如带协程的数据库访问操作，收到退出信号后，保存数据）。
---注意：处理完成后必须要调用moon.quit,使服务自身退出,否则server进程将无法正常退出。
---@param callback fun()
function moon.shutdown(callback)
    cb_shutdown = callback
end

--------------------------timer-------------

reg_protocol {
    name = "timer",
    PTYPE = moon.PTYPE_TIMER,
    israw = true,
    dispatch = function(msg)
        local timerid = _decode(msg, "S")
        local v = timer_routine[timerid]
        timer_routine[timerid] = nil
        if not v then
            return
        end
        if type(v) == "thread" then
            coresume(v, timerid)
        else
            v()
        end
    end
}

---@param timerid integer @
function moon.remove_timer(timerid)
    timer_routine[timerid] = false
end

function moon.timeout(mills, fn)
    local timer_session = _timeout(mills)
    timer_routine[timer_session] = fn
    return timer_session
end

---异步等待 mills 毫秒
---@async
---@param mills integer
---@return integer
function moon.sleep(mills)
    local timer_session = _timeout(mills)
    timer_routine[timer_session] = co_running()
    return co_yield()
end

--------------------------DEBUG----------------------------

local debug_command = {}

debug_command.gc = function(sender, sessionid)
    collectgarbage("collect")
    moon.response("debug", sender, sessionid, collectgarbage("count"))
end

debug_command.mem = function(sender, sessionid)
    moon.response("debug", sender, sessionid, collectgarbage("count"))
end

debug_command.ping = function(sender, sessionid)
    moon.response("debug", sender, sessionid, "pong")
end

debug_command.state = function(sender, sessionid)
    local running_num, free_num = moon.coroutine_num()
    local s = string.format("co-running %d co-free %d cpu:%d", running_num, free_num, moon.cpu())
    moon.response("debug", sender, sessionid, s)
end

reg_protocol {
    name = "debug",
    PTYPE = moon.PTYPE_DEBUG,
    pack = moon.pack,
    unpack = moon.unpack,
    dispatch = function(sender, session, cmd, ...)
        local func = debug_command[cmd]
        if func then
            func(sender, session, ...)
        else
            moon.response("debug", sender, session, "unknow debug cmd " .. cmd)
        end
    end
}

return moon
