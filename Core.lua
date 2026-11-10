local addonName, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")

coreFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= addonName then return end

    PCF.LoadConfig()
    PCF.Consensus.Init()
    if PCF.MeshSync and PCF.MeshSync.Init then
        PCF.MeshSync.Init()
    end
    PCF.ChatListener.Init()
    if PCF.Tooltip and PCF.Tooltip.Init then
        PCF.Tooltip.Init()
    end

    -- Slash Command Setup
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

    print("|cff00ff00PriceCheckerForever loaded.|r Use /pcf for options.")
end)

PCF.coreFrame = coreFrame
