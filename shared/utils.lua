local utils = { }

function string:split(sSeparator, nMax, bRegexp)
   assert(sSeparator ~= '')
   assert(nMax == nil or nMax >= 1)

   local aRecord = {}

   if self:len() > 0 then
      local bPlain = not bRegexp
      nMax = nMax or -1

      local nField, nStart = 1, 1
      local nFirst,nLast = self:find(sSeparator, nStart, bPlain)
      while nFirst and nMax ~= 0 do
         aRecord[nField] = self:sub(nStart, nFirst-1)
         nField = nField+1
         nStart = nLast+1
         nFirst,nLast = self:find(sSeparator, nStart, bPlain)
         nMax = nMax-1
      end
      aRecord[nField] = self:sub(nStart)
   end

   return aRecord
end

function table.map(func, tbl)
    local newtbl = {}
    for i,v in pairs(tbl) do
        newtbl[i] = func(v)
    end
    return newtbl
end
 
function string.trim(self)
    return self:match"^%s*(.*)":match"(.-)%s*$"
end

function string.starts(str,start)
    return string.sub(str,1,string.len(start))==start
end

function utils.parse_proxy_command_args(tParams)
    local args = {}
    local parsedArgs = C4:ParseXml(tParams["ARGS"])
    for i,v in pairs(parsedArgs.ChildNodes) do
            args[v.Attributes["name"]] = v.Value
    end
    return args
end

return utils
