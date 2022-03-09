json      = require("dkjson")
utils     = require("utils")
Moo       = require("moo")
MooBridge = require("moobridge")

-- globals 
g_cores           = { }
g_zones           = { }
g_zone_queues     = { }
g_zones_subid     = nil
g_core            = nil
g_output          = nil
g_zone            = nil
g_moo_bridge      = nil
g_next_subid      = math.random(0,2000000000)
g_failure         = nil
g_last_dashboard  = nil
g_browse_sessions = { }
g_browse_replace  = { }
g_user_input      = nil
g_input_value     = nil         -- brief state saving for the search screen load
g_browse_seq      = 1
g_added_seq       = 1
g_added_rooms     = ""
g_removed_seq     = 1
g_removed_rooms   = ""

-- used for avoiding duplicate updates to the C4 infrastructure
local last_length
local last_seek

local last_line1
local last_line2
local last_line3
local last_line4
local last_imageurl

local last_volume = -1
local last_mute   = nil

-- to avoid repetitive property updates
local last_output_settings_names = nil
local last_core_settings_names   = nil
local last_core_setting = nil
local last_zone_setting = nil

function gen_subid() 
    local ret = "C4:" .. tostring(C4:GetDeviceID()) .. ":" .. tostring(g_next_subid)
    g_next_subid = g_next_subid + 1
    return ret
end

local CORE_ZONE_INTERFACE_VERSION = 1

function fail(...)
    local s = table.concat(table.map(tostring, {...}), " ")
    g_failure = s
end

--=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
-- Driver Declarations
--=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
--[[
    Command Handler Tables
--]]
PRX_CMD = {}

-- Constants
MEDIA_SERVICE_BINDING = 5001
AMPLIFIER_BINDING     = 5002

--image path
gControllerIPAddress = C4:GetControllerNetworkAddress()
gDriverPath          = "http://" .. gControllerIPAddress .. "/driver/Roon%20Zone/"

--=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
-- Utils
--=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
function log(...)
    local s = table.concat(table.map(tostring, {...}), " ")
	local m = 100
	local l = string.len(s)
	local n = l / m
	for i = 1, (n + 1) do
		--print(string.sub(s, ((i - 1) * m) + 1, i * m))
	end
    print(s)
    C4:DebugLog(s)
end
function log2(s)
	local m = 5
	local l = string.len(s)
	local n = l / m
	for i = 1, (n + 1) do
		print(string.sub(s, ((i - 1) * m) + 1, i * m))
        C4:DebugLog(s)
	end
end

function get_image_url(key, size, nil_ok)
    if not key or not g_core then 
        if nil_ok then 
            return nil 
        else
            --return "controller://driver/Roon%20Zone/icons/noartwork/noartwork.png" 
            return gDriverPath .. "icons/noartwork/noartwork.png"
        end
    end
    return "http://" .. tostring(g_core.http_ip) .. ":" .. tostring(g_core.http_port) .. "/api/image/" .. key .. "?scale=fit&width="..tostring(size).."&height="..tostring(size)
end

function print_table(tValue, sIndent)
    sIndent = sIndent or "   "
    for k,v in pairs(tValue) do
        local v_tos = tostring(v)
        --if #v_tos > 256 then v_tos = v_tos:sub(1,256) .. "..." end
        log(sIndent .. tostring(k) .. ":  " .. v_tos)
        if (type(v) == "table") then
            print_table(v, sIndent .. "   ")
        end
    end
end

---------------------------------------------------------------------
-- ReceivedFromProxy Code
---------------------------------------------------------------------
function ReceivedFromProxy(idBinding, sCommand, tParams)
    if (sCommand ~= nil) then
        if(tParams == nil)        -- initial table variable if nil
            then tParams = {}
        end
        log("ReceivedFromProxy(): " .. sCommand .. " on binding " .. idBinding .. "; Call Function " .. sCommand .. "()")
        print_table(tParams, "     ")
        if (PRX_CMD[sCommand]) ~= nil then
            PRX_CMD[sCommand](idBinding, tParams)
        else
            log("ReceivedFromProxy: Unhandled command = " .. sCommand)
        end
    end
end

function ParseProxyCommandArgs(tParams)
    local args = {}
    local parsedArgs = C4:ParseXml(tParams["ARGS"])
    for i,v in pairs(parsedArgs.ChildNodes) do
        args[v.Attributes["name"]] = v.Value
    end
    return args
    
end

---------------------------------------------------------------------
-- Proxy Functions
---------------------------------------------------------------------

