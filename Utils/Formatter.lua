local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Formatter = {}

function PCF.Formatter.FormatMoney(copper)
    if not copper or copper <= 0 then return "0c" end
    copper = math.floor(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100

    local parts = {}
    if g > 0 then table.insert(parts, string.format("%dg", g)) end
    if s > 0 then table.insert(parts, string.format("%ds", s)) end
    if c > 0 or #parts == 0 then table.insert(parts, string.format("%dc", c)) end
    return table.concat(parts, " ")
end

function PCF.Formatter.FormatTooltipMoney(copper)
    if not copper or copper <= 0 then return "??" end
    copper = math.floor(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100

    local parts = {}
    if g > 0 then table.insert(parts, string.format("%dg", g)) end
    if s > 0 then table.insert(parts, string.format("%ds", s)) end
    if c > 0 or #parts == 0 then table.insert(parts, string.format("%dc", c)) end
    return table.concat(parts, "")
end
