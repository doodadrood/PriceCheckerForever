local addonName, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF
_G.GPC = PCF

local function NormalizeItemInput(itemLinkOrId)
    if type(itemLinkOrId) == "number" then
        if itemLinkOrId > 0 then
            return nil, math.floor(itemLinkOrId)
        end
        return nil, nil
    elseif type(itemLinkOrId) == "string" then
        local directId = tonumber(itemLinkOrId)
        if directId and directId > 0 then
            return nil, math.floor(directId)
        end
        local extractedId = tonumber(itemLinkOrId:match("item:(%d+)"))
        if extractedId and extractedId > 0 then
            local link = itemLinkOrId:find("|Hitem:") and itemLinkOrId or nil
            return link, extractedId
        end
    end
    return nil, nil
end

local function NormalizeSourceLabel(rawSource)
    if not rawSource or rawSource == "No Data" then
        return "None"
    elseif rawSource == "TSM DBMarket" or rawSource:find("^TSM") then
        return "TSM"
    elseif rawSource == "Auctionator" or rawSource:find("^Auctionator") then
        return "Auctionator"
    elseif rawSource:find("^PCF Mesh") or rawSource == "Mesh" then
        return "Mesh"
    elseif rawSource:find("^PCF Sniff") or rawSource == "Sniff" then
        return "Sniff"
    elseif rawSource:find("^Native") then
        return "Native"
    elseif rawSource == "Vendor Base" or rawSource:find("^Vendor") then
        return "Vendor"
    end
    return rawSource
end

-- Public Developer API (_G.PCF_API)
PCF_API = _G.PCF_API or {}
_G.PCF_API = PCF_API

function PCF_API.GetPrice(itemLinkOrId)
    if not PCF.ProviderRegistry or not PCF.ProviderRegistry.ResolvePrice then
        return nil, "None", "No Data"
    end
    local itemLink, itemId = NormalizeItemInput(itemLinkOrId)
    if not itemLink and not itemId then
        return nil, "None", "No Data"
    end

    local price, rawSource = PCF.ProviderRegistry.ResolvePrice(itemLink, itemId)
    if price and price > 0 then
        return price, NormalizeSourceLabel(rawSource), rawSource
    end
    return nil, "None", rawSource or "No Data"
end

function PCF_API.FormatMoney(copper)
    if not PCF.Formatter or not PCF.Formatter.FormatMoney then
        return "0c"
    end
    return PCF.Formatter.FormatMoney(copper)
end

function PCF_API.FormatTooltipMoney(copper)
    if not PCF.Formatter or not PCF.Formatter.FormatTooltipMoney then
        return "??"
    end
    return PCF.Formatter.FormatTooltipMoney(copper)
end

function PCF_API.GetPriceTimestamp(itemId)
    local _, numericId = NormalizeItemInput(itemId)
    if not numericId or not PCF_DB or not PCF_DB.prices then
        return nil
    end
    local entry = PCF_DB.prices[numericId]
    if entry and entry.lastUpdated and entry.lastUpdated > 0 then
        return entry.lastUpdated
    end
    return nil
end

function PCF_API.RequestPriceCheck(itemLink, channel, target)
    if not PCF.ChatListener or not PCF.ChatListener.DispatchPriceReply then
        return false
    end
    local link, itemId = NormalizeItemInput(itemLink)
    if not itemId then
        return false
    end
    local displayLink = link or (type(itemLink) == "string" and itemLink) or string.format("[item:%d]", itemId)
    return PCF.ChatListener.DispatchPriceReply(displayLink, itemId, channel or "GUILD", target, target or channel or "_API_")
end

function PCF_API.IsReady()
    return _G.PCF_INITIALIZED == true
        and type(PCF_DB) == "table"
        and type(PCF_DB.prices) == "table"
        and type(PCF.ProviderRegistry) == "table"
end

function PCF_API.SetSavedVariables(customDBTable)
    if type(customDBTable) ~= "table" then
        return false
    end
    PCF.LoadConfig(customDBTable)
    return true
