local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local function QueryTSM(itemLink, itemId)
    if not TSM_API or not TSM_API.GetCustomPriceValue then
        return nil
    end

    local price = nil
    if itemLink then
        local ok, result = pcall(TSM_API.GetCustomPriceValue, "DBMarket", itemLink)
        if ok and result and result > 0 then
            price = result
        end
    end

    if not price and itemId then
        local ok, result = pcall(TSM_API.GetCustomPriceValue, "DBMarket", "i:" .. itemId)
        if ok and result and result > 0 then
            price = result
        end
    end

    if price and price > 0 then
        return price, "TSM DBMarket"
    end
    return nil
end

PCF.ProviderRegistry.Register("TradeSkillMaster", 10, QueryTSM)
