local M = {}

M.array_append    = function(array, more)
    if not (type(array) == "table" and type(more) == "table") then
        error("Bad call to array_append")
    end
    for _, element in ipairs(more) do
        table.insert(array, element)
    end
end

return M
