local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Formatter = {}

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function IsFinitePositiveNumber(val)
    return type(val) == "number" and val > 0 and val < math.huge
end

local function FormatCoinParts(copper, goldSuffix, silverSuffix, copperSuffix)
    local g = math.floor(copper / 10000) + 0
    local s = math.floor((copper % 10000) / 100) + 0
    local c = (copper % 100) + 0

    local parts = {}
    -- %.0f avoids WoW Lua's signed 32-bit %d overflow for large gold stacks
    if g > 0 then table.insert(parts, string.format("%.0f%s", g, goldSuffix)) end
    if s > 0 then table.insert(parts, string.format("%d%s", s, silverSuffix)) end
    if c > 0 or #parts == 0 then table.insert(parts, string.format("%d%s", c, copperSuffix)) end
    return table.concat(parts, " ")
end

function PCF.Formatter.FormatMoney(copper)
    if not IsFinitePositiveNumber(copper) then return "0c" end
    return FormatCoinParts(math.floor(copper), "g", "s", "c")
end

function PCF.Formatter.FormatTooltipMoney(copper)
    if not IsFinitePositiveNumber(copper) then return "??" end
    copper = math.floor(copper)
    if _G.GetCoinTextureString then
        local ok, formatted = pcall(_G.GetCoinTextureString, copper)
        if ok and type(formatted) == "string" and formatted ~= "" then
            return formatted
        end
    end
    return FormatCoinParts(copper, GOLD_ICON, SILVER_ICON, COPPER_ICON)
end

function PCF.Formatter.FormatRelativeAge(timestamp, nowOverride)
    if type(timestamp) ~= "number" or timestamp ~= timestamp or timestamp >= math.huge or timestamp <= -math.huge then
        return "0m ago"
    end
    local now = nowOverride or time()
    local ageMin = math.max(0, math.floor((now - timestamp) / 60)) + 0
    if ageMin >= 60 then
        local hours = math.floor(ageMin / 60) + 0
        local mins = (ageMin % 60) + 0
        if mins > 0 then
            return string.format("%.0fh %dm ago", hours, mins)
        end
        return string.format("%.0fh ago", hours)
    end
    return string.format("%dm ago", ageMin)
end
