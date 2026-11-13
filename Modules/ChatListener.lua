local _, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF

PCF.ChatListener = PCF.ChatListener or {}

local cooldowns = {}

local function IsSecret(val)
    if val == nil then return false end
    if PCF and PCF.IsSecret then
        return PCF.IsSecret(val)
    end
    if _G.issecretvalue then
        local ok, isSec = pcall(_G.issecretvalue, val)
        if ok and isSec then
            return true
        end
    end
    if _G.canaccessvalue then
        local ok, canAccess = pcall(_G.canaccessvalue, val)
        if ok and not canAccess then
            return true
        end
    end
    return false
end

local function IsSelfSender(sender, guid)
    if guid and not IsSecret(guid) then
        local playerGUID = UnitGUID and UnitGUID("player")
        if playerGUID and not IsSecret(playerGUID) and guid == playerGUID then
            return true
        end
    end
    if not sender or IsSecret(sender) then
        return false
    end
    local playerName = UnitName and UnitName("player")
    if not playerName or IsSecret(playerName) then
        return false
    end
    local ok, isMatch = pcall(function()
        if sender == playerName then return true end
        local shortSender = sender:match("^([^%-]+)")
        return shortSender == playerName
    end)
    return ok and isMatch == true
end

local function CheckCooldown(sender)
    local key = sender
    if key == nil or IsSecret(key) then
        key = "_SECRET_"
    end
    local now = GetTime()
    local cooldownSec = (PCF_DB and PCF_DB.settings and PCF_DB.settings.cooldownSeconds) or 3
    if cooldowns[key] and (now - cooldowns[key]) < cooldownSec then
        return false
    end
    cooldowns[key] = now
    return true
end

local function BuildPriceResponse(itemLink, itemId, quantity)
    local price, source = PCF.ProviderRegistry.ResolvePrice(itemLink, itemId)
    local formatted
    if price and price > 0 then
        if quantity > 1 then
            local stackFormatted = PCF.Formatter.FormatMoney(price * quantity)
            local unitFormatted = PCF.Formatter.FormatMoney(price)
            formatted = string.format("%s (%s ea)", stackFormatted, unitFormatted)
        else
            formatted = PCF.Formatter.FormatMoney(price)
        end
    else
        formatted = "No price data"
    end
    return string.format("Price check for %s: %s [%s]", itemLink, formatted, source), price, source
end

function PCF.ChatListener.DispatchPriceReply(itemLink, itemId, channel, target, cooldownKey, quantity)
    if not itemLink or not itemId then return false end
    if not CheckCooldown(cooldownKey or target or channel) then
        return false
    end

    local parsedQty = tonumber(quantity)
    if not parsedQty or not (parsedQty >= 1) or parsedQty >= math.huge then
        quantity = 1
    else
        quantity = math.floor(parsedQty) + 0
    end

    local responseMsg, price, source = BuildPriceResponse(itemLink, itemId, quantity)

    local upperChannel = (channel or "GUILD"):upper()
    if upperChannel == "WHISPER" then
        if PCF_DB and PCF_DB.settings and PCF_DB.settings.allowWhispers == false then
            return false
        end
        if not target or IsSecret(target) then
            return false
        end
        SendChatMessage(responseMsg, "WHISPER", nil, target)
        return true, responseMsg
    elseif upperChannel == "GUILD" then
        if PCF_DB and PCF_DB.settings and PCF_DB.settings.allowGuild == false then
            return false
        end
        -- No real AH data here (nothing, or vendor price only): ask guild peers for just this
        -- item, whether or not we end up answering, so we have it next time.
        local hasAHData = price and price > 0 and not (type(source) == "string" and source:find("^Vendor"))
        if not hasAHData and PCF.MeshSync and PCF.MeshSync.RequestItem then
            PCF.MeshSync.RequestItem(itemId)
        end
        PCF.Consensus.DispatchGuildResponse(itemId, function()
            -- Re-resolve at send time: peer data may have arrived while we waited our turn
            local freshMsg = BuildPriceResponse(itemLink, itemId, quantity)
            SendChatMessage(freshMsg, "GUILD")
        end, source)
        return true, responseMsg
    elseif upperChannel == "PARTY" or upperChannel == "RAID" or upperChannel == "SAY" or upperChannel == "INSTANCE_CHAT" then
        SendChatMessage(responseMsg, upperChannel)
        return true, responseMsg
    end

    return false
end

local function HandleIncoming(message, sender, channel, guid)
    if not PCF_DB or not PCF_DB.settings or not PCF_DB.settings.enabled then return end
    if message == nil or IsSecret(message) then return end
    if IsSelfSender(sender, guid) then return end

    -- Another player's visible price reply counts as a claim, so we stay quiet even if
    -- their addon-channel CLAIM message was missed or delayed.
    if channel == "GUILD" and type(message) == "string" then
        local ok, repliedItemId = pcall(string.match, message, "^Price check for .-item:(%d+)")
        if ok and repliedItemId then
            if PCF.Consensus and PCF.Consensus.RegisterClaim then
                PCF.Consensus.RegisterClaim(tonumber(repliedItemId))
            end
            return
        end
    end

    local itemLink, itemId, quantity = PCF.ItemParser.Parse(message)
    if not itemLink or not itemId then return end

    local safeCooldownKey = (sender and not IsSecret(sender)) and sender or (channel or "_SECRET_")
    PCF.ChatListener.DispatchPriceReply(itemLink, itemId, channel, sender, safeCooldownKey, quantity)
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

    listenerFrame:SetScript("OnEvent", function(self, event, msg, sender, languageName, channelName, playerName2, specialFlags, zoneChannelID, channelIndex, channelBaseName, unused, lineID, guid)
        if event == "CHAT_MSG_GUILD" then
            HandleIncoming(msg, sender, "GUILD", guid)
        elseif event == "CHAT_MSG_WHISPER" then
            HandleIncoming(msg, sender, "WHISPER", guid)
        end
    end)

    PCF.ChatListener.frame = listenerFrame
end
