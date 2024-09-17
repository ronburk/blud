local debug = {}

function debug.dump(o)

    if type(o) == 'table' then
        local s = '{ '
        for k,v in pairs(o) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            if v ~= "__index" then
                s = s .. '['..k..'] = ' .. dump(v) .. ','
            end
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

return debug
