local _, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF

PCF.ChatListener = PCF.ChatListener or {}

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
    local key = sender or "_API_"
    local now = GetTime()
    local cooldownSec = (PCF_DB and PCF_DB.settings and PCF_DB.settings.cooldownSeconds) or 3
    if cooldowns[key] and (now - cooldowns[key]) < cooldownSec then
        return false
    end
    cooldowns[key] = now
    return true
end

function PCF.ChatListener.DispatchPriceReply(itemLink, itemId, channel, target, cooldownKey)
    if not itemLink or not itemId then return false end
    if not CheckCooldown(cooldownKey or target or channel) then
        return false
    end

    local price, source = PCF.ProviderRegistry.ResolvePrice(itemLink, itemId)
    local formatted = price and PCF.Formatter.FormatMoney(price) or "No price data"
    local responseMsg = string.format("Price check for %s: %s (%s)", itemLink, formatted, source)

    local upperChannel = (channel or "GUILD"):upper()
    if upperChannel == "WHISPER" then
        if PCF_DB and PCF_DB.settings and PCF_DB.settings.allowWhispers == false then
            return false
        end
        SendChatMessage(responseMsg, "WHISPER", nil, target)
        return true, responseMsg
    elseif upperChannel == "GUILD" then
        if PCF_DB and PCF_DB.settings and PCF_DB.settings.allowGuild == false then
            return false
        end
        PCF.Consensus.DispatchGuildResponse(itemId, function()
            SendChatMessage(responseMsg, "GUILD")
        end, source)
        return true, responseMsg
    elseif upperChannel == "PARTY" or upperChannel == "RAID" or upperChannel == "SAY" or upperChannel == "INSTANCE_CHAT" then
        SendChatMessage(responseMsg, upperChannel)
        return true, responseMsg
    end

    return false
end

local function HandleIncoming(message, sender, channel)
    if not PCF_DB or not PCF_DB.settings or not PCF_DB.settings.enabled then return end
    if IsSelfSender(sender) then return end

    local itemLink, itemId = PCF.ItemParser.Parse(message)
    if not itemLink or not itemId then return end

    PCF.ChatListener.DispatchPriceReply(itemLink, itemId, channel, sender, sender)
end

function PCF.ChatListener.ResetCooldowns()
    cooldowns = {}
end

function PCF.ChatListener.Init()
    if PCF.ChatListener._initialized then return end
    PCF.ChatListener._initialized = true

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
