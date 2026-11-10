local addonName, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")

coreFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= addonName then return end

    PCF.LoadConfig()
    PCF.Consensus.Init()
    PCF.ChatListener.Init()
    if PCF.Tooltip and PCF.Tooltip.Init then
        PCF.Tooltip.Init()
    end

    -- Slash Command Setup
    SLASH_GUILDPRICECHECK1 = "/gpc"
    SLASH_GUILDPRICECHECK2 = "/pcf"
    SlashCmdList["GUILDPRICECHECK"] = function(msg)
        local cmd = (msg or ""):lower():match("^%s*(%S+)")
        if cmd == "scan" then
            PCF.Scanner.StartScan()
        elseif cmd == "toggle" then
            PCF_DB.settings.enabled = not PCF_DB.settings.enabled
            print(string.format("|cff00ff00[PCF]|r Enabled state: %s", tostring(PCF_DB.settings.enabled)))
        else
            print("|cff00ff00PriceCheckerForever Commands:|r")
            print("  /gpc scan   - Perform full AH scan (must have AH window open)")
            print("  /gpc toggle - Enable or disable automatic replies")
        end
    end

    print("|cff00ff00PriceCheckerForever loaded.|r Use /gpc for options.")
end)

PCF.coreFrame = coreFrame
