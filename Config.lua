local addonName, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF
_G.GPC = PCF

PCF_DB = PCF_DB or _G.GPC_DB or {}
_G.PCF_DB = PCF_DB
_G.GPC_DB = PCF_DB

local defaultConfig = {
    version = 1,
    settings = {
        enabled = true,
        allowWhispers = true,
        allowGuild = true,
        cooldownSeconds = 3,
        preferredProvider = "AUTO", -- "AUTO", "TSM", "AUCTIONATOR", "NATIVE"
        showScanButton = true,
        showTooltip = true,
        enablePassiveSniffing = true,
        enablePeerSync = true,
        enableSniffExternalAddons = true,
    },
    prices = {}, -- [itemId] = { minBuyout = 0, minBid = 0, lastUpdated = 0, count = 0, source = "Scan" }
    lastFullScan = 0,
    lastReplicateScan = 0,
    lastPeerSync = 0,
}

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

function PCF.HasExternalAuctionAddon()
    if _G.TSM_API ~= nil or _G.TradeSkillMaster ~= nil or _G.Auctionator ~= nil then
        return true
    end
    local isLoaded = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(isLoaded) == "function" then
        if isLoaded("TradeSkillMaster") or isLoaded("Auctionator") then
            return true
        end
    end
    return false
end

function PCF.LoadConfig(customDB)
    if type(customDB) == "table" then
        PCF_DB = customDB
    else
        PCF_DB = (type(_G.PCF_DB) == "table" and _G.PCF_DB)
            or (type(_G.GPC_DB) == "table" and _G.GPC_DB)
            or {}
    end
    _G.PCF_DB = PCF_DB
    _G.GPC_DB = PCF_DB

    ApplyDefaults(PCF_DB, defaultConfig)

    if PCF.HasExternalAuctionAddon() then
        PCF_DB.settings.showScanButton = false
        PCF_DB.settings.showTooltip = false
    end

    return PCF_DB
end
