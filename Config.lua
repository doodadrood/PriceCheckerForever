local addonName, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF_DB = PCF_DB or {}

local defaultConfig = {
    version = 1,
    settings = {
        enabled = true,
        allowWhispers = true,
        allowGuild = true,
        cooldownSeconds = 3,
        preferredProvider = "AUTO", -- "AUTO", "TSM", "AUCTIONATOR", "NATIVE"
    },
    prices = {}, -- [itemId] = { minBuyout = 0, minBid = 0, lastUpdated = 0, count = 0 }
    lastFullScan = 0,
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

function PCF.LoadConfig()
    PCF_DB = type(PCF_DB) == "table" and PCF_DB or {}
    ApplyDefaults(PCF_DB, defaultConfig)
end
