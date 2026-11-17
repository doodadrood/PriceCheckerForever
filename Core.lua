local addonName, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF
_G.GPC = PCF

local function NormalizeItemInput(itemLinkOrId)
    if not itemLinkOrId or (PCF.IsSecret and PCF.IsSecret(itemLinkOrId)) then
        return nil, nil, nil
    end
    if type(itemLinkOrId) == "number" then
        if itemLinkOrId > 0 and itemLinkOrId < math.huge then
            return nil, math.floor(itemLinkOrId) + 0, 1
        end
        return nil, nil, nil
    elseif type(itemLinkOrId) == "string" then
        local directId = tonumber(itemLinkOrId)
        if directId and directId > 0 and directId < math.huge then
            return nil, math.floor(directId) + 0, 1
        end
        local extractedId = tonumber(itemLinkOrId:match("item:(%d+)"))
        if extractedId and extractedId > 0 and extractedId < math.huge then
            local cleanLink = itemLinkOrId:match("(|c%x+|Hitem:%d+.-|h%[.-%]|h|r)")
                or itemLinkOrId:match("(|cn[^:]+:|Hitem:%d+.-|h%[.-%]|h|r)")
                or itemLinkOrId:match("(|Hitem:%d+.-|h%[.-%]|h)")
            local parsedQty = 1
            if cleanLink then
                local _, endIdx = itemLinkOrId:find(cleanLink, 1, true)
                if endIdx then
                    local tail = itemLinkOrId:sub(endIdx + 1)
                    local qtyStr = tail:match("^%s*%]?%s*[xX%*]%s*(%d+)")
                        or tail:match("^%s*%]?%s*(%d+)%s*[xX%*]")
                    if qtyStr then
                        local q = tonumber(qtyStr)
                        if q and q >= 1 and q < math.huge then
                            parsedQty = math.floor(q) + 0
                        end
                    end
                end
            end
            return cleanLink, extractedId, parsedQty
        end
    end
    return nil, nil, nil
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

function PCF_API.RequestPriceCheck(itemLink, channel, target, quantity)
    if not PCF.ChatListener or not PCF.ChatListener.DispatchPriceReply then
        return false
    end
    local link, itemId, parsedQty = NormalizeItemInput(itemLink)
    if not itemId then
        return false
    end
    local resolvedQty = tonumber(quantity) or parsedQty or 1
    local displayLink = link or (type(itemLink) == "string" and itemLink) or string.format("[item:%.0f]", itemId)
    return PCF.ChatListener.DispatchPriceReply(displayLink, itemId, channel or "GUILD", target, target or channel or "_API_", resolvedQty)
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
            PCF_DB.settings.userSetScanButton = true
            if PCF.Scanner and PCF.Scanner.UpdateVisibility then
                PCF.Scanner.UpdateVisibility()
            end
            print(string.format("|cff00ff00[PCF]|r AH Scan Button: %s", PCF_DB.settings.showScanButton and "ON" or "OFF"))
        elseif cmd == "tooltip" or cmd == "tooltips" or cmd == "tip" then
            PCF_DB.settings.showTooltip = not PCF_DB.settings.showTooltip
            PCF_DB.settings.userSetTooltip = true
            print(string.format("|cff00ff00[PCF]|r Tooltip AH Price: %s", PCF_DB.settings.showTooltip and "ON" or "OFF"))
        elseif cmd == "autoscan" then
            PCF_DB.settings.autoScanOnOpen = not PCF_DB.settings.autoScanOnOpen
            print(string.format("|cff00ff00[PCF]|r Auto-Scan on AH Open: %s", PCF_DB.settings.autoScanOnOpen and "ON" or "OFF"))
        elseif cmd == "replicate" then
            PCF_DB.settings.preferReplicateScan = not PCF_DB.settings.preferReplicateScan
            PCF_DB.settings.userSetScanMode = true
            print(string.format("|cff00ff00[PCF]|r Replicate Full Scan Mode: %s", PCF_DB.settings.preferReplicateScan and "ON" or "OFF"))
        elseif cmd == "sniff" then
            PCF_DB.settings.enablePassiveSniffing = not PCF_DB.settings.enablePassiveSniffing
            print(string.format("|cff00ff00[PCF]|r Passive AH Sniffing: %s", PCF_DB.settings.enablePassiveSniffing and "ON" or "OFF"))
        elseif cmd == "sync" then
            PCF_DB.settings.enablePeerSync = not PCF_DB.settings.enablePeerSync
            print(string.format("|cff00ff00[PCF]|r Peer Mesh Sync: %s", PCF_DB.settings.enablePeerSync and "ON" or "OFF"))
        elseif cmd == "default" or cmd == "defaults" or cmd == "reset" then
            if PCF.ResetSettings then
                PCF.ResetSettings()
            end
            if PCF.Scanner and PCF.Scanner.UpdateVisibility then
                PCF.Scanner.UpdateVisibility()
            end
            if PCF.Tooltip and PCF.Tooltip.RefreshVisibleTooltip then
                PCF.Tooltip.RefreshVisibleTooltip()
            end
            print("|cff00ff00[PCF]|r Settings reset to defaults (AH Scan Button: ON, Tooltip: ON, Auto-Scan: OFF, Replicate Scan: ON, Provider: AUTO).")
        else
            print("|cff00ff00PriceCheckerForever Commands:|r")
            print("  /pcf scan      - Perform full AH scan (must have AH window open)")
            print("  /pcf autoscan  - Toggle automatic cooldown-gated AH scan on open")
            print("  /pcf replicate - Toggle full API scan (ReplicateItems) vs paginated browse mode")
            print("  /pcf toggle    - Enable or disable automatic replies")
            print("  /pcf button    - Toggle the AH window scan button on or off")
            print("  /pcf tooltip   - Toggle item tooltip AH price display on or off")
            print("  /pcf sniff     - Toggle passive AH browse-sniffing on or off")
            print("  /pcf sync      - Toggle guild peer-to-peer mesh sync on or off")
            print("  /pcf default   - Reset all PCF settings to baseline defaults")
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
