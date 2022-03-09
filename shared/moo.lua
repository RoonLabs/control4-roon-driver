local json  = require("dkjson")

g_reconnect_seq = 0

local Moo = { 
    -- Connection states (moo_instance.state)
    DISCONNECTED = "Disconnected",
    CONNECTED    = "Connected",
    CONNECTING   = "Connecting",

    -- verbs
    REQUEST      = "REQUEST",
    CONTINUE     = "CONTINUE",
    COMPLETE     = "COMPLETE",
}

function Moo:new(host, port)
    o = {
        tcp_client            = nil,
        state                 = Moo.DISCONNECTED,
        host                  = host,
        port                  = port,
        prefix                = "[moo " .. host .. ":" .. tostring(port) .. "] ",
        next_reqid            = 1,
        state_change_handlers = {},
        request_handlers      = {},
        requests              = {},
        pending_writes        = {},
        write_pending         = false
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function Moo:_change_state(newstate)
    if self.state ~= newstate then 
        self:_log("Moo state changed", self.state, newstate)
        self.state = newstate
        if self.state == Moo.DISCONNECTED then
            self.pending_writes = { }
            self.write_pending  = false
        end
        for i,cb in ipairs(self.state_change_handlers) do
            cb(self, newstate)
        end
    end
end

function Moo:_log(s)
    print(self.prefix .. s)
end

function Moo:connect()
    print("Moo:connect()")
    if self.state == Moo.CONNECTING or self.state == Moo.CONNECTED then
	   return
    end

    if self.tcp_client then
        self.tcp_client:Close();
	   self.tcp_client = nil;
    end
    
    function delayed_reconnect(timeout) 
		local reconnect_seq = g_reconnect_seq
		C4:SetTimer(timeout, function()
			if reconnect_seq ~= g_reconnect_seq then return end
			self:reconnect() 
		end);
    end
    
    local PS_HEADERS    = 0
    local PS_HEADERS_NL = 1
    local PS_BODY       = 2
    
    local headerbuf      = "";
    local parsestate 	= PS_HEADERS;
    local body           = "";
    local body_remaining = 0;
    
    function on_message(verb, name, headers, body)
       --self:_log("---[ GOT " .. verb .. " " .. name .. body .. "]----------")

       local message = Moo.message({
           name    = name,
           verb    = verb,
           headers = headers,
           body    = body,
       });

       if message.verb == Moo.REQUEST then
           local cx = { }
           local themoo = self
           function cx:respond(response)
               response.headers["Request-Id"] = message.headers["Request-Id"]
               themoo:_send(response)
           end
           for i,cb in ipairs(self.request_handlers) do
               cb(self, cx, message)
           end
       else
           local rid = headers["Request-Id"]
           if rid == nil then error("message was missing required field Request-Id") end
           local cb = self.requests[rid]
           if cb then
               cb(message)
           else
               self:_log("warning: unhandled rid " .. tostring(rid))
           end
           if message.verb == Moo.COMPLETE then
               table.remove(self.requests, rid)
           end
       end
    end

    local verb
    local name
    local headers
    
    function on_read(data, offset, count)
        while count > 0 do
            if     parsestate == PS_HEADERS    then
                local indexof_nl    = string.find(data, "\n", offset)
                local consume_count
                if indexof_nl ~= nil then
                    consume_count = indexof_nl - offset + 1
                    parsestate = PS_HEADERS_NL
                else
                    consume_count = count
                end
                local b = string.sub(data, offset, offset+consume_count-1)
                offset = offset + consume_count
                count  = count  - consume_count
                headerbuf = headerbuf .. b

            elseif parsestate == PS_HEADERS_NL then
                local b = string.sub(data, offset, offset)
                offset = offset + 1; count  = count  - 1
                if b == "\n" then
                    local lines = headerbuf:split("\n");
                    if #lines < 1 then error("header section must be non-empty") end

                    local firstline = table.map(string.trim, lines[1]:split(" ", 2))

                    if firstline[1] ~= "MOO/1" then error("unsupported protocol version " .. tostring(firstline[1])) end

                    verb    = firstline[2];
                    name    = firstline[3];
                    headers = { }
                    for i=2,(#lines - 1) do             -- last line is empty
                        local nameval = table.map(string.trim, lines[i]:split(":", 1))
                        headers[nameval[1]] = nameval[2];
                    end

                    local content_length = headers["Content-Length"] or 0;
                    if content_length == 0 then
                        on_message(verb, name, headers, "")
                        body = ""
                        parsestate = PS_HEADERS
                        body_remaining = 0
                        headerbuf = ""
                    else 
                        body           = "";
                        body_remaining = tonumber(content_length);
                        parsestate     = PS_BODY;
                    end
                else
                    headerbuf = headerbuf .. b
                    parsestate = PS_HEADERS
                end
            elseif parsestate == PS_BODY       then
                local tocopy = math.min(body_remaining, count)
                body = body .. string.sub(data, offset, offset+tocopy-1)
                offset         = offset + tocopy
                count          = count  - tocopy
                body_remaining = body_remaining - tocopy
                if  body_remaining == 0 then
                    on_message(verb, name, headers, body)
                    body = ""
                    parsestate = PS_HEADERS
                    body_remaining = 0
                    headerbuf = ""
                end
            end
        end
    end
    
    print("Connecting to " .. self.host .. ":" .. self.port);
    self:_change_state(Moo.CONNECTING) 
    self.tcp_client = C4:CreateTCPClient()
	   :OnConnect(function(client)
              self:_log("Connected!");
              self:_change_state(Moo.CONNECTED) 
              self.tcp_client:ReadUpTo(65536)
	   end)
	   :OnRead(function(client,data)
              if self.tcp_client ~= client then return end 
              --log("OnRead(",#data,") " .. data)
              local status,err = pcall(function() 
                  on_read(data, 1, #data);
              end)
              if status then
                  client:ReadUpTo(65536)
              else
                  self:_log("error processing data from remote: " .. err)
                  self:disconnect()
                  delayed_reconnect(2000);
              end
	   end)
	   :OnWrite(function(client)
               if self.tcp_client ~= client then return end 
               if #self.pending_writes == 0 then
                   self.write_pending = false
               else 
                   local buf = self.pending_writes[1]
                   table.remove(self.pending_writes, 1)
                   client:Write(buf)
               end
           end)
	   :OnDisconnect(function(client, errCode, errMsg)
               if self.tcp_client ~= client then return end 
               self:_log("Moo.DISCONNECTED errCode=" .. tostring(errCode) .. " errMsg=" .. tostring(errMsg));
               client:Close();
               self:_change_state(Moo.DISCONNECTED) 
               delayed_reconnect(2000);
	   end)
	   :OnError(function(client,errorCode,errMsg)
               if self.tcp_client ~= client then return end 
               self:_log("Error errCode=" .. tostring(errCode) .. " errMsg=" .. tostring(errMsg));
               self:_change_state(Moo.DISCONNECTED) 
               delayed_reconnect(2000);
	   end)
    self.tcp_client:Connect(self.host, self.port)
end

function Moo:disconnect()
	g_reconnect_seq = g_reconnect_seq + 1
    local tcp_client = self.tcp_client
    self.tcp_client = nil
    if tcp_client then
        self:_log("Disconnecting");
        tcp_client:Close()
        self:_change_state(Moo.DISCONNECTED) 
    end
end

function Moo:reconnect()
    self:disconnect()
    self:connect()
end

function Moo:_send(msg)
    if not self.tcp_client then return end
    --self:_log("SENT " .. msg.verb .. " " .. msg.name .. msg.body)
    local segs = { }    -- build up string segments in an array, then concat once at the end 
    table.insert(segs, "MOO/1 " .. msg.verb .. " " .. msg.name .. "\n")
    if #msg.body > 0 then
        table.insert(segs, "Content-Length: ".. tostring(#msg.body) .. "\n")
    end
    for k,v in pairs(msg.headers) do
        if k ~= "Content-Length" then
            table.insert(segs, k .. ": " .. v .. "\n")
        end
    end
    table.insert(segs, "\n")
    table.insert(segs, msg.body)

    local buf =  table.concat(segs, "")

    if self.write_pending then
        table.insert(self.pending_writes, buf)
    else
        self.write_pending = true
        self.tcp_client:Write(buf)
    end
end

-- send a Moo request.
function Moo:request(msg, cbfunc)
    local rid = self.next_reqid
    self.next_reqid = self.next_reqid + 1
    msg.headers["Request-Id"] = tostring(rid)
    self:_send(msg)
    self.requests[tostring(rid)] = cbfunc
end

-- cb(moo, newstate)
function Moo:on_state_change(cb) 
    table.insert(self.state_change_handlers, cb)
    return self
end

function Moo:on_request(cb) 
    table.insert(self.request_handlers, cb)
    return self
end


-- opts:
--
-- name    = "name"
-- verb    = MooMessage.Request
-- headers = { ... }
-- body    = string
function Moo.message(opts)
    return {
        name    = opts.name    or error("name is a required option"),
        verb    = opts.verb    or Moo.REQUEST,
        headers = opts.headers or {},
        body    = opts.body    or ""
    }
end

function Moo.json_message(opts)
    local o = {
        name    = opts.name    or error("name is a required option"),
        verb    = opts.verb    or Moo.REQUEST,
        headers = opts.headers or {},
    }
    if opts.body then
        o.body = json.encode(opts.body)  
        o.headers["Content-Type"] = "application/json"
    else
        o.body = ""
    end
    return o
end

return Moo
