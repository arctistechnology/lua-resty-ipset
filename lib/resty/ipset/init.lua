--[[
============================================================================
 lua-resty-ipset
============================================================================
 High-performance Lua/LuaJIT bindings for Linux ipset via libipset FFI.
 Zero subprocess overhead, kernel-level IP filtering for OpenResty/nginx.

 Author      : Zephrise
 Company     : Arctis Technology
 Website     : https://arctis.com
 GitHub      : https://github.com/arctistechnology/lua-resty-ipset
 License     : MIT
 Version     : 1.0.0

 Performance:
   - ban    : ~60,000 ops/sec
   - test   : ~80,000 ops/sec
   - unban  : ~80,000 ops/sec
   - list   : 10,000 entries in <13ms (pure FFI, no subprocess)

 Requirements:
   - LuaJIT (or Lua + ffi module)
   - libipset (libipset.so.13 or compatible)
   - Linux kernel with ip_set module
   - CAP_NET_ADMIN capability for the running process

 IMPORTANT FOR OPENRESTY USERS:
   Do NOT call _M.new() inside init_by_lua. Netlink sockets do not survive
   master->worker fork cleanly. Always create instances inside
   init_worker_by_lua_block, content_by_lua_block, or later phases.
============================================================================
--]]

local ffi = require("ffi")
local ffi_string = ffi.string
local ffi_cast = ffi.cast
local ffi_new = ffi.new
local ffi_copy = ffi.copy
local ffi_gc = ffi.gc
local tbl_concat = table.concat
local str_format = string.format
local str_match = string.match
local str_gsub = string.gsub
local str_find = string.find

ffi.cdef[[
typedef struct ipset ipset_t;
typedef struct ipset_session ipset_session_t;

void ipset_load_types(void);
ipset_t *ipset_init(void);
int ipset_fini(ipset_t *ipset);
int ipset_parse_argv(ipset_t *ipset, int argc, char *argv[]);
ipset_session_t *ipset_session(ipset_t *ipset);
const char *ipset_session_report_msg(const ipset_session_t *session);
void ipset_session_report_reset(ipset_session_t *session);

int ipset_custom_printf(ipset_t *ipset,
    void *custom_error,
    void *standard_error,
    void *outfn,
    void *p);
]]

local lib
do
    local ok, loaded = pcall(ffi.load, "ipset")
    if ok then
        lib = loaded
    else
        local ok2, loaded2 = pcall(ffi.load, "libipset.so.13")
        if not ok2 then
            error("failed to load libipset: " .. tostring(loaded))
        end
        lib = loaded2
    end
end

lib.ipset_load_types()

local output_buffer = {}
local output_count = 0

local function reset_output()
    output_buffer = {}
    output_count = 0
end

local std_error_cb = ffi_cast(
    "int (*)(ipset_t *, void *)",
    function(handle, p) return -1 end
)

local custom_error_cb = ffi_cast(
    "int (*)(ipset_t *, void *, int, const char *)",
    function(handle, p, status, msg) return 0 end
)

local print_out_cb = ffi_cast(
    "int (*)(ipset_session_t *, void *, const char *, const char *)",
    function(session, p, fmt, outbuf)
        if outbuf ~= nil then
            output_count = output_count + 1
            output_buffer[output_count] = ffi_string(outbuf)
        end
        return 0
    end
)

local function log_err(fmt, ...)
    if ngx and ngx.log then
        ngx.log(ngx.ERR, "[ipset] " .. str_format(fmt, ...))
    end
end

local function is_master_process()
    if not ngx or not ngx.config then return false end
    local phase = ngx.get_phase and ngx.get_phase()
    return phase == "init"
end

