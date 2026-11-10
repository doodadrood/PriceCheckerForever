local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.ChatListener = {}

local cooldowns = {}

local function IsSelfSender(sender)
    if not sender then return false end
    local playerName = UnitName and UnitName("player")
    if not playerName then return false end
    if sender == playerName then return true end
    local shortSender = sender:match("^([^%-]+)")
    return shortSender == playerName
end

local function CheckCooldown(sender)
    local now = GetTime()
    local cooldownSec = (PCF_DB and PCF_DB.settings and PCF_DB.settings.cooldownSeconds) or 3
    if cooldowns[sender] and (now - cooldowns[sender]) < cooldownSec then
        return false
    end
    cooldowns[sender] = now
    return true
end

local function HandleIncoming(message, sender, channel)
    if not PCF_DB or not PCF_DB.settings or not PCF_DB.settings.enabled then return end
    if IsSelfSender(sender) then return end

    local itemLink, itemId = PCF.ItemParser.Parse(message)
    if not itemLink or not itemId then return end

    if not CheckCooldown(sender) then return end

    local price, source = PCF.ProviderRegistry.ResolvePrice(itemLink, itemId)
    local formatted = price and PCF.Formatter.FormatMoney(price) or "No price data"
    local responseMsg = string.format("Price check for %s: %s (%s)", itemLink, formatted, source)

    if channel == "WHISPER" and PCF_DB.settings.allowWhispers then
        SendChatMessage(responseMsg, "WHISPER", nil, sender)
    elseif channel == "GUILD" and PCF_DB.settings.allowGuild then
        PCF.Consensus.DispatchGuildResponse(itemId, function()
            SendChatMessage(responseMsg, "GUILD")
        end, source)
    end
end

function PCF.ChatListener.ResetCooldowns()
    cooldowns = {}
end

function PCF.ChatListener.Init()
    local listenerFrame = CreateFrame("Frame")
    listenerFrame:RegisterEvent("CHAT_MSG_GUILD")
    listenerFrame:RegisterEvent("CHAT_MSG_WHISPER")

    listenerFrame:SetScript("OnEvent", function(_, event, msg, sender)
        if event == "CHAT_MSG_GUILD" then
            HandleIncoming(msg, sender, "GUILD")
        elseif event == "CHAT_MSG_WHISPER" then
            HandleIncoming(msg, sender, "WHISPER")
        end
    end)

    PCF.ChatListener.frame = listenerFrame
end
