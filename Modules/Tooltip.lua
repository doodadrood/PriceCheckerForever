local _, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF

PCF.Tooltip = PCF.Tooltip or {}

local function ExtractItemFromTooltip(tooltip, tooltipData)
    local itemLink = nil
    local itemId = nil

    if tooltip and tooltip.GetItem then
        local _, link = tooltip:GetItem()
        itemLink = link
    end

    if not itemLink and tooltipData and tooltipData.hyperlink then
        itemLink = tooltipData.hyperlink
    end

    if itemLink then
        itemId = tonumber(itemLink:match("item:(%d+)"))
    end

    if not itemId and tooltipData and tooltipData.id then
        itemId = tonumber(tooltipData.id)
    end

    return itemLink, itemId
end

local function QueryContainerStackCount(bag, slot, expectedItemId)
    if type(bag) ~= "number" or type(slot) ~= "number" then
        return nil
    end

    if _G.C_Container and _G.C_Container.GetContainerItemInfo then
        local ok, info = pcall(_G.C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" and info.stackCount and info.stackCount > 1 then
            if not expectedItemId or not info.itemID or info.itemID == expectedItemId then
                return math.floor(info.stackCount)
            end
        end
    end

    if _G.GetContainerItemInfo then
        local ok, _, itemCount, _, _, _, _, link = pcall(_G.GetContainerItemInfo, bag, slot)
        if ok and type(itemCount) == "number" and itemCount > 1 then
            local slotItemId = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
            if not expectedItemId or not slotItemId or slotItemId == expectedItemId then
                return math.floor(itemCount)
            end
        end
    end

    return nil
end

local function ExtractStackCount(tooltip, itemId)
    if not tooltip then return 1 end

    if type(tooltip._pcfStackCount) == "number" and tooltip._pcfStackCount > 1 then
        return math.floor(tooltip._pcfStackCount)
    end

    local owner = tooltip.GetOwner and tooltip:GetOwner()
    if owner then
        if type(owner.count) == "number" and owner.count > 1 then
            return math.floor(owner.count)
        end
        if type(owner.stackCount) == "number" and owner.stackCount > 1 then
            return math.floor(owner.stackCount)
        end

        local countRegion = owner.Count or (owner.GetName and owner:GetName() and _G[owner:GetName() .. "Count"])
        if countRegion and countRegion.GetText and (not countRegion.IsShown or countRegion:IsShown()) then
            local text = countRegion:GetText()
            local parsed = type(text) == "string" and tonumber(text:match("^%s*(%d+)%s*$"))
            if parsed and parsed > 1 then
                return math.floor(parsed)
            end
        end

        local bag = (owner.GetBagID and owner:GetBagID())
            or owner.bagID
            or (owner.GetParent and owner:GetParent() and owner:GetParent().GetID and owner:GetParent():GetID())
        local slot = (owner.GetSlotIndex and owner:GetSlotIndex())
            or owner.slotID
            or (owner.GetID and owner:GetID())

        local containerCount = QueryContainerStackCount(bag, slot, itemId)
        if containerCount and containerCount > 1 then
            return containerCount
        end
    end

    return 1
end

local function UpdateOrAddAHPriceLine(tooltip, lineText)
    if not tooltip then return end

    -- Check if an AH Price line already exists on this tooltip to avoid duplicates
    local tooltipName = tooltip.GetName and tooltip:GetName()
    local numLines = tooltip.NumLines and tooltip:NumLines() or 0
    if tooltipName and numLines > 0 then
        for i = 1, numLines do
            local leftFontString = _G[tooltipName .. "TextLeft" .. i]
            if leftFontString and leftFontString.GetText then
                local existingText = leftFontString:GetText()
                if existingText and existingText:find("^AH%s+Price:") then
                    leftFontString:SetText(lineText)
                    if tooltip.Show then tooltip:Show() end
                    return
                end
            end
        end
    end

    if tooltip.AddLine then
        tooltip:AddLine(lineText, 1, 1, 1)
    end
    if tooltip.Show then
        tooltip:Show()
    end
end

function PCF.Tooltip.OnTooltipSetItem(tooltip, tooltipData)
    if not tooltip then return end
    local itemLink, itemId = ExtractItemFromTooltip(tooltip, tooltipData)
    if not itemLink and not itemId then return end

    -- Always resolve AH price first so TSM/Auctionator users passively harvest
    -- hovered item prices into PCF_DB.prices for the guild mesh even when showTooltip is off
    local ahPrice = PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)

    if PCF_DB and PCF_DB.settings and PCF_DB.settings.showTooltip == false then
        return
    end

    local lineText
    if ahPrice and ahPrice > 0 then
        local stackCount = ExtractStackCount(tooltip, itemId)
        local unitFormatted = PCF.Formatter.FormatTooltipMoney(ahPrice)
        if stackCount and stackCount > 1 then
            local stackFormatted = PCF.Formatter.FormatTooltipMoney(ahPrice * stackCount)
            lineText = string.format("AH  Price: %s (%s)", stackFormatted, unitFormatted)
        else
            lineText = string.format("AH  Price: %s", unitFormatted)
        end
    else
        lineText = "AH  Price: ??"
    end

    UpdateOrAddAHPriceLine(tooltip, lineText)
end

function PCF.Tooltip.RefreshVisibleTooltip()
    if _G.GameTooltip and (not _G.GameTooltip.IsShown or _G.GameTooltip:IsShown()) then
        PCF.Tooltip.OnTooltipSetItem(_G.GameTooltip)
    end
end

local function HookTooltip(tooltip)
    if not tooltip or tooltip._pcfHooked then return end
    if tooltip.HookScript then
        local ok = pcall(function()
            tooltip:HookScript("OnTooltipSetItem", function(self)
                PCF.Tooltip.OnTooltipSetItem(self)
            end)
        end)
        if ok then
            tooltip._pcfHooked = true
        end
        pcall(function()
            tooltip:HookScript("OnTooltipCleared", function(self)
                self._pcfStackCount = nil
            end)
        end)
        pcall(function()
            tooltip:HookScript("OnHide", function(self)
                self._pcfStackCount = nil
            end)
        end)
    end

    if _G.hooksecurefunc and type(tooltip.SetBagItem) == "function" then
        pcall(_G.hooksecurefunc, tooltip, "SetBagItem", function(self, bag, slot)
            self._pcfStackCount = QueryContainerStackCount(bag, slot, nil)
        end)
    end
end

function PCF.Tooltip.Init()
    HookTooltip(_G.GameTooltip)
    HookTooltip(_G.ItemRefTooltip)
    HookTooltip(_G.ShoppingTooltip1)
    HookTooltip(_G.ShoppingTooltip2)

    if _G.TooltipDataProcessor and _G.TooltipDataProcessor.AddTooltipPostCall and _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Item then
        if not PCF.Tooltip._processorHooked then
            _G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Item, function(tooltip, data)
                PCF.Tooltip.OnTooltipSetItem(tooltip, data)
            end)
            PCF.Tooltip._processorHooked = true
        end
    end
end