function PRX_CMD.GetBrowseMusicMenu(idBinding, tParams)
    if not g_output then output_not_available(idBinding); return end
    local args = ParseProxyCommandArgs(tParams)
    if args.level == nil then
        args.level = 0
    else
        args.level = args.level + 1
    end

    function finish(load_level)
        log("finish, level: " .. load_level)
        g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.browse:1/load",
            body = {
                multi_session_key = tParams.NAVID,
                hierarchy         = "browse",
                offset            = args.offset,
                count             = args.count,
                level             = load_level,
            }}), function (m)
                local body = json.decode(m.body)
                if m.name ~= "Success" then return end
                local list_has_images = false
                for i,item in ipairs(body.items) do
                    if item.image_key then
                        list_has_images = true
                        break
                    end
                end
                --local hint = nil
                local tListItems = {}
                local tAlphaMap = {}
                local prev_first_char = ""
                --this level arg will be sent as the level arg by the C4 navigator when and item in the list is selected
                local next_level = body.list.hint == "action_list" and (body.list.level - 1) or (body.list.level + 1)
                for i,item in ipairs(body.items) do
                    table.insert(tListItems, {
                        type           = "item",
                        text           = item.title,
                        subtext        = item.subtitle,
                        image_url      = get_image_url(item.image_key, 128, not list_has_images or item.hint == "action_list"),
                        key            = item.item_key,
                        level          = body.list.level,
                        default_action = item.input_prompt and "SearchMediaAction" or "BrowseMediaAction",
                        folder         = item.hint == "list"   and "true" or "false",
                        is_header      = item.hint == "header" and "true" or "false",
                    })
                    local first_char = string.sub(item.title, 1, 1)
                    --if first_char ~= prev_first_char then
                    if i == 1 then
                        prev_first_char = first_char
                        table.insert(tAlphaMap, {
                            key   = item.title,
                            index = i - 1,
                        })
                    end
                end
                local response = ""
                --response = response .. BuildListXml(tAlphaMap, true, "AlphaMap")
                response = response .. BuildListXml(tListItems, true)
                --if #tListItems > 12 then
                    --response = response .. BuildListXml(tAlphaMap, true, "AlphaMap")
                --end
                DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], response)
            end)
    end

    if g_browse_sessions[tParams.NAVID] then
        log("existing session")
        finish(math.min(args.level, g_browse_sessions[tParams.NAVID].level))
    else 
        log("browse request")
        g_browse_sessions[tParams.NAVID] = { }
        g_browse_replace[tParams.NAVID] = nil
        g_moo_bridge:request(
            Moo.json_message({name = "com.roonlabs.browse:1/browse", 
            body = { 
                 multi_session_key = tParams.NAVID,
                 item_key          = args.key,
                 zone_or_output_id = g_output.output_id,
                 pop_all           = true,
                 hierarchy         = "browse",
                 input             = args.search
            }}), 
            function (m) 
                if m.name ~= "Success" then return end
                local body = json.decode(m.body)
                g_browse_sessions[tParams.NAVID].level = body.list.level
                finish(body.list.level) 
            end)
    end
end 

function PRX_CMD.BackCommand(idBinding, tParams) 
    log("back command 1")
    print_table(g_browse_replace)
    log("back command 2")
    g_moo_bridge:request(
        Moo.json_message({name = "com.roonlabs.browse:1/browse", 
        body = { 
             multi_session_key = tParams.NAVID,
             pop_levels        = 1,
             zone_or_output_id = g_output.output_id,
             hierarchy         = "browse",
        }}), 
        function(m)
            log("back command 3")
            local nextscreen = ""
            log("back command 4")
            if g_browse_replace[tParams.NAVID] == true then
                log("hybrid back!!!")
                g_browse_replace[tParams.NAVID] = false
                nextscreen = browse_same()
            end
            log("back command 5")
            DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], nextscreen)
        end)
end

function browse_same() return "<ReplaceScreen>BrowseMusic</ReplaceScreen>" end
function browse_back() return "<RemoveScreen>true</RemoveScreen>"          end
function browse_fwd()  return "<NextScreen>BrowseMusic</NextScreen>"       end

function PRX_CMD.SearchMusicCommand(idBinding, tParams)
    local args = ParseProxyCommandArgs(tParams)
    browse(idBinding, tParams, args.level, args.key, args.search)
end

function PRX_CMD.BrowseMusicCommand(idBinding, tParams) 
    local args = ParseProxyCommandArgs(tParams)
    browse(idBinding, tParams, args.level, args.key)
end 

function PRX_CMD.DEVICE_SELECTED(idBinding, tParams) 
    force_refresh_data()
end

function output_not_available(idBinding)
    local evt_args = { }
    evt_args["Id"]        = "MessageNotification"
    evt_args["Title"]     = "Roon"
    evt_args["Message"]   = "Zone is not available"
    local tParams = { }
    tParams["EVTARGS"] = BuildSimpleXml(nil, evt_args, true)
    tParams["NAME"] = "DriverNotification"
    SendToProxy(idBinding, "SEND_EVENT", tParams, "COMMAND")    
end

