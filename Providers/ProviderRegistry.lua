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

local EXTERNAL_PROVIDER_NAMES = {
    TradeSkillMaster = true,
    Auctionator = true,
}

local EXTERNAL_FRESH_SECONDS = 21600 -- 6 hours

function PCF.ProviderRegistry.Register(name, priority, queryFunc)
    for i = #providers, 1, -1 do
        if providers[i].name == name then
            table.remove(providers, i)
        end
    end
    table.insert(providers, { name = name, priority = priority, query = queryFunc })
    table.sort(providers, function(a, b) return a.priority < b.priority end)
end

local function CacheExternalProviderPrice(providerName, itemId, price, externalTimestamp, externalCount)
    if not EXTERNAL_PROVIDER_NAMES[providerName] or not itemId or not price or price <= 0 then
        return
    end
    if not PCF_DB or not PCF_DB.prices then
        return
    end
    if PCF_DB.settings and PCF_DB.settings.enableSniffExternalAddons == false then
        return
    end

    local now = time()
    local hasValidExternalTs = type(externalTimestamp) == "number" and externalTimestamp > 0 and externalTimestamp <= (now + 60)
    local existing = PCF_DB.prices[itemId]
    local itemTimestamp = hasValidExternalTs
        and math.floor(externalTimestamp)
        or (existing and type(existing.lastUpdated) == "number" and existing.lastUpdated > 0 and existing.lastUpdated)
        or now
    local flooredPrice = math.floor(price)
    local hasValidCount = type(externalCount) == "number" and externalCount > 0
    local resolvedCount = hasValidCount
        and math.floor(externalCount)
        or (existing and type(existing.count) == "number" and existing.count > 0 and existing.count)
        or 1

    if not existing
        or existing.minBuyout ~= flooredPrice
        or (hasValidCount and existing.count ~= resolvedCount)
        or (hasValidExternalTs and existing.lastUpdated ~= itemTimestamp)
        or (now - (existing.lastUpdated or 0)) >= 3600
    then
        if existing then
            existing.minBuyout = flooredPrice
            existing.minBid = flooredPrice
            existing.lastUpdated = itemTimestamp
            existing.count = resolvedCount
            existing.source = "PCF Sniff"
        else
            PCF_DB.prices[itemId] = {
                minBuyout = flooredPrice,
                minBid = flooredPrice,
                lastUpdated = itemTimestamp,
                count = resolvedCount,
                source = "PCF Sniff",
            }
        end

        if hasValidExternalTs and (now - itemTimestamp) <= EXTERNAL_FRESH_SECONDS then
            if PCF.MeshSync and PCF.MeshSync.MarkDirty then
                PCF.MeshSync.MarkDirty(itemId)
            end
        end
    end
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

PCF.ProviderRegistry.GetVendorPrice = GetVendorPrice

function PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)
    local preferred = PCF_DB and PCF_DB.settings and PCF_DB.settings.preferredProvider
    local preferredName = preferred and PREFERRED_MAP[preferred:upper()]

    if preferredName then
        for _, provider in ipairs(providers) do
            if provider.name == preferredName then
                local price, source, timestamp, count = provider.query(itemLink, itemId)
                if price and price > 0 then
                    CacheExternalProviderPrice(provider.name, itemId, price, timestamp, count)
                    return price, source
                end
            end
        end
    end

    for _, provider in ipairs(providers) do
        local price, source, timestamp, count = provider.query(itemLink, itemId)
        if price and price > 0 then
            CacheExternalProviderPrice(provider.name, itemId, price, timestamp, count)
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
