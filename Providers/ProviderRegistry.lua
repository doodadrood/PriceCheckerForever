local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.ProviderRegistry = {}

local providers = {}

local PREFERRED_MAP = {
    TSM = "TradeSkillMaster",
    TRADESKILLMASTER = "TradeSkillMaster",
    AUCTIONATOR = "Auctionator",
    NATIVE = "Native",
}

function PCF.ProviderRegistry.Register(name, priority, queryFunc)
    for i = #providers, 1, -1 do
        if providers[i].name == name then
            table.remove(providers, i)
        end
    end
    table.insert(providers, { name = name, priority = priority, query = queryFunc })
    table.sort(providers, function(a, b) return a.priority < b.priority end)
end

local function GetVendorPrice(itemLink, itemId)
    local target = itemId or itemLink
    if not target then return nil end

    if C_Item and C_Item.GetItemInfo then
        local vendorPrice = select(11, C_Item.GetItemInfo(target))
        if vendorPrice and vendorPrice > 0 then
            return vendorPrice
        end
    end

    if GetItemInfo then
        local vendorPrice = select(11, GetItemInfo(target))
        if vendorPrice and vendorPrice > 0 then
            return vendorPrice
        end
    end

    return nil
end

function PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)
    local preferred = PCF_DB and PCF_DB.settings and PCF_DB.settings.preferredProvider
    local preferredName = preferred and PREFERRED_MAP[preferred:upper()]

    if preferredName then
        for _, provider in ipairs(providers) do
            if provider.name == preferredName then
                local price, source = provider.query(itemLink, itemId)
                if price and price > 0 then
                    return price, source
                end
            end
        end
    end

    for _, provider in ipairs(providers) do
        local price, source = provider.query(itemLink, itemId)
        if price and price > 0 then
            return price, source
        end
    end

    return nil, nil
end

function PCF.ProviderRegistry.ResolvePrice(itemLink, itemId)
    local ahPrice, ahSource = PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)
    if ahPrice and ahPrice > 0 then
        return ahPrice, ahSource
    end

    -- Fallback: Vendor Sell Price (Priority 40)
    local vendorPrice = GetVendorPrice(itemLink, itemId)
    if vendorPrice and vendorPrice > 0 then
        return vendorPrice, "Vendor Base"
    end

    return nil, "No Data"
end
