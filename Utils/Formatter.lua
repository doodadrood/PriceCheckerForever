local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Formatter = {}

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

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
    if _G.GetCoinTextureString then
        return _G.GetCoinTextureString(copper)
    end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100

    local parts = {}
    if g > 0 then table.insert(parts, string.format("%d%s", g, GOLD_ICON)) end
    if s > 0 then table.insert(parts, string.format("%d%s", s, SILVER_ICON)) end
    if c > 0 or #parts == 0 then table.insert(parts, string.format("%d%s", c, COPPER_ICON)) end
    return table.concat(parts, " ")
end

function PCF.Formatter.FormatRelativeAge(timestamp, nowOverride)
    if type(timestamp) ~= "number" then
        return "0m ago"
    end
    local now = nowOverride or time()
    local ageMin = math.max(0, math.floor((now - timestamp) / 60))
    if ageMin >= 60 then
        local hours = math.floor(ageMin / 60)
        local mins = ageMin % 60
        if mins > 0 then
            return string.format("%dh %dm ago", hours, mins)
        end
        return string.format("%dh ago", hours)
    end
    return string.format("%dm ago", ageMin)
end
