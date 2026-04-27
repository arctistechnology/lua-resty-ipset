local ipset = require "resty.ipset"

local _M = {
    _VERSION = "1.0.0",
}
local instance = nil
local init_err = nil

function _M.init()
    if instance then return instance end

    local bl, err = ipset.new("banlist", {
        default_timeout = 3600,
    })

    if not bl then
        init_err = err
        return nil, err
    end

    instance = bl
    return instance
end

function _M.get()
    if instance then return instance end
    if init_err then return nil, init_err end
    return nil, "banlist not initialized"
end

return _M