function browse(idBinding, tParams, level, key, input) 
    level = tonumber(level)
    g_browse_seq = g_browse_seq + 1
    local browse_seq = g_browse_seq

    g_moo_bridge:request(
        Moo.json_message({name = "com.roonlabs.browse:1/browse", 
        body = { 
             multi_session_key = tParams.NAVID,
             item_key          = key,
             zone_or_output_id = g_output.output_id,
             hierarchy         = "browse",
             input             = input,
        }}), 
        function (m)
            if m.name ~= "Success" then return end

            local body = json.decode(m.body)

            if browse_seq ~= g_browse_seq then
                DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], "")
            end

            if body.action == "message" then
                -- show a notification box with the messge
                local evt_args = { }
                evt_args["Id"]        = "MessageNotification"
                evt_args["Title"]     = "Roon"
                evt_args["Message"]   = body.message
                tParams["EVTARGS"] = BuildSimpleXml(nil, evt_args, true)
                tParams["NAME"] = "DriverNotification"
                SendToProxy(idBinding, "SEND_EVENT", tParams, "COMMAND")    
                DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], "")

            elseif body.action == "none" then
                DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], "")

            elseif body.action == "list" then
                local new_level = body.list.level
                g_browse_sessions[tParams.NAVID].level  = new_level

                print_table(g_browse_replace)
                if new_level < level then
                    if g_browse_replace[tParams.NAVID] == true then
                        g_browse_replace[tParams.NAVID] = false
                        DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_same())
                    else
                        DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_back())
                    end
                elseif new_level == level then 
                    DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_same())
                else
                    if body.list.hint == "action_list" then
                        g_browse_replace[tParams.NAVID] = true
                        DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_same())
                    else
                        DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_fwd(new_level))
                    end
                end

            elseif body.action == "replace_item" then
                DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_same())

            elseif body.action == "remove_item" then
                DataReceived(idBinding, tParams["NAVID"], tParams["SEQ"], browse_same())
            end
        end)
end

function PRX_CMD.DESTROY_NAV(idBinding, tParams)
    g_browse_sessions[tParams.NAVID] = nil
    g_browse_replace[tParams.NAVID] = nil
end

local g_vol_down_timer
local g_vol_up_timer

function vol_relative(value)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/change_volume", 
                         body = { 
                             output_id = g_output.output_id,
                             how       = "relative_step",
                             value     = value,
                         }}))
end


function vol_down() vol_relative(-1) end
function vol_up()   vol_relative( 1) end

function PRX_CMD.START_VOL_DOWN(idBinding, tParams)    
    vol_down()
    g_vol_down_timer = C4:SetTimer(200, function(oTimer,nSkips) vol_down() end, true)
end
function PRX_CMD.STOP_VOL_DOWN(idBinding, tParams)    
    if g_vol_down_timer then
        g_vol_down_timer:Cancel()
        g_vol_down_timer = nil
    end
end
function PRX_CMD.PULSE_VOL_DOWN(idBinding, tParams) vol_down() end

function PRX_CMD.START_VOL_UP(idBinding, tParams)    
    vol_up()
    g_vol_up_timer = C4:SetTimer(200, function(oTimer,nSkips) vol_up() end, true)
end
function PRX_CMD.STOP_VOL_UP(idBinding, tParams)    
    if g_vol_up_timer then
        g_vol_up_timer:Cancel()
        g_vol_up_timer = nil
    end
end
function PRX_CMD.PULSE_VOL_UP(idBinding, tParams) vol_up() end

function PRX_CMD.MUTE_OFF(idBinding, tParams)    
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/mute", 
                         body = { 
                             output_id = g_output.output_id,
                             how       = "unmute"
                         }}))
end

function PRX_CMD.MUTE_TOGGLE(idBinding, tParams)    
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/mute", 
                         body = { 
                             output_id = g_output.output_id,
                             how       = "toggle"
                         }}))
end

function PRX_CMD.MUTE_ON(idBinding, tParams)    
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/mute", 
                         body = { 
                             output_id = g_output.output_id,
                             how       = "mute"
                         }}))
end

function PRX_CMD.PLAY(idBinding, tParams)    
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "play"
                         }}))
end

function PRX_CMD.PAUSE(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "pause"
                         }}))
end

function PRX_CMD.TransportSkipRevButton(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "previous"
                         }}))
end

function PRX_CMD.TransportSkipFwdButton(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "next"
                         }}))
end

function PRX_CMD.GetQueue(idBinding, tParams)
	if not g_output then return end
	C4:SendToDevice(g_core.device_id, "ROON_CORE_GET_QUEUE", {
            SENDER = C4:GetDeviceID(),
            ROOMID = C4:RoomGetId(),
            ZONEID = g_zone.zone_id
        })
	broadcast_queue()
end 

function broadcast_queue(force)
    local args = "<NowPlayingIndex>0</NowPlayingIndex>"
	local list = { }
	if g_zone then
		log("g_zone, id: " .. g_zone.zone_id)
		--print_table(g_zone)
		if g_zone_queues[g_zone.zone_id] then
			log("queue of zone id")
			--print_table(g_zone_queues[g_zone.zone_id])
			
			for i,item in ipairs(g_zone_queues[g_zone.zone_id]) do
				local l_item = { }
				l_item.Id = i
				l_item.Title = item.two_line.line1
				l_item.SubTitle = item.two_line.line2
				l_item.ImageUrl = get_image_url(item.image_key, 512, true)
				l_item.type = "song"
				l_item.key = item.queue_item_id
				table.insert(list, l_item)
			end
			
		end
	end
	args = args .. BuildListXml(list, true)
    QueueChanged(MEDIA_SERVICE_BINDING, nil, args)
end

function PRX_CMD.GetDashboard(idBinding, tParams)
    force_refresh_data()
end

function PRX_CMD.PLAY(idBinding, tParams)    
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "play"
                         }}))
end

