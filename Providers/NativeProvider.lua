local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local function QueryNative(itemLink, itemId)
    if not itemId or not PCF_DB or not PCF_DB.prices then
        return nil
    end
    local data = PCF_DB.prices[itemId]
    if data and data.minBuyout and data.minBuyout > 0 then
        local label = "Native AH Scan"
        local timestamp = data.lastUpdated or 0
        if data.source == "PCF Mesh" or data.source == "Mesh" then
            label = "PCF Mesh"
        elseif data.source == "PCF Sniff" or data.source == "Sniff" then
            label = "PCF Sniff"
        elseif PCF_DB.lastFullScan and PCF_DB.lastFullScan > 0 then
            timestamp = math.max(timestamp, PCF_DB.lastFullScan)
        end
        local ageStr = (PCF.Formatter and PCF.Formatter.FormatRelativeAge and PCF.Formatter.FormatRelativeAge(timestamp))
            or string.format("%dm ago", math.max(0, math.floor((time() - timestamp) / 60)))
        local sourceTag = string.format("%s (%s)", label, ageStr)
        return data.minBuyout, sourceTag
    end
    return nil
end

PCF.ProviderRegistry.Register("Native", 30, QueryNative)
