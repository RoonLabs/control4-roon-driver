-- Moo Bridge
local MooBridge = { } 

function MooBridge:new(core) 
    o = {
        state   = Moo.DISCONNECTED,
        pending = { },
        core    = core,
        nextref = 1,
        state_change_handlers = { }
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function MooBridge:_log(s)
    log("[moobridge] " .. s)
end

function _body_tostring(b)
    if type(b) == "table" then
        return json.encode(b)
    else
        return tostring(b)
    end
end

function MooBridge:request(m, cb)
    --self:_log("SENT ".. m.verb .. " " ..  m.name .. " " .. m.body)
    C4:SendToDevice(self.core.device_id, "ROON_MOO_BRIDGE_REQUEST", {
        SENDER  = C4:GetDeviceID(), 
        REF     = self.nextref,
        MESSAGE = json.encode(m)
    })
    self.pending[tostring(self.nextref)] = cb or (function(m) end)
    self.nextref = self.nextref + 1
end


function MooBridge:dispatch_response(tParams)
    if tParams.SENDER ~= self.core.device_id then return end
    local m = json.decode(tParams.MESSAGE)

    --self:_log("GOT ".. m.verb .. " " ..  m.name .. " " .. m.body)
    local cb = self.pending[tParams.REF]
    if m.verb == Moo.COMPLETE then
        table.remove(self.pending, tParams.REF)
    end
    if cb then
        cb(m)
    else
        log("[moobridge] Warning: unexpected response ref",tParams.REF)
    end
end

function MooBridge:change_state(newstate)
    if self.state ~= newstate then 
        self.state = newstate
        for i,cb in ipairs(self.state_change_handlers) do
            cb(self, newstate)
        end
    end
end

-- cb(moo, newstate)
function MooBridge:on_state_change(cb) 
    table.insert(self.state_change_handlers, cb)
    return self
end

return MooBridge
