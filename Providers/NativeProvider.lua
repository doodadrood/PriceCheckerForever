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
        local sourceTag = string.format("Native AH Scan (%dh ago)", ageHours)
        return data.minBuyout, sourceTag
    end
    return nil
end

PCF.ProviderRegistry.Register("Native", 30, QueryNative)