end

local function RegisterSlashCommands()
    SLASH_PRICECHECKERFOREVER1 = "/pcf"
    SlashCmdList["PRICECHECKERFOREVER"] = function(msg)
        local cmd = (msg or ""):lower():match("^%s*(%S+)")
        if cmd == "scan" then
            PCF.Scanner.StartScan()
        elseif cmd == "toggle" then
            PCF_DB.settings.enabled = not PCF_DB.settings.enabled
            print(string.format("|cff00ff00[PCF]|r Enabled state: %s", tostring(PCF_DB.settings.enabled)))
        elseif cmd == "button" or cmd == "scanbutton" or cmd == "ahbutton" then
            PCF_DB.settings.showScanButton = not PCF_DB.settings.showScanButton
            if PCF.Scanner and PCF.Scanner.UpdateVisibility then
                PCF.Scanner.UpdateVisibility()
            end
            print(string.format("|cff00ff00[PCF]|r AH Scan Button: %s", PCF_DB.settings.showScanButton and "ON" or "OFF"))
        elseif cmd == "tooltip" or cmd == "tooltips" or cmd == "tip" then
            PCF_DB.settings.showTooltip = not PCF_DB.settings.showTooltip
            print(string.format("|cff00ff00[PCF]|r Tooltip AH Price: %s", PCF_DB.settings.showTooltip and "ON" or "OFF"))
        elseif cmd == "sniff" then
            PCF_DB.settings.enablePassiveSniffing = not PCF_DB.settings.enablePassiveSniffing
            print(string.format("|cff00ff00[PCF]|r Passive AH Sniffing: %s", PCF_DB.settings.enablePassiveSniffing and "ON" or "OFF"))
        elseif cmd == "sync" then
            PCF_DB.settings.enablePeerSync = not PCF_DB.settings.enablePeerSync
            print(string.format("|cff00ff00[PCF]|r Peer Mesh Sync: %s", PCF_DB.settings.enablePeerSync and "ON" or "OFF"))
        else
            print("|cff00ff00PriceCheckerForever Commands:|r")
            print("  /pcf scan    - Perform full AH scan (must have AH window open)")
            print("  /pcf toggle  - Enable or disable automatic replies")
            print("  /pcf button  - Toggle the AH window scan button on or off")
            print("  /pcf tooltip - Toggle item tooltip AH price display on or off")
            print("  /pcf sniff   - Toggle passive AH browse-sniffing on or off")
            print("  /pcf sync    - Toggle guild peer-to-peer mesh sync on or off")
        end
    end
end

function PCF.Initialize()
    if _G.PCF_INITIALIZED then
        return false
    end
    _G.PCF_INITIALIZED = true

    PCF.LoadConfig()
    if PCF.Consensus and PCF.Consensus.Init then
        PCF.Consensus.Init()
    end
    if PCF.MeshSync and PCF.MeshSync.Init then
        PCF.MeshSync.Init()
    end
    if PCF.Scanner and PCF.Scanner.Init then
        PCF.Scanner.Init()
    end
    if PCF.ChatListener and PCF.ChatListener.Init then
        PCF.ChatListener.Init()
    end
    if PCF.Tooltip and PCF.Tooltip.Init then
        PCF.Tooltip.Init()
    end

    RegisterSlashCommands()
    print("|cff00ff00PriceCheckerForever loaded.|r Use /pcf for options.")
    return true
end

-- Guard against duplicate frame registration when embedded alongside standalone PCF
if _G.PCF_INITIALIZED then
    return
end

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")

coreFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= addonName and loadedAddon ~= "PriceCheckerForever" then
        return
    end
    if _G.PCF_INITIALIZED then
        self:UnregisterEvent("ADDON_LOADED")
        return
    end
    PCF.Initialize()
    self:UnregisterEvent("ADDON_LOADED")
end)

PCF.coreFrame = coreFrame