local function validate_setname(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 31 then return false end
    if not str_match(name, "^[%w_%-]+$") then return false end
    return true
end

local function validate_ip(ip)
    if type(ip) ~= "string" or ip == "" then return false end
    if #ip > 45 then return false end
    if not str_match(ip, "^[%w%.:/]+$") then return false end
    return true
end

local function get_session_error(handle)
    if handle == nil then return nil end
    local sess = lib.ipset_session(handle)
    if sess == nil then return nil end
    local msg = lib.ipset_session_report_msg(sess)
    if msg == nil then return nil end
    return (str_gsub(ffi_string(msg), "%s+$", ""))
end

local function clear_session_error(handle)
    if handle == nil then return end
    local sess = lib.ipset_session(handle)
    if sess ~= nil then
        lib.ipset_session_report_reset(sess)
    end
end

local function build_argv(args)
    local argc = #args + 1
    local argv = ffi_new("char*[?]", argc + 1)
    local refs = ffi_new("char*[?]", argc + 1)

    local prog = ffi_new("char[?]", 6)
    ffi_copy(prog, "ipset")
    refs[0] = prog
    argv[0] = prog

    for i = 1, #args do
        local s = tostring(args[i])
        local buf = ffi_new("char[?]", #s + 1)
        ffi_copy(buf, s)
        refs[i] = buf
        argv[i] = buf
    end

    argv[argc] = nil
    return argv, argc, refs
end

local function exec_cmd(handle, args, capture_output)
    if handle == nil then
        return false, "session closed"
    end

    clear_session_error(handle)

    if capture_output then
        reset_output()
    end

    local argv, argc, refs = build_argv(args)
    local rc = lib.ipset_parse_argv(handle, argc, argv)

    local _ = refs

    if rc ~= 0 then
        local err = get_session_error(handle) or ("rc=" .. tostring(rc))
        if capture_output then reset_output() end
        return false, err
    end

    if capture_output then
        local result = tbl_concat(output_buffer)
        reset_output()
        return true, result
    end

    return true
end

local _M = {
    _VERSION = "1.0.0",
    _AUTHOR  = "Zephrise <https://github.com/zephrise>",
    _LICENSE = "MIT",
    _URL     = "https://github.com/arctistechnology/lua-resty-ipset",
}
local mt = { __index = _M }

function _M.new(setname, opts)
    if is_master_process() then
        return nil, "do not create instances in init_by_lua (master process); use init_worker_by_lua or later phases"
    end

    if not validate_setname(setname) then
        return nil, "invalid setname: " .. tostring(setname)
    end

    opts = opts or {}

    local handle = lib.ipset_init()
    if handle == nil then
        return nil, "ipset_init returned NULL (CAP_NET_ADMIN missing?)"
    end

    local rc = lib.ipset_custom_printf(handle,
        custom_error_cb,
        std_error_cb,
        print_out_cb,
        nil)

    if rc ~= 0 then
        lib.ipset_fini(handle)
        return nil, "ipset_custom_printf failed: rc=" .. tostring(rc)
    end

    local self = setmetatable({
        handle = handle,
        setname = setname,
        ipv6 = opts.ipv6 or false,
        default_timeout = opts.default_timeout or 0,
        closed = false,
    }, mt)

    ffi_gc(handle, lib.ipset_fini)

    if opts.auto_create then
        local ok, err = self:create({
            timeout  = opts.default_timeout,
            maxelem  = opts.maxelem or 1048576,
            hashsize = opts.hashsize or 4096,
        })

        if not ok then
            local exists = err and (str_find(err, "already exists") or str_find(err, "already added"))
            if not exists then
                log_err("auto_create failed: %s", tostring(err))
                self:close()
                return nil, "create failed: " .. tostring(err)
            end
        end
    end

    return self
end

function _M:create(opts)
    opts = opts or {}

    local args = {
        "create", self.setname, "hash:ip",
        "family", self.ipv6 and "inet6" or "inet",
    }

    if opts.timeout and opts.timeout > 0 then
        args[#args + 1] = "timeout"
        args[#args + 1] = tostring(math.floor(opts.timeout))
    end

    if opts.hashsize then
        args[#args + 1] = "hashsize"
        args[#args + 1] = tostring(math.floor(opts.hashsize))
    end

    if opts.maxelem then
        args[#args + 1] = "maxelem"
        args[#args + 1] = tostring(math.floor(opts.maxelem))
    end

    args[#args + 1] = "-exist"

    return exec_cmd(self.handle, args)
end

function _M:destroy()
    return exec_cmd(self.handle, { "destroy", self.setname })
end

function _M:flush()
    return exec_cmd(self.handle, { "flush", self.setname })
end

function _M:ban(ip, timeout)
    if not validate_ip(ip) then
        return false, "invalid ip: " .. tostring(ip)
    end

    local ttl = timeout or self.default_timeout

    local args = { "add", self.setname, ip }
    if ttl and ttl > 0 then
        args[#args + 1] = "timeout"
        args[#args + 1] = tostring(math.floor(ttl))
    end
    args[#args + 1] = "-exist"

    return exec_cmd(self.handle, args)
end

function _M:unban(ip)
    if not validate_ip(ip) then
        return false, "invalid ip: " .. tostring(ip)
    end
    return exec_cmd(self.handle, { "del", self.setname, ip, "-exist" })
end

function _M:is_banned(ip)
    if not validate_ip(ip) then
        return nil, "invalid ip: " .. tostring(ip)
    end

    local ok, err = exec_cmd(self.handle, { "test", self.setname, ip })

    if ok then return true end

    if err and (
        str_find(err, "NOT in set") or
        str_find(err, "not added") or
        str_find(err, "is NOT") or
        str_find(err, "not in set")
    ) then
        return false
    end

    return nil, err
end

function _M:ban_many(ips, timeout)
    local results = { ok = 0, failed = 0, errors = {} }
    if type(ips) ~= "table" then
        return results
    end

    for i = 1, #ips do
        local ok, err = self:ban(ips[i], timeout)
        if ok then
            results.ok = results.ok + 1
        else
            results.failed = results.failed + 1
            if results.failed <= 10 then
                results.errors[ips[i]] = tostring(err)
            end
        end
    end
    return results
end

function _M:unban_many(ips)
    local results = { ok = 0, failed = 0, errors = {} }
    if type(ips) ~= "table" then
        return results
    end

    for i = 1, #ips do
        local ok, err = self:unban(ips[i])
        if ok then
            results.ok = results.ok + 1
        else
            results.failed = results.failed + 1
            if results.failed <= 10 then
                results.errors[ips[i]] = tostring(err)
            end
        end
    end
    return results
end

local function parse_save_line(line)
    local ip, rest = str_match(line, "^add%s+%S+%s+(%S+)%s*(.*)$")
    if not ip then return nil end

    local entry = { ip = ip }

    local timeout = str_match(rest, "timeout%s+(%d+)")
    if timeout then entry.timeout = tonumber(timeout) end

    local packets = str_match(rest, "packets%s+(%d+)")
    if packets then entry.packets = tonumber(packets) end

    local bytes = str_match(rest, "bytes%s+(%d+)")
    if bytes then entry.bytes = tonumber(bytes) end

    return entry
end

function _M:list()
    local ok, output = exec_cmd(self.handle, { "save", self.setname }, true)
    if not ok then
        return nil, output
    end

    local entries = {}
    local n = 0
    local pos = 1
    local len = #output

    while pos <= len do
        local nl = str_find(output, "\n", pos, true)
        local line
        if nl then
            line = output:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = output:sub(pos)
            pos = len + 1
        end

        if #line > 0 then
            local entry = parse_save_line(line)
            if entry then
                n = n + 1
                entries[n] = entry
            end
        end
    end

    return entries
end

function _M:count()
    local entries, err = self:list()
    if not entries then return nil, err end
    return #entries
end

function _M:close()
    if self.closed then return end
    self.closed = true

    if self.handle ~= nil then
        local h = ffi_gc(self.handle, nil)
        self.handle = nil
        if h ~= nil then
            lib.ipset_fini(h)
        end
    end
end

return _M