function PRX_CMD.NowPlayingCommand(idBinding, tParams)
	if not g_output then return end
	if tParams.ROOMID ~= tostring(C4:RoomGetId()) then return end
	
	local args = ParseProxyCommandArgs(tParams)
	g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/play_from_here", 
						body = { 
							zone_or_output_id = g_output.output_id,
							queue_item_id     = args.key,
						}}))
end

---------------------------------------------------------------------
-- Notification Functions
---------------------------------------------------------------------
function SendToProxy(idBinding, strCommand, tParams, strCallType, bAllowEmptyValues)
    log("SendToProxy (" .. idBinding .. ", " .. strCommand .. ")")
    print_table(tParams, "     ")
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

function SendEvent(idBinding, navId, tRooms, name, tArgs)
    -- This function must have a registered navigator event set up
    local tParams = {}
    if (navId ~= nil) then
        tParams["NAVID"] = navId
        --dbg("SendEvent " .. name .. " to navigator " .. navId)
    elseif (tRooms ~= nil) then
        local rooms = ""
        for i,v in pairs(tRooms) do
            if (string.len(rooms) > 0) then
                rooms = rooms .. ","
            end
            rooms = rooms .. tostring(v)
        end
        
        if (string.len(rooms) > 0) then
            tParams["ROOMS"] = rooms
        end
        --dbg("SendEvent " .. name .. " to navigators in rooms " .. rooms)
    else
        --dbg("SendEvent " .. name .. " to all navigators (broadcast)")
    end
    tParams["NAME"] = name
    tParams["EVTARGS"] = BuildListXml(tArgs, true)
    SendToProxy(idBinding, "SEND_EVENT", tParams, "COMMAND")
end

function BroadcastEvent(idBinding, name, tArgs)
    local tParams = {}
    tParams["NAME"] = name
    tParams["EVTARGS"] = BuildSimpleXml(nil, tArgs, true)
    SendToProxy(idBinding, "SEND_EVENT", tParams, "COMMAND")    
end

function SendQueueChangedEvent(queueId, args)
    log("SendQueueChangedEvent(" .. queueId .. ")")
    local tRooms = GetRoomsByQueue(nil, queueId)
	local tParams = { }
	tParams["NAME"] = QueueChanged
	tParams["EVTARGS"] = args
    if (tRooms ~= nil) then
        SendEvent(MEDIA_SERVICE_BINDING, nil, tRooms, "QueueChanged", tArgs)
    end
end
---------------------------------------------------------------------
-- Helper Functions
---------------------------------------------------------------------
function getFavorites()
    local t = {}
    for i,v in pairs(g_MediaByKey) do
        if (v.is_preset == "true")  then
            table.insert(t, v) 
        end
    end
    return t
end

function BuildSimpleXml(tag, tData, escapeValue)
    local xml = ""
    
    if (tag ~= nil) then
        xml = "<" .. tag .. ">"
    end
    
    if (escapeValue) then
        for i,v in pairs(tData) do
            xml = xml .. "<" .. i .. ">" .. C4:XmlEscapeString(v) .. "</" .. i .. ">"
        end
    else
        for i,v in pairs(tData) do
            xml = xml .. "<" .. i .. ">" .. v .. "</" .. i .. ">"
        end
    end
    
    if (tag ~= nil) then
        xml = xml .. "</" .. tag .. ">"
    end
    return xml
end

function BuildListXml(tData, escapeValue, --[[optional]]elementName)
--log("BuildListXml, tData:")
--print_table(tData, "     ")
    local xml = {}
    local name = elementName or "List"

    table.insert(xml, "<" .. name .. ">")

    if (escapeValue) then
        for j,k in pairs(tData) do
            table.insert(xml, "<item>")
            for i,v in pairs(k) do
                table.insert(xml, "<" .. i .. ">" .. C4:XmlEscapeString(v) .. "</" .. i .. ">")
            end    
            table.insert(xml, "</item>")
        end    
    else
        for j,k in pairs(tData) do
            table.insert(xml, "<item>")
            for i,v in pairs(k) do
                table.insert(xml, "<" .. i .. ">" .. v .. "</" .. i .. ">")
            end    
            table.insert(xml, "</item>")
        end
    end
    table.insert(xml, "</" .. name .. ">")
    return table.concat(xml, "")
end

function DataReceivedError(idBinding, navId, seq, msg)
    local tResponse = {}
    tResponse["NAVID"] = navId
    tResponse["SEQ"] = seq
    tResponse["DATA"] = ""
    tResponse["ERROR"] = msg
    SendToProxy(idBinding, "DATA_RECEIVED", tResponse)
end

function DataReceived(idBinding, navId, seq, response)
    local data 
    if (type(response) == "table") then
        data = BuildListXml(response, true)
    else    
        data = response
    end
    
    local tResponse = {
        ["NAVID"] = navId,
        ["SEQ"] = seq,
        ["DATA"] = data,
    }
    SendToProxy(idBinding, "DATA_RECEIVED", tResponse)    
end

function SelectInternetRadio(idBinding, roomId, url, info, vol)
    local tResponse = {
        ["ROOM_ID"] = roomId,
        ["STATION_URL"] = url,
        ["QUEUE_INFO"] = info,
    }    
    if (vol ~= nil) then
        tResponse["VOLUME"] = vol    
    end    
            
    SendToProxy(idBinding, "SELECT_INTERNET_RADIO", tResponse, "COMMAND")    
