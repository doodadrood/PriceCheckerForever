local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local function QueryAuctionator(itemLink, itemId)
    if not Auctionator or not Auctionator.API or not Auctionator.API.v1 then
        return nil
    end

    local api = Auctionator.API.v1
    local price = nil

    if itemLink and api.GetAuctionPriceByItemLink then
        local ok, result = pcall(api.GetAuctionPriceByItemLink, "PriceCheckerForever", itemLink)
        if ok and result and result > 0 then
            price = result
        end
    end

    if not price and itemId and api.GetAuctionPriceByItemID then
        local ok, result = pcall(api.GetAuctionPriceByItemID, "PriceCheckerForever", itemId)
        if ok and result and result > 0 then
            price = result
        end
    end

    if price and price > 0 then
        return price, "Auctionator"
    end
    return nil
end

PCF.ProviderRegistry.Register("Auctionator", 20, QueryAuctionator)
