local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local function QueryNative(itemLink, itemId)
    if not itemId or not PCF_DB or not PCF_DB.prices then
        return nil
    end
    local data = PCF_DB.prices[itemId]
    if data and data.minBuyout and data.minBuyout > 0 then
        local ageHours = math.max(0, math.floor((time() - (data.lastUpdated or 0)) / 3600))
        local label = "Native AH Scan"
        if data.source == "PCF Mesh" or data.source == "Mesh" then
            label = "PCF Mesh"
        elseif data.source == "PCF Sniff" or data.source == "Sniff" then
            label = "PCF Sniff"
        end
        local sourceTag = string.format("%s (%dh ago)", label, ageHours)
        return data.minBuyout, sourceTag
    end
    return nil
end

PCF.ProviderRegistry.Register("Native", 30, QueryNative)