end

function QueueChanged(idBinding, navId, args)
    local tResponse = {}
    if (navId ~= nil) then
        tResponse["NAVID"] = navId
    end
    tResponse["NAME"] = "QueueChanged"
    tResponse["EVTARGS"] = args
    SendToProxy(idBinding, "SEND_EVENT", tResponse, "COMMAND")    
end

function PRX_CMD.SCAN_FWD(idBinding, tParams)
end

function PRX_CMD.SCAN_REV(idBinding, tParams)
end

function PRX_CMD.PAUSE(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "pause"
                         }}))
end

function PRX_CMD.PLAY(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "play"
                         }}))
end

function PRX_CMD.OFF(idBinding, tParams)
    if not g_output then return end
    if Properties["Room Off Action"] == "Standby" then
        g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                             body = { 
                                 zone_or_output_id = g_output.output_id,
                                 control           = "stop"
                             }}))
         g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/standby", 
                              body = { output_id = g_output.output_id }}))
    elseif Properties["Room Off Action"] == "Stop" then
        g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                             body = { 
                                 zone_or_output_id = g_output.output_id,
                                 control           = "stop"
                             }}))
    elseif Properties["Room Off Action"] == "Pause" then
        g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                             body = { 
                                 zone_or_output_id = g_output.output_id,
                                 control           = "pause"
                             }}))
    end

end

function PRX_CMD.STOP(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "stop"
                         }}))
end

function PRX_CMD.SKIP_FWD(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "next"
                         }}))
end

function PRX_CMD.SKIP_REV(idBinding, tParams)
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "previous"
                         }}))
end

function PRX_CMD.REQUEST_CURRENT_MEDIA_INFO(idBinding, tParams)
    local tResponse = {
        artistname = "Artist",
        albumname  = "Album",
        titlename  = "Title",
    }
    C4:SendToProxy(idBinding, "REQUEST_CURRENT_MEDIA_INFO", tResponse)
end

function PRX_CMD.SELECT_SOURCE(idBinding, tParams)
    --C4:SendToProxy(idBinding, "SKIP_REV", { })
	outputs = ""
	for i,output in ipairs(g_zone.outputs) do
		if output ~= nil then
			outputs = outputs .. output.output_id .. " "
		end
	end
	g_added_seq = g_added_seq + 1
    local added_seq = g_added_seq
	g_added_rooms = g_added_rooms .. tParams.ROOM_ID .. " "
	C4:SetTimer(100, function()
		if added_seq == g_added_seq then
		    C4:SendToDevice(g_core.device_id, "ROON_CORE_ADD_TO_GROUP", {
				ADDED = g_added_rooms,
				SENDER = C4:RoomGetId(),
				GROUP = outputs
			})
			g_added_rooms = ""
		end
    end, false)
end

function PRX_CMD.DEVICE_DESELECTED(idBinding, tParams)
	outputs = ""
	for i,output in ipairs(g_zone.outputs) do
		if output ~= nil then
			outputs = outputs .. output.output_id .. " "
		end
	end
	g_removed_seq = g_removed_seq + 1
    local removed_seq = g_removed_seq
	g_removed_rooms = g_removed_rooms .. tParams.idRoom .. " "
	C4:SetTimer(100, function()
		log("deselected debounce, seq: " .. removed_seq .. " g_seq: " .. g_removed_seq .. " rooms: " .. g_removed_rooms)
		if removed_seq == g_removed_seq then
		    C4:SendToDevice(g_core.device_id, "ROON_CORE_REMOVE_FROM_GROUP", {
				REMOVED = g_removed_rooms,
				SENDER = C4:RoomGetId(),
				GROUP = outputs
			})
			g_removed_rooms = ""
		end
    end, false)
end

function PRX_CMD.CONNECT_INPUT(idBinding, tParams)
end

function PRX_CMD.CONNECT_OUTPUT(idBinding, tParams)
end

function PRX_CMD.SET_INPUT(idBinding, tParams)
end

function PRX_CMD.GET_AUDIO_PATH(idBinding, tParams)
end

function PRX_CMD.QUEUE_MEDIA_INFO_UPDATED(idBinding, tParams)
end

function PlayPause()
    if not g_output then return end
    g_moo_bridge:request(Moo.json_message({name = "com.roonlabs.transport:2/control", 
                         body = { 
                             zone_or_output_id = g_output.output_id,
                             control           = "playpause"
                         }}))
end
      
---------------------------------------------------------------------
-- Timer Handling
---------------------------------------------------------------------
function broadcast_dashboard(force)
    if not g_output then return end
    local options = { }

    if g_zone.is_previous_allowed  then table.insert(options, "SkipRev") end
    if g_zone.is_pause_allowed     then 
        table.insert(options, "Pause")   
    elseif g_zone.is_play_allowed then 
        table.insert(options, "Play")    
    else
        table.insert(options, "Stop")    
    end
    if g_zone.is_next_allowed      then table.insert(options, "SkipFwd") end

    local new_dashboard = table.concat(options, " ")

    if force or new_dashboard ~= g_last_dashboard then
        BroadcastEvent(MEDIA_SERVICE_BINDING, "DashboardChanged", { Items   = new_dashboard })
        g_last_dashboard = new_dashboard
    else
        --print("NOT BROADCASTING DASH " .. new_dashboard)
    end
