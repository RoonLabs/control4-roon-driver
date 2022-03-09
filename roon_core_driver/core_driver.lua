local json  = require("dkjson")
local utils = require("utils")
local Moo   = require("moo")

local CORE_ZONE_INTERFACE_VERSION = 1
local PRX_CMD                     = { } 

g_moo_conn        = nil
g_core_info       = nil   -- { core_id = <string>, display_name = <string>, display_version = <string> }
g_core_state      = nil  
g_core_http_port  = nil
g_zones           = { }  -- array of Roon API zone objects
g_zone_drivers    = { }  -- from C4 driver id to C4 driver name
g_room_outputs    = { }  -- from C4 room id to Roon output id
g_output_devids   = { }  -- from Roon output id to C4 device id
g_outputs_count   = { }  -- from Roon output id to count of rooms set to that output
g_zone_queues     = { }  -- from Roon zone ID to Roon queue
g_next_subid      = math.random(0,2000000000)

function gen_subid() 
    local ret = "C4:" .. tostring(C4:GetDeviceID()) .. ":" .. tostring(g_next_subid)
    g_next_subid = g_next_subid + 1
    return ret
end

function log(...)
    local s = table.concat(table.map(tostring, {...}), " ")
    print(s) 
    C4:DebugLog(s)
end

local CoreState = {
    AwaitingInfo          = "AwaitingInfo",
    AwaitingAuthorization = "AwaitingAuthorization",
    Ready                 = "Ready",
    NotCompatible         = "NotCompatible",
}

function refresh_zones()
    local devs = C4:GetDevicesByC4iName("Roon Zone.c4z")
    if devs ~= nil then
        local old_zone_count = #g_zone_drivers
        for devid,drivername in pairs(devs) do
            g_zone_drivers[devid] = drivername
        end
        if #g_zone_drivers ~= old_zone_count then
            update_status()
        end
    end
    broadcast_all_zones()
end

function broadcast_all_zones()
    if not g_zones then return end
    for i,zone in ipairs(g_zones) do
        ev_zone_updated(zone)
    end
end

function OnDriverInit() 
    log("---[ Core Driver Init ]---");
end

function OnDriverLateInit()
    C4:SetTimer(500, function()
        force_disconnect();
        try_connect()
        foreach_zone(function(zone) 
            C4:SendToDevice(zone.device_id, "ROON_CORE_CREATED", { SENDER = C4:GetDeviceID() })
        end)
    end, false)
end

function OnBindingChanged(idBinding, strclass, bIsBound) 
    log("OnBindingChanged " .. tostring(idBinding) .. " " .. tostring(strclass) .. " " .. tostring(bIsBound))
end

-- Called when the dealer sets properties in Composer
function OnPropertyChanged(name)
    if name == "Core IP Address" or name == "Core Port" then
        force_disconnect()
        try_connect()
    end
end


function PrintTable(tValue, sIndent)
    sIndent = sIndent or "   "
    for k,v in pairs(tValue) do
        log(sIndent .. tostring(k) .. ":  " .. tostring(v))
        if (type(v) == "table") then
            PrintTable(v, sIndent .. "   ")
        end
    end
end

function ReceivedFromProxy(idBinding, sCommand, tParams)
    if (sCommand ~= nil) then
        if(tParams == nil)        -- initial table variable if nil
                then tParams = {}
        end
        log("ReceivedFromProxy(): " .. sCommand .. " on binding " .. idBinding .. "; Call Function " .. sCommand .. "()")
        PrintTable(tParams, "     ")
        if (PRX_CMD[sCommand]) ~= nil then
            PRX_CMD[sCommand](idBinding, tParams)
        else
            log("ReceivedFromProxy: Unhandled command = " .. sCommand)
        end
    end
end

function SendToProxy(idBinding, strCommand, tParams, strCallType, bAllowEmptyValues)
    log("SendToProxy (" .. idBinding .. ", " .. strCommand .. ")")
    PrintTable(tParams, "     ")
    if (strCallType ~= nil) then
        if (bAllowEmptyValues ~= nil) then
            C4:SendToProxy(idBinding, strCommand, tParams, strCallType, bAllowEmptyValues)
        else
            C4:SendToProxy(idBinding, strCommand, tParams, strCallType)
        end
    else
        if (bAllowEmptyValues ~= nil) then
            C4:SendToProxy(idBinding, strCommand, tParams, bAllowEmptyValues)
        else
            C4:SendToProxy(idBinding, strCommand, tParams)
        end
    end
