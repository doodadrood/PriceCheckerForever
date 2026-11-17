local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local function FindAuctionatorDBEntry(dbTable, targetId)
    if type(dbTable) ~= "table" or not targetId then
        return nil
    end
    local strKey = tostring(targetId)
    local direct = dbTable[strKey] or dbTable[targetId]
    if type(direct) == "table" and type(direct.a) == "table" then
        return direct
    end
    for k, v in pairs(dbTable) do
        if k ~= "__dbversion" and type(v) == "table" then
            local nested = v[strKey] or v[targetId]
            if type(nested) == "table" and type(nested.a) == "table" then
                return nested
            end
        end
    end
    return nil
end

local function GetAuctionatorTimestampAndCount(itemLink, itemId)
    local targetId = itemId
    if not targetId and type(itemLink) == "string" then
        local matchId = itemLink:match("item:(%d+)")
        targetId = matchId and tonumber(matchId)
    end

    local now = time()
    local lastScanTs = 0
    local savedState = (Auctionator and type(Auctionator.SavedState) == "table" and Auctionator.SavedState)
        or (type(_G.AUCTIONATOR_SAVEDVARS) == "table" and _G.AUCTIONATOR_SAVEDVARS)
    if savedState then
        local browseTs = tonumber(savedState.TimeOfLastBrowseScan) or 0
        local repTs = tonumber(savedState.TimeOfLastReplicateScan) or 0
        lastScanTs = math.max(browseTs, repTs)
    end

    local ageDays = nil
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api then
        if itemLink and type(api.GetAuctionAgeByItemLink) == "function" then
            local ok, val = pcall(api.GetAuctionAgeByItemLink, "PriceCheckerForever", itemLink)
            if ok and type(val) == "number" and val >= 0 then
                ageDays = val
            end
        end
        if ageDays == nil and targetId and type(api.GetAuctionAgeByItemID) == "function" then
            local ok, val = pcall(api.GetAuctionAgeByItemID, "PriceCheckerForever", targetId)
            if ok and type(val) == "number" and val >= 0 then
                ageDays = val
            end
        end
    end

    local timestamp = nil
    if type(ageDays) == "number" and ageDays > 0 then
        local baseTs = (lastScanTs > 0) and math.min(lastScanTs, now) or now
        timestamp = math.min(baseTs, now - (ageDays * 86400))
    elseif lastScanTs > 0 then
        timestamp = math.min(lastScanTs, now)
    end
    if timestamp and timestamp <= 0 then
        timestamp = nil
    end

    local count = nil
    if targetId then
        local entry = FindAuctionatorDBEntry(_G.AUCTIONATOR_PRICE_DATABASE, targetId)
        if not entry and Auctionator and type(Auctionator.Database) == "table" then
            entry = FindAuctionatorDBEntry(Auctionator.Database.db, targetId)
        end
        if entry and type(entry.a) == "table" then
            local latestDay = nil
            for dayKey, qty in pairs(entry.a) do
                local dayNum = tonumber(dayKey)
                local qtyNum = tonumber(qty)
                if dayNum and qtyNum and qtyNum > 0 then
                    if not latestDay or dayNum > latestDay then
                        latestDay = dayNum
                        count = math.floor(qtyNum)
                    end
                end
            end
        end
    end

    return timestamp, count
end

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
        local timestamp, count = GetAuctionatorTimestampAndCount(itemLink, itemId)
        local sourceTag = "Auctionator"
        if type(timestamp) == "number" and timestamp > 0 then
            local ageStr = (PCF.Formatter and PCF.Formatter.FormatRelativeAge and PCF.Formatter.FormatRelativeAge(timestamp))
                or string.format("%dm ago", math.max(0, math.floor((time() - timestamp) / 60)))
            if ageStr then
                sourceTag = string.format("Auctionator (%s)", ageStr)
            end
        end
        return price, sourceTag, timestamp, count
    end
    return nil
end

PCF.ProviderRegistry.Register("Auctionator", 20, QueryAuctionator)