end

function UpdateMediaInfo(line1, line2, line3, line4, imageurl)
        if line1 == last_line1 and
           line2 == last_line2 and
           line3 == last_line3 and
           line4 == last_line4 and
           imageurl == last_imageurl then
           return
       end
       last_line1    = line1 
       last_line2    = line2 
       last_line3    = line3 
       last_line4    = line4 
       last_imageurl = imageurl 

        local tParams = { }
        tParams["ROOMID"] = roomId
        tParams["ROOM_ID"] = roomId
        SendToProxy(MEDIA_SERVICE_BINDING, "SELECT_DEVICE", tParams, "COMMAND")	

        tParams = {
            ["LINE1"] = line1,
            ["LINE2"] = line2,
            ["LINE3"] = line3,
            ["LINE4"] = line4, 
            ["IMAGEURL"] = imageurl and C4:Base64Encode(imageurl) or nil,
            ["ROOMID"] = C4:RoomGetId(),
            ["ROOM_ID"] = C4:RoomGetId(),
            ["MEDIATYPE"] = "secondary",
            ["MERGE"] = "False",
        }            
        SendToProxy(MEDIA_SERVICE_BINDING, "UPDATE_MEDIA_INFO", tParams, "COMMAND", true)
end

function force_refresh_data()
    last_line1    = nil
    last_line2    = nil
    last_line3    = nil
    last_line4    = nil
    last_imageurl = nil
    last_volume   = -1
    last_mute     = nil
    if g_zone then
        ev_zone_changed(g_zone)
    end
    broadcast_dashboard(true)
    broadcast_queue(true)
end

function ev_output_changed(output)
    if g_output ~= output then return end

    if output.volume then
        local range  = output.volume.max - output.volume.min
        local prop   = (output.volume.value - output.volume.min) / range
        local volume = prop*100

        if volume ~= last_volume then
            C4:SendToProxy(AMPLIFIER_BINDING, "VOLUME_LEVEL_CHANGED", { OUTPUT = 4001, LEVEL = volume })
            last_volume = volume
        end

        if last_mute ~= output.volume.is_muted then
            C4:SendToProxy(AMPLIFIER_BINDING, "MUTE_CHANGED", { OUTPUT = 4001, MUTE = output.volume.is_muted and "TRUE" or "FALSE" })
            last_mute = output.volume.is_muted 
        end
    end
	
	if g_output then
        C4:SendToDevice(g_core.device_id, "ROON_CORE_SET_ROOM_OUTPUT", {
            SENDER = C4:GetDeviceID(),
            ROOMID = C4:RoomGetId(),
            OUTPUTID = g_output.output_id
        })
    else
        C4:SendToDevice(g_core.device_id, "ROON_CORE_SET_ROOM_OUTPUT", {
            SENDER = C4:GetDeviceID(),
            ROOMID = C4:RoomGetId(),
            OUTPUTID = nil
        })
    end
end

function ev_zone_changed(zone)
    if g_zone ~= zone then return end
    --log("zone changed");
    local tParams = { }
    broadcast_dashboard()

    if zone.now_playing then
        UpdateMediaInfo(zone.now_playing.two_line.line1 or "",
                        zone.now_playing.two_line.line2 or "",
                        "",
                        "",
                        get_image_url(zone.now_playing.image_key, 512, true))
        UpdateProgress(zone.now_playing.seek_position, zone.now_playing.length)
    else
        UpdateMediaInfo("", "", "", "", nil)
        UpdateProgress(nil, nil)
    end

    ev_output_changed(g_output)
end

function format_time(t)
    if t == nil then return nil end
    local ret = ""
    if t > 3600 then
        ret = ret .. tostring(math.floor(t/3600)) .. ":" 
        t = t % 3600
    end
    if t > 60 then
        ret = ret .. tostring(math.floor(t/60)) .. ":" 
        t = t % 60
    end
    if ret == "" then
        ret = "0:"
    end
    if t >= 10 then
        ret = ret .. tostring(math.floor(t))
    else
        ret = ret .. "0" .. tostring(math.floor(t))
    end
    return ret
end

function UpdateProgress(seek, length)
    if last_length == length and last_seek == seek then return end
    last_length = length
    last_seek   = seek
    local args = { }

    if seek ~= nil then 
        args.offset = seek 
        args.label  = format_time(seek)
    end
    if length ~= nil then 
        args.length = length 
    end

    BroadcastEvent(MEDIA_SERVICE_BINDING, "ProgressChanged", args)
end

---------------------------------------------------------------------
-- Property Handling
---------------------------------------------------------------------
function OnPropertyChanged(strProperty)
    log("OnPropertyChanged(" .. strProperty .. ") changed to: " .. Properties[strProperty])
    
    if strProperty ~= "Status" then
        if update_properties ~= nil then update_properties() end
    end
end

------------------- Initialization ---------------------
function OnDriverInit()
    -- room uses the proxy for lookups - use the proxy device id for items
    local proxyDev = C4:GetProxyDevices()
    if (proxyDev) then
        C4:MediaSetDeviceContext(proxyDev)
    end

    log("---[ Zone Driver Init ]---");