end

-- Called when commands are executed, for example the Actions tab in composer
function ExecuteCommand(strCommand, tParams)
	log("ExecuteCommand, str: " .. strCommand)
	PrintTable(tParams)
    if strCommand == "LUA_ACTION" then
       if tParams ~= nil then
          for cmd,cmdv in pairs(tParams)do
             if cmd == "ACTION" then
                if cmdv == "Reconnect" then
                    force_disconnect();
                    try_connect()
                elseif cmdv == "Disconnect" then
                    force_disconnect();
				elseif cmdv == "AutoConnectGroups" then
					connect_grouping()
                end
             end
          end
       end
    elseif strCommand == "ROON_CORE_REFRESH_ZONES" then
        C4:SetTimer(500, refresh_zones, false)

    elseif strCommand == "ROON_CORE_GET_INFO" then
        send_g_core_info(tParams.SENDER)

    elseif strCommand == "ROON_MOO_BRIDGE_REQUEST" then
        if g_moo_conn then
            local ref = tParams.REF
            g_moo_conn:request(json.decode(tParams.MESSAGE), function(m)
                C4:SendToDevice(tParams.SENDER, "ROON_MOO_BRIDGE_RESPONSE", {
                    SENDER  = C4:GetDeviceID(), 
                    REF     = ref,
                    MESSAGE = json.encode(m)
                })
            end)
        end
    elseif strCommand == "ROON_CORE_SET_ROOM_OUTPUT" then
		if tParams.OUTPUTID ~= nil then
			g_output_devids[tParams.OUTPUTID] = tParams.SENDER
		elseif g_room_outputs[tParams.ROOMID] ~= nil then
			g_output_devids[g_room_outputs[tParams.ROOMID]] = nil
		end
		g_room_outputs[tParams.ROOMID] = tParams.OUTPUTID
        
    elseif strCommand == "ROON_CORE_ADD_TO_GROUP" then
        if g_moo_conn then
			local outputs = { }	
			if string.starts(tParams.ADDED, tostring(tParams.SENDER)) then
				table.insert(outputs, g_room_outputs[tParams.SENDER])
			else	
				local i = 1
				for id in string.gmatch(tParams.GROUP, "%S+") do
					outputs[id] = i
					i = i + 1
				end
				for room_id in string.gmatch(tParams.ADDED, "%S+") do
					local added = g_room_outputs[room_id]
					if outputs[added] == nil then
						outputs[added] = i
						i = i + 1
					end
				end
			end
			
			local outputs_array = { }
			for k,v in pairs(outputs) do
				log("key: " .. k .. " value: " .. v)
				outputs_array[v] = k
			end
            g_moo_conn:request(Moo.json_message({ name = "com.roonlabs.transport:2/group_outputs",
                                                  body = { output_ids = outputs_array } }),
                               function(m)
                                  log ("response from group outputs message")
                               end)
        end
	elseif strCommand == "ROON_CORE_REMOVE_FROM_GROUP" then
        if g_moo_conn then
			local removes = { }
			local i = 1
			for room_id in string.gmatch(tParams.REMOVED, "%S+") do
				table.insert(removes, g_room_outputs[room_id])
			end
            g_moo_conn:request(Moo.json_message({ name = "com.roonlabs.transport:2/ungroup_outputs",
                                                  body = { output_ids = removes } }),
                               function(m)
                                  log ("response from group outputs message")
                               end)
        end
	elseif strCommand == "ROON_CORE_GET_QUEUE" then
		PrintTable(g_zone_queues)
		if g_moo_conn then
			local zone_id = tParams.ZONEID
			if zone_id == nil then return end
			if not g_zone_queues[zone_id] then
				subscribe_queue(zone_id)
			else
				ev_queue_updated(g_zone_queues[zone_id], zone_id, tParams.SENDER)
			end
		end
    end
end

function send_g_core_info(zone_device_id)
    local params = { 
        DEVICE_ID = C4:GetDeviceID(),
    }
    if g_moo_conn then 
        params.MOO_STATE = g_moo_conn.state 
    end
    if g_core_state then
        params.g_core_state = g_core_state
    end
    if g_core_http_port then
        params.HTTP_PORT  = g_core_http_port
        params.HTTP_IP    = Properties["Core IP Address"]
    end
    if g_core_info then
        params.CORE_ID         = g_core_info.core_id
        params.DISPLAY_NAME    = g_core_info.display_name
        params.DISPLAY_VERSION = g_core_info.display_version
    end
    C4:SendToDevice(zone_device_id, "ROON_CORE_INFO", params)
