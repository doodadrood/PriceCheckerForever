local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local function ValidateTimestamp(ts, now)
    if type(ts) ~= "number" then return nil end
    now = now or time()
    -- Valid Unix epoch timestamp (standard WoW environment, after Jan 2010)
    if ts > 1262304000 and ts <= (now + 600) then
        return ts
    end
    -- Support mock or non-epoch environments where time() starts small
    if now < 1262304000 and (now - ts) >= 0 and (now - ts) < (86400 * 365) then
        return ts
    end
    -- Elapsed duration in seconds (e.g. 1 to 30 days)
    if ts > 0 and ts < (86400 * 30) and (now - ts) >= 0 then
        return now - ts
    end
    return nil
end

local function GetTSMTimestamp(itemLink, itemId)
    local targetId = itemId
    if not targetId and itemLink and type(itemLink) == "string" then
        local matchId = itemLink:match("item:(%d+)")
        targetId = matchId and tonumber(matchId)
    end

    local now = time()

    -- 1. Check TSM_API functions if exposed
    if _G.TSM_API then
        if type(_G.TSM_API.GetPriceTimestamp) == "function" then
            local target = itemLink or (targetId and ("i:" .. tostring(targetId)))
            if target then
                local ok, val = pcall(_G.TSM_API.GetPriceTimestamp, "DBMarket", target)
                local valid = ok and ValidateTimestamp(val, now)
                if valid then return valid end
            end
        end
        if type(_G.TSM_API.GetScanTime) == "function" then
            local ok, val = pcall(_G.TSM_API.GetScanTime, targetId or itemLink)
            local valid = ok and ValidateTimestamp(val, now)
            if valid then return valid end
        end
        if type(_G.TSM_API.GetLastScanTime) == "function" then
            local ok, val = pcall(_G.TSM_API.GetLastScanTime, targetId or itemLink)
            local valid = ok and ValidateTimestamp(val, now)
            if valid then return valid end
        end
    end

    -- 2. Check TSM core object (global or AceAddon)
    local tsmObj = _G.TSM or _G.TradeSkillMaster
    if not tsmObj and _G.LibStub and type(_G.LibStub.GetLibrary) == "function" then
        local ace = _G.LibStub("AceAddon-3.0", true)
        if ace and ace.GetAddon then
            local ok, addon = pcall(ace.GetAddon, ace, "TradeSkillMaster")
            if ok and addon then
                tsmObj = addon
            end
        end
    end

    if tsmObj then
        -- Direct method: TSM:GetLastScanTime(itemId)
        if type(tsmObj.GetLastScanTime) == "function" and targetId then
            local ok, val = pcall(tsmObj.GetLastScanTime, tsmObj, targetId)
            local valid = ok and ValidateTimestamp(val, now)
            if valid then return valid end
        end

        -- AuctionDB sub-module
        if type(tsmObj.AuctionDB) == "table" then
            if type(tsmObj.AuctionDB.GetLastScanTime) == "function" and targetId then
                local ok, val = pcall(tsmObj.AuctionDB.GetLastScanTime, tsmObj.AuctionDB, targetId)
                local valid = ok and ValidateTimestamp(val, now)
                if valid then return valid end
            end
            if type(tsmObj.AuctionDB.GetLastCompleteScan) == "function" then
                local ok, val = pcall(tsmObj.AuctionDB.GetLastCompleteScan, tsmObj.AuctionDB)
                local valid = ok and ValidateTimestamp(val, now)
                if valid then return valid end
            end
            if type(tsmObj.AuctionDB.GetRealmItemData) == "function" and targetId then
                local ok, val = pcall(tsmObj.AuctionDB.GetRealmItemData, targetId, "lastScan")
                local valid = ok and ValidateTimestamp(val, now)
                if valid then return valid end
            end
        end

        -- Database realm properties
        if type(tsmObj.db) == "table" and type(tsmObj.db.realm) == "table" then
            local r = tsmObj.db.realm
            local valid = ValidateTimestamp(r.appDataUpdate, now)
                or ValidateTimestamp(r.lastCompleteScan, now)
                or ValidateTimestamp(r.time, now)
            if valid then return valid end
        end

        -- AppData2 realm downloadTime
        if type(tsmObj.AppData2) == "table" then
            local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
            if type(tsmObj.AppData2[realm]) == "table" then
                local valid = ValidateTimestamp(tsmObj.AppData2[realm].downloadTime, now)
                if valid then return valid end
            end
        end

        -- App synchronization metadata
        if type(tsmObj.appInfo) == "table" then
            local valid = ValidateTimestamp(tsmObj.appInfo.lastSync, now)
            if valid then return valid end
        end

        if type(tsmObj.appDB) == "table" and type(tsmObj.appDB.factionrealm) == "table" then
            local valid = ValidateTimestamp(tsmObj.appDB.factionrealm.lastSync, now)
            if valid then return valid end
        end
    end

    -- 3. Check TradeSkillMaster_AuctionDB standalone object
    local adb = _G.TradeSkillMaster_AuctionDB
    if adb then
        if type(adb.GetLastScanTime) == "function" and targetId then
            local ok, val = pcall(adb.GetLastScanTime, adb, targetId)
            local valid = ok and ValidateTimestamp(val, now)
            if valid then return valid end
        end
        if type(adb.GetLastCompleteScan) == "function" then
            local ok, val = pcall(adb.GetLastCompleteScan, adb)
            local valid = ok and ValidateTimestamp(val, now)
            if valid then return valid end
        end
        if type(adb.db) == "table" and type(adb.db.realm) == "table" then
            local r = adb.db.realm
            local valid = ValidateTimestamp(r.appDataUpdate, now) or ValidateTimestamp(r.lastCompleteScan, now)
            if valid then return valid end
        end
    end

    -- 4. Check SavedVariables / globals
    if type(_G.TradeSkillMasterDB) == "table" and type(_G.TradeSkillMasterDB.realm) == "table" then
        local r = _G.TradeSkillMasterDB.realm
        local valid = ValidateTimestamp(r.appDataUpdate, now)
            or ValidateTimestamp(r.lastCompleteScan, now)
            or ValidateTimestamp(r.time, now)
        if valid then return valid end
    end

    return nil
end

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
        local timestamp = GetTSMTimestamp(itemLink, itemId)
        local sourceTag = "TSM DBMarket"
        if type(timestamp) == "number" then
            local ageStr = PCF.Formatter and PCF.Formatter.FormatRelativeAge and PCF.Formatter.FormatRelativeAge(timestamp)
            if ageStr then
                sourceTag = string.format("TSM DBMarket (%s)", ageStr)
            end
        end
        return price, sourceTag, timestamp
    end
    return nil
end

PCF.ProviderRegistry.Register("TradeSkillMaster", 10, QueryTSM)