end    

function OnDriverUpdate()
    -- room uses the proxy for lookups - use the proxy device id for items
    local proxyDev = C4:GetProxyDevices()
    if (proxyDev) then
        C4:MediaSetDeviceContext(proxyDev)
    end
end    

for k,v in pairs(Properties) do
    OnPropertyChanged(k)
end

-- Given a string like 'My zone <abcdeabcdeabcdea>', extracts the abcdeabcdeabcdea part. 
-- Given nil, "", or other nonconfirming string returns nil
function extract_angle_bracketed_id(settings_name)
    if not settings_name or settings_name == "" then return nil end
    return string.match(settings_name, "<([^>]+)>")
end

function update_properties() 
    if g_failure then
        C4:UpdateProperty("Status", g_failure)
        return
    end

    local core_settings_names = { } 
    local selected_core_id = extract_angle_bracketed_id(Properties["Core"])
    local first_core       = nil
    local selected_core    = nil

    ---[ Core Selection ]---------------------------------------------
    for deviceid,core in pairs(g_cores) do
        if core.settings_name then 
            if not first_core then first_core = core end

            table.insert(core_settings_names, core.settings_name)

            if core.core_id == selected_core_id then
                selected_core = core
            end
        end
    end

    local core_settings_names_string = table.concat(core_settings_names, ",")
    if core_settings_names_string ~= last_core_settings_names then
        C4:UpdatePropertyList("Core", core_settings_names_string)
        last_core_settings_names = core_settings_names_string
        last_core_setting        = nil
    end

    if selected_core then
        if last_core_setting ~= selected_core.settings_name then
            C4:UpdateProperty("Core", selected_core.settings_name)
            last_core_setting = selected_core.settings_name
        end
    elseif not selected_core_id and first_core then
        if last_core_setting ~= first_core.settings_name then
            C4:UpdateProperty("Core", first_core.settings_name)
            last_core_setting = first_core.settings_name
        end
    end

    if g_core ~= selected_core then
        g_core = selected_core

        if g_moo_bridge and g_moo_bridge.core ~= g_core then
            g_moo_bridge = nil
        end

        if g_core then 
            if not g_moo_bridge then 
                g_moo_bridge = MooBridge:new(g_core)
            end
            g_moo_bridge:change_state(selected_core.moo_state)
        end
    end

    ---[ Output Selection ]-------------------------------------------
    local output_settings_names = { } 
    local selected_output_id = extract_angle_bracketed_id(Properties["Zone"])
    local selected_output    = nil
    local selected_zone      = nil
    local outputs_visited    = { }

    if not g_core then g_zones = { } end

    for k1,zone in pairs(g_zones) do
        for k2,output in pairs(zone.outputs) do
            if not outputs_visited[output.output_id] then 
                output.settings_name = output.display_name .. " <" .. output.output_id .. ">"
                table.insert(output_settings_names, output.settings_name)
                if output.output_id == selected_output_id then
                    selected_output = output
                    selected_zone   = zone
                end
                outputs_visited[output.output_id] = true
            end
        end
    end

    if selected_output_id and not selected_output then
        --table.insert(output_settings_names, Properties["Zone"])
    end

    local output_settings_names_string = table.concat(output_settings_names, ",")
    if last_output_settings_names ~= output_settings_names_string then
        C4:UpdatePropertyList("Zone", output_settings_names_string)
        last_output_settings_names = output_settings_names_string
        last_zone_setting          = nil
    end

    if selected_output then
        if last_zone_setting ~= selected_output.settings_name then
            C4:UpdateProperty("Zone", selected_output.settings_name)
            last_zone_setting = selected_output.settings_name
        end
    end

    local old_zone_id   = g_zone and g_zone.zone_id or "none"

    g_output = selected_output
    g_zone   = selected_zone 

    local new_zone_id   = g_zone and g_zone.zone_id or "none"

    if old_zone_id ~= new_zone_id then
        force_refresh_data()
    end

    if g_output then
        C4:UpdateProperty("Status", "Ready")
    elseif g_core and selected_output_id then 
        C4:UpdateProperty("Status", "Waiting for Zone")
    elseif g_core then
        C4:UpdateProperty("Status", "Please Select a Zone")
    elseif #g_cores == 0 then
        C4:UpdateProperty("Status", "Waiting for Core")
    else 
        C4:UpdateProperty("Status", "Please Select a Core")
    end

    for k,zone in pairs(g_zones) do
        if zone.dirty then
            zone.dirty = false
            ev_zone_changed(zone)
        end
    end
end

function OnDriverLateInit()
    log("---[ Zone Driver Late Init ]---");
    C4:SetTimer(1000, function()
        foreach_core(function(core) 
            C4:SendToDevice(core.device_id, "ROON_CORE_REFRESH_ZONES", { SENDER = C4:GetDeviceID() })
        end)
        refresh_cores()
        update_properties()
    end, false)
end

-- cb_core(device_id, driver_name)
function foreach_core(cb_core) 
    local g_cores = C4:GetDevicesByC4iName("Roon Core.c4z")
    if g_cores ~= nil then
        for devid,drivername in pairs(g_cores) do
            cb_core({ 
                device_id    = devid, 
                driver_name = drivername
            })
        end
    end
