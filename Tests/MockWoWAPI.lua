-- Mock WoW Lua Environment for CLI validation
local Mock = {
    chatMessages = {},
    addonMessages = {},
    registeredPrefixes = {},
    timers = {},
    currentTime = 1000.0,
    auctionListings = {},
}

_G.SlashCmdList = _G.SlashCmdList or {}

_G.GetTime = function() return Mock.currentTime end
_G.time = function() return math.floor(Mock.currentTime) end
_G.UnitName = function(unit) return unit == "player" and "LocalPlayer" or "TargetPlayer" end

_G.C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix)
        Mock.registeredPrefixes[prefix] = true
        return true
    end,
    SendAddonMessage = function(prefix, msg, channel)
        assert(type(msg) == "string" and #msg <= 255, "SendAddonMessage payload exceeds 255-byte Blizzard limit: " .. tostring(#(msg or "")))
        table.insert(Mock.addonMessages, { prefix = prefix, msg = msg, channel = channel })
    end
}

_G.SendChatMessage = function(msg, channel, lang, target)
    table.insert(Mock.chatMessages, { msg = msg, channel = channel, target = target })
end

_G.C_Timer = {
    After = function(delay, callback)
        table.insert(Mock.timers, { executeAt = Mock.currentTime + delay, delay = delay, callback = callback })
    end
}

_G.GetNumAuctionItems = function(listType)
    return #Mock.auctionListings, #Mock.auctionListings
end

_G.GetAuctionItemInfo = function(listType, index)
    local entry = Mock.auctionListings[index]
    if not entry then return nil end
    return entry.name or "MockItem", nil, entry.count or 1, 1, nil, 1, nil, entry.minBid or entry.buyoutPrice or 0, 0, entry.buyoutPrice or 0, 0, nil, 0, "Seller", nil, 0, entry.itemId
end

_G.CreateFrame = function(frameType, name, parent, template)
    local frame = {
        frameType = frameType,
        name = name,
        parent = parent,
        template = template,
        events = {},
        scripts = {},
        lines = {},
        text = "",
        shown = true,
        minVal = 0,
        maxVal = 1,
        val = 0,
    }
    if name then _G[name] = frame end
    function frame:GetName() return self.name end
    function frame:GetParent() return self.parent end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:SetScript(name, func) self.scripts[name] = func end
    function frame:HookScript(name, func)
        local prev = self.scripts[name]
        self.scripts[name] = function(...) if prev then prev(...) end; func(...) end
    end
    function frame:Trigger(event, ...)
        if self.events[event] and self.scripts["OnEvent"] then
            self.scripts["OnEvent"](self, event, ...)
        end
    end
    function frame:Click()
        if self.scripts["OnClick"] then
            self.scripts["OnClick"](self)
        end
    end
    function frame:SetOwner(...) end
    function frame:ClearLines()
        if self.name then
            for i = 1, #self.lines do
                _G[self.name .. "TextLeft" .. i] = nil
            end
        end
        self.lines = {}
    end
    function frame:AddLine(text)
        table.insert(self.lines, text)
        if self.name then
            local idx = #self.lines
            _G[self.name .. "TextLeft" .. idx] = {
                GetText = function() return self.lines[idx] end,
                SetText = function(_, newText) self.lines[idx] = newText end,
            }
        end
    end
    function frame:NumLines() return #self.lines end
    function frame:SetItem(itemName, itemLink)
        self.itemName = itemName
        self.itemLink = itemLink
        if self.scripts["OnTooltipSetItem"] then
            self.scripts["OnTooltipSetItem"](self)
        end
    end
    function frame:GetItem()
        return self.itemName, self.itemLink
    end
    function frame:SetSize(w, h) self.width = w; self.height = h end
    function frame:SetWidth(w) self.width = w end
    function frame:SetHeight(h) self.height = h end
    function frame:SetPoint(...) end
    function frame:SetAllPoints(...) end
    function frame:SetFrameStrata(...) end
    function frame:SetText(t) self.text = t end
    function frame:GetText() return self.text end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:SetMinMaxValues(minV, maxV) self.minVal = minV; self.maxVal = maxV end
    function frame:SetValue(v) self.val = v end
    function frame:GetValue() return self.val end
    function frame:SetStatusBarTexture(...) end
    function frame:SetStatusBarColor(...) end
    function frame:CreateTexture(...)
        return {
            SetAllPoints = function() end,
            SetColorTexture = function() end,
            SetTexture = function() end,
        }
    end
    function frame:CreateFontString(...)
        local fs = { text = "" }
        function fs:SetPoint(...) end
        function fs:SetText(t) self.text = t end
        function fs:GetText() return self.text end
        return fs
    end
    return frame
end

_G.GameTooltip = _G.CreateFrame("GameTooltip", "GameTooltip")

_G.GetItemInfo = function(itemId)
    if itemId == 19019 then
        -- Thunderfury: vendor sell 25g
        return "Thunderfury", nil, 5, 80, 0, "Weapon", "Sword", 1, "", 1, 250000
    end
    return nil
end

return Mock