end

function broadcast_core_info()
    foreach_zone(function(zone) send_g_core_info(zone.device_id) end)
end

function foreach_zone(cb_zone) 
    local g_zone_drivers = C4:GetDevicesByC4iName("Roon Zone.c4z")
    if g_zone_drivers ~= nil then
        for devid,drivername in pairs(g_zone_drivers) do
            cb_zone({ 
                device_id    = devid, 
                driver_name = drivername
            })
        end
    end
end

function foreach_output(cb_output)
	for i,zone in ipairs(g_zones) do
		for j,output in ipairs(zone.outputs) do
			cb_output(output)
		end
	end
end

function OnDriverDestroyed()
    foreach_zone(function(zone) 
        C4:SendToDevice(zone.device_id, "ROON_CORE_DESTROYED", { SENDER = C4:GetDeviceID() })
    end)
end

function force_disconnect()
    if g_moo_conn then
        g_moo_conn:disconnect()
        g_moo_conn = nil
    end
end

-- If we are configured, or configuration has changed, then reconnect
function try_connect()
    local port = Properties["Core Port"];
    local host = Properties["Core IP Address"];
    
    if not port or not host or port == 0 or host == "" then
        force_disconnect()
        return
   end

   if g_moo_conn and g_moo_conn.host == host and g_moo_conn.port == port then
       return
   end

   force_disconnect()
   g_moo_conn = Moo:new(host, port)
                 :on_state_change(ev_moo_state_changed)
                 :on_request(ev_moo_request)
   g_moo_conn:connect()
end