end

function ev_roon_api_zone_updated(tParams)
    if not g_core                        then return end
    if g_core.core_id ~= tParams.CORE_ID then return end

    local zone = json.decode(tParams.ZONE)
	local seek_only = tParams.SEEK_ONLY == "true"

    local found = false
     for idx,existing in ipairs(g_zones) do
         if existing.zone_id == zone.zone_id then
			 --print_table(existing)
			 --log("seek only: " .. seek_only)
			 --log("existing.now_playing: " .. existing.now_playing)
			 --print_table(existing.now_playing)
			 if not seek_only then
				 g_zones[idx] = zone
				 zone.dirty = true
			 else
				 existing.now_playing.seek_position = zone.seek_position
				 existing.dirty = true
			 end
			 found = true
         end
     end
     if not found then
         table.insert(g_zones, zone)
     end
     update_properties()
end

function ev_roon_api_zone_removed(tParams)
    if not g_core                        then return end
    if g_core.core_id ~= tParams.CORE_ID then return end
	local new_zones = { } 
	local new_queues = { }
	for idx,existing in ipairs(g_zones) do
		if tParams.ZONE_ID ~= existing.zone_id then
			table.insert(new_zones, existing)
			new_queues[exist.zone_id] = g_zone_queues[existing.zone_id]
		end
	end
	g_zones = new_zones
	g_zone_queues = new_queues
	update_properties()
end

function ev_roon_api_queue_updated(tParams)
    if not g_core                        then return end
    if g_core.core_id ~= tParams.CORE_ID then return end
	log("ev_roon_api_queue_updated, params:")
	--print_table(tParams)
	local queue = json.decode(tParams.QUEUE)
	g_zone_queues[tParams.ZONE_ID] = queue
	if g_core and tParams.ZONE_ID == g_zone.zone_id then
		broadcast_queue()
	end
end

function OnDriverDestroyed()
    foreach_core(function(core) 
        C4:SendToDevice(core.device_id, "ROON_CORE_REFRESH_ZONES", { SENDER = C4:GetDeviceID() })
    end)
end

function refresh_cores()
    local old_cores = g_cores
    g_cores = { }
    foreach_core(function(core)
        local core = old_cores[core.device_id] or { device_id = core.device_id }
        C4:SendToDevice(core.device_id, "ROON_CORE_GET_INFO", { SENDER = C4:GetDeviceID() })
    end)
end

function OnBindingChanged(idBinding, strclass, bIsBound) 
    log("OnBindingChanged " .. tostring(idBinding) .. " " .. tostring(strclass) .. " " .. tostring(bIsBound))
end

function ExecuteCommand(strCommand, tParams)
    if strCommand == "LUA_ACTION" then
       if tParams ~= nil then
          for cmd,cmdv in pairs(tParams)do
             if cmd == "ACTION" then
                if cmdv == "Reconnect" then
                    force_disconnect();
                    try_connect()
                elseif cmdv == "Disconnect" then
                    force_disconnect();
                end
             end
          end
       end

    elseif strCommand == "ROON_CORE_CREATED" or strCommand == "ROON_CORE_DESTROYED" then
        C4:SetTimer(500, refresh_cores, false)

    elseif strCommand == "ROON_API_ZONE_UPDATED" then
        ev_roon_api_zone_updated(tParams)

    elseif strCommand == "ROON_API_ZONE_REMOVED" then
        ev_roon_api_zone_removed(tParams)
		
	elseif strCommand == "ROON_API_QUEUE_UPDATED" then
		ev_roon_api_queue_updated(tParams)

    elseif strCommand == "ROON_CORE_INFO" then
        local core = g_cores[tParams.DEVICE_ID] or { device_id = tParams.DEVICE_ID }

        core.core_id         = tParams.CORE_ID
        core.display_name    = tParams.DISPLAY_NAME
        core.display_version = tParams.DISPLAY_VERSION
        core.core_state      = tParams.CORE_STATE
        core.moo_state       = tParams.MOO_STATE
        core.http_ip         = tParams.HTTP_IP
        core.http_port       = tParams.HTTP_PORT

        if core.core_id and core.display_name then
            core.settings_name = core.display_name .. " <" .. core.core_id .. ">"
        else
            core.settings_name = nil
        end
        
        g_cores[core.device_id] = core

        update_properties()

    elseif strCommand == "ROON_MOO_BRIDGE_RESPONSE" then
        if g_moo_bridge then
            g_moo_bridge:dispatch_response(tParams)
        end
	elseif strCommand == "PLAY" then
		PRX_CMD.PLAY(nil, nil)
	elseif strCommand == "PAUSE" then
		PRX_CMD.PAUSE(nil, nil)
	elseif strCommand == "PLAYPAUSE" then
		PlayPause()
	elseif strCommand == "SKIP_FWD" then
		PRX_CMD.TransportSkipFwdButton(nil, nil)
	elseif strCommand == "SKIP_REV" then
		PRX_CMD.TransportSkipRevButton(nil, nil)
	elseif strCommand == "STOP" then
		PRX_CMD.STOP(nil, nil)
    end
end

log("---[ Loaded Zone Driver ]---");
