local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Tooltip = {}

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
    if PCF_DB and PCF_DB.settings and PCF_DB.settings.showTooltip == false then
        return
    end
    local itemLink, itemId = ExtractItemFromTooltip(tooltip, tooltipData)
    if not itemLink and not itemId then return end

    local ahPrice = PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)
    local formatted = PCF.Formatter.FormatTooltipMoney(ahPrice)
    -- Two spaces between "AH" and "Price:" shifts "Price:" right by 3px,
    -- aligning "Price:" and ":" with "Sell Price:" in Friz Quadrata TT.
    local lineText = string.format("AH  Price: %s", formatted)

    UpdateOrAddAHPriceLine(tooltip, lineText)
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