function connect_grouping()
	local groups = { }
	foreach_output(function(output)
		local found = false
		for i,group in ipairs(groups) do
			if is_in_grouping(output.output_id, group) then
				found = true
				break
			end
		end
		if not found and (#output.can_group_with_output_ids ~= 0) then
			table.insert(groups, output.can_group_with_output_ids)
		end
	end)
	for i=1,5 do
		local group = groups[i]
		local core_proxy_dev = C4:GetDeviceID() + 1 + i
		local start = (i - 1) * 32
		for j=1,32 do
			local offset = start + j
			local devs = C4:GetBoundConsumerDevices(core_proxy_dev, 4000 + offset)
			if devs ~= nil then
				for id,name in pairs(devs) do
					C4:Unbind(id, 3000)
				end
			end
			if C4:GetBoundProviderDevice(core_proxy_dev, 3100 + offset) ~= 0 then
				C4:Unbind(core_proxy_dev, 3100 + offset)
			end
		end
		if group ~= nil then
			local offset = start
			for j,output_id in ipairs(group) do
				local zone_device_id = g_output_devids[output_id]
				if zone_device_id == nil then 
					log("null device id")
				else
					offset = offset + 1
					--core is provider
					log("bind args: " .. core_proxy_dev .. ", " .. 4000 + offset .. ", " .. zone_device_id + 2 .. ", " .. 3000 .. ", " .. "RF_ROON_NET_AUDIO")
					C4:Bind(core_proxy_dev, 4000 + offset, zone_device_id + 2, 3000, "RF_ROON_NET_AUDIO")
					--core is consumer
					log("bind args: " .. zone_device_id + 1 .. ", " .. 4000 .. ", " .. core_proxy_dev .. ", " .. 3100 + offset .. ", " .. "RF_ROON_NET_ZONE")
					C4:Bind(zone_device_id + 1, 4000, core_proxy_dev, 3100 + offset, "RF_ROON_NET_ZONE")
				end
			end
		end
	end
end

function is_in_grouping(output_id, group)
	for _,group_id in ipairs(group) do
		if output_id == group_id then return true end
	end
	return false
end

function update_status() 
    local port = Properties["Core Port"];
    local host = Properties["Core IP Address"];

    if not port or not host or port == 0 or host == "" then
        C4:UpdateProperty("Status", "Please configure IP Address and Port")

    elseif not g_moo_conn then
        C4:UpdateProperty("Status", "Disconnected")

    elseif g_moo_conn.state ~= Moo.CONNECTED then 
        C4:UpdateProperty("Status", g_moo_conn.state)

    elseif not g_core_info then 
        C4:UpdateProperty("Status", g_moo_conn.state .. ", Waiting for Core")

    else
        if     g_core_state == CoreState.AwaitingInfo then
            C4:UpdateProperty("Status", "Loading Core Information")
        elseif g_core_state == CoreState.AwaitingAuthorization then
            C4:UpdateProperty("Status", "Go to Roon->Settings->Extensions and enable Control:4")
        elseif g_core_state == CoreState.Ready then
            C4:UpdateProperty("Status", "Ready")
        elseif g_core_state == CoreState.NotCompatible then
            C4:UpdateProperty("Status", "Roon Core Update Required")
        else 
            C4:UpdateProperty("Status", g_moo_conn.state .. ", " .. tostring(g_core_state))
        end
    end

    if g_core_info then 
        C4:UpdateProperty("Core Name",    g_core_info.display_name)
        C4:UpdateProperty("Core Version", g_core_info.display_version)
    else
        C4:UpdateProperty("Core Name", "")
        C4:UpdateProperty("Core Version", "")
    end

    broadcast_core_info()
end

function ev_zone_updated(zone, seek_only)
    local zone_json = json.encode(zone)
    local params = {
        SENDER     = C4:GetDeviceID(), 
        ZONE       = zone_json,
        CORE_ID    = g_core_info.core_id,
        ZONE_ID    = zone.zone_id,
        SEEK_ONLY  = seek_only and "true" or "false"
    }
    foreach_zone(function(zone_driver) 
        C4:SendToDevice(zone_driver.device_id, "ROON_API_ZONE_UPDATED", params)
    end)
end

function ev_zone_removed(zone)
    local params = { 
        SENDER = C4:GetDeviceID(), 
        CORE_ID    = g_core_info.core_id,
        ZONE_ID    = zone.zone_id,
    }
    foreach_zone(function(zone_driver) 
        C4:SendToDevice(zone_driver.device_id, "ROON_API_ZONE_REMOVED", params)
    end)
	g_zone_queues[zone.zone_id] = nil
end

function ev_queue_updated(queue, zone_id, device_id)
	log("ev_queue_updated, zone_id: " .. zone_id)
	g_zone_queues[zone_id] = queue
	local queue_json = json.encode(queue)
	local params = {
		SENDER     = C4:GetDeviceID(), 
		QUEUE      = queue_json,
		CORE_ID    = g_core_info.core_id,
		ZONE_ID    = zone_id,
	}
	if not device_id then
		foreach_zone(function(zone_driver)
			C4:SendToDevice(zone_driver.device_id, "ROON_API_QUEUE_UPDATED", params)
		end)
	else
		C4:SendToDevice(device_id, "ROON_API_QUEUE_UPDATED", params)
	end
end

function subscribe_queue(zone_id)
	log("subscribe_queue 1, id: " .. zone_id)
	if not g_moo_conn then return end
	log("subscribe_queue 2, id: " .. zone_id)
	if not g_zone_queues[zone_id] then g_zone_queues[zone_id] = { } end
	log("subscribe_queue 3, id: " .. zone_id)
	g_moo_conn:request(Moo.json_message({ name = "com.roonlabs.transport:2/subscribe_queue",
										  body = { subscription_key = zone_id,
										           zone_or_output_id = zone_id,
												   max_item_count = 10, } }),
					    function(m)
							if g_core ~= core then return end
							log("queue update message, string: " .. m.body)
                            local body = json.decode(m.body)
                            if m.name == "Subscribed" then
								ev_queue_updated(body.items, zone_id, false)
								--g_zone_queues[zone_id] = body.items
							elseif m.name == "Changed" then
								local queue = g_zone_queues[zone_id]
								for _,change in ipairs(body.changes) do
									if change.operation == "remove" then
										pos = change.index + 1
										for i=1,change.count do
											table.remove(queue, pos)
										end
									elseif change.operation == "insert" then
										for i,item in pairs(change.items) do
											table.insert(queue, change.index + i, item)
										end
									end
								end
								ev_queue_updated(queue, zone_id, false)
							end
						end)
end

function unsubscribe_queue(output_id)
	log("unsubscribe_queue, id: " .. output_id)
	g_moo_conn:request(Moo.json_message({ name = "com.roonlabs.transport:2/unsubscribe_queue",
									      body = { subscription_key = output_id, }}),
		                function(m)
							log("unsubscribe_queue, response, name: " .. m.name)
						end)
	g_zone_queues[output_id] = nil
end

function ev_ready()
    log("---[ Ready ]---")
    g_zones_subid = gen_subid()
	g_zone_queues = { }
    g_moo_conn:request(Moo.json_message({ name = "com.roonlabs.transport:2/subscribe_zones", 
                                            body = { subscription_key = g_zones_subid } }),
                         function(m)
                             if g_core ~= core then return end
                             local body = json.decode(m.body)
                             if m.name == "Subscribed" then
                                g_zones = body.zones
                                broadcast_all_zones()

                             elseif m.name == "Changed" then
                                 -- process removes
                                 if body.zones_removed then
                                     local new_zones = { } 
                                     for idx,existing in ipairs(g_zones) do
                                         local skip = false
                                         for _,zone_id in ipairs(body.zones_removed) do
                                             if zone_id == existing.zone_id then
                                                 skip = true
                                                 break
                                             end
                                         end
                                         if not skip then
                                             table.insert(new_zones, existing)
                                         else
                                             ev_zone_removed(existing)
                                         end
                                     end
                                     g_zones = new_zones
                                 end

                                 -- process adds
                                 if body.zones_added then
                                     for _,zone in ipairs(body.zones_added) do
                                         zone.dirty = true
                                         table.insert(g_zones, zone)
                                         ev_zone_updated(zone, false)
                                     end
                                 end

                                 -- process changes
                                 if body.zones_changed then
                                     for _,zone in ipairs(body.zones_changed) do
                                         for idx,existing in ipairs(g_zones) do
                                             if existing.zone_id == zone.zone_id then
                                                 g_zones[idx] = zone
                                                 zone.dirty = true
                                                 ev_zone_updated(zone, false)
                                             end
                                         end
                                     end
                                 end
								 
								 -- process seek only changes
								 if body.zones_seek_changed then
									 for _,zone in ipairs(body.zones_seek_changed) do
										 ev_zone_updated(zone, true)
									 end
								 end
                             end
                         end)
end

function ev_moo_request(themoo, cx, m) 
    if m.name == "com.roonlabs.ping:1/ping" then
        cx:respond(Moo.message({
            verb = Moo.COMPLETE,
            name = "Success",
        }))
    end
end

function ev_moo_state_changed(themoo, state) 
    if themoo ~= g_moo_conn then return end
    update_status()

    if state == Moo.CONNECTED then 
        g_core_info  = nil
        g_core_state = CoreState.AwaitingInfo

        local got_response = false

        C4:SetTimer(5000, function()
            if not got_response then
                log("Timed out while waiting for info response. Trying again")
                force_disconnect();
                try_connect()
            end
        end, false)

        g_moo_conn:request(Moo.message { name = "com.roonlabs.registry:1/info" },
            function(message) 
                got_response = true
                local response = json.decode(message.body)
                if message.name == "Success" then
                    log("[roonapi] Connected to Core: " .. response.core_id);
                    local token_key = "token_" .. response.core_id
                    local token = PersistData[token_key]
                    if token then
                        log("[roonapi] Using saved token: " .. token)
                    else 
                        log("[roonapi] No saved token")
                    end
                    g_core_info  = response
                    g_core_state = CoreState.AwaitingAuthorization
                    g_moo_conn:request(Moo.json_message {
                        name = "com.roonlabs.registry:1/register",
                        body = {
                            token             = token,
                            extension_id      = "com.roonlabs.control4",
                            display_name      = "Control:4",
                            display_version   = "1.0",
                            publisher         = "Roon Labs, LLC",
                            email             = "contact@roonlabs.com",
                            website           = "http://www.roonlabs.com",
                            provided_services = { 
                                "com.roonlabs.ping:1",
                            },
                            required_services = {
                                "com.roonlabs.transport:2",
                                "com.roonlabs.browse:1",
                                "com.roonlabs.control4:1",
                            },
                            optional_services = { },
                            pairing_required  = false
                        }
                    },
                    function(message)
                        local response = json.decode(message.body)
                        if message.name == "Registered" then
                            g_core_state             = CoreState.Ready
                            PersistData[token_key] = response.token
                            g_core_http_port         = response.http_port
                            ev_ready()
                        elseif message.name == "Unregistered" then
                            error("unregistered")       -- triggers disconnect+reconnect
                        elseif message.name == "NotCompatible" then 
                            g_core_state = CoreState.NotCompatible
                        end
                        update_status()
                    end)
                else
                    error("got error response from info")
                end
                update_status()
            end)
    else
        g_core_state  = nil
        g_core_info   = nil
		g_zone_queues = { }
    end

    update_status()
end

log("---[ Loaded Core Driver ]---");
