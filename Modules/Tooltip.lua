local _, PCF = ...
PCF = (_G.PCF_INITIALIZED and _G.PCF) or (type(PCF) == "table" and PCF) or _G.PCF or {}
_G.PCF = PCF

PCF.Tooltip = PCF.Tooltip or {}

local RECIPE_CLASS_ID = (_G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Recipe)
    or _G.LE_ITEM_CLASS_RECIPE
    or 9

-- Store per-tooltip state in addon-local weak tables so we never write custom fields
-- onto Blizzard tooltip frames (avoiding GameTooltip frame taint).
local hookedTooltips = setmetatable({}, { __mode = "k" })
local tooltipStates = setmetatable({}, { __mode = "k" })

local function GetTooltipState(tooltip, create)
    if not tooltip then return nil end
    local st = tooltipStates[tooltip]
    if not st and create then
        st = {}
        tooltipStates[tooltip] = st
    end
    return st
end

local function ResetTooltipState(tooltip)
    if not tooltip then return end
    tooltipStates[tooltip] = nil
end

local function IsForbiddenTooltip(tooltip)
    if not tooltip then return true end
    if tooltip.IsForbidden then
        local ok, forbidden = pcall(tooltip.IsForbidden, tooltip)
        if ok and forbidden then
            return true
        end
    end
    return false
end

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

local function SafeFind(str, pattern)
    if str == nil or IsSecret(str) then return nil end
    local ok, res = pcall(string.find, str, pattern)
    if ok then
        return res
    end
    return nil
end

local function SafeMatch(str, pattern)
    if str == nil or IsSecret(str) then return nil end
    local ok, res = pcall(string.match, str, pattern)
    if ok then
        return res
    end
    return nil
end

local function ExtractIdFromLink(link)
    if type(link) ~= "string" or IsSecret(link) then
        return nil
    end
    local matchStr = SafeMatch(link, "item:(%d+)")
    if matchStr then
        local id = tonumber(matchStr)
        if id and id > 0 and id < math.huge then
            return math.floor(id) + 0
        end
    end
    return nil
end

local function NormalizePositiveId(val)
    if val == nil or IsSecret(val) then return nil end
    local num = tonumber(val)
    if num and num > 0 and num < math.huge then
        return math.floor(num) + 0
    end
    return nil
end

local function IsRecipeItem(itemLink, itemId)
    local target = itemId or itemLink
    if not target or IsSecret(target) then
        return false
    end

    if _G.C_Item and _G.C_Item.GetItemInfoInstant then
        local ok, _, _, _, _, _, classID = pcall(_G.C_Item.GetItemInfoInstant, target)
        if ok and not IsSecret(classID) and type(classID) == "number" then
            return classID == RECIPE_CLASS_ID
        end
    end

    if _G.GetItemInfoInstant then
        local ok, _, _, _, _, _, classID = pcall(_G.GetItemInfoInstant, target)
        if ok and not IsSecret(classID) and type(classID) == "number" then
            return classID == RECIPE_CLASS_ID
        end
    end

    if _G.C_Item and _G.C_Item.GetItemInfo then
        local ok, _, _, _, _, _, itemType, _, _, _, _, _, classID = pcall(_G.C_Item.GetItemInfo, target)
        if ok then
            if not IsSecret(classID) and type(classID) == "number" then
                return classID == RECIPE_CLASS_ID
            end
            if not IsSecret(itemType) and type(itemType) == "string" then
                return itemType == "Recipe"
            end
        end
    end

    if _G.GetItemInfo then
        local ok, _, _, _, _, _, itemType, _, _, _, _, _, classID = pcall(_G.GetItemInfo, target)
        if ok then
            if not IsSecret(classID) and type(classID) == "number" then
                return classID == RECIPE_CLASS_ID
            end
            if not IsSecret(itemType) and type(itemType) == "string" then
                return itemType == "Recipe"
            end
        end
    end

    return false
end

local function ResolveItemLinkFallback(itemLink, itemId)
    if type(itemLink) == "string" and not IsSecret(itemLink) and itemLink ~= "" then
        return itemLink
    end
    if not itemId then
        return nil
    end
    if _G.C_Item and _G.C_Item.GetItemInfo then
        local ok, _, link = pcall(_G.C_Item.GetItemInfo, itemId)
        if ok and type(link) == "string" and not IsSecret(link) and link ~= "" then
            return link
        end
    end
    if _G.GetItemInfo then
        local ok, _, link = pcall(_G.GetItemInfo, itemId)
        if ok and type(link) == "string" and not IsSecret(link) and link ~= "" then
            return link
        end
    end
    return nil
end

local function SafeGetNumberFromRegion(region)
    if not region or not region.GetText then return nil end
    if region.IsShown and not region:IsShown() then return nil end
    local ok, text = pcall(region.GetText, region)
    if not ok or text == nil or IsSecret(text) then
        return nil
    end
    local matchStr = SafeMatch(text, "^%s*(%d+)%s*$")
    if matchStr then
        return tonumber(matchStr)
    end
    return nil
end

local function GetLeftFontString(tooltip, index)
    if not tooltip then return nil end
    local tooltipName = tooltip.GetName and tooltip:GetName()
    if tooltipName and not IsSecret(tooltipName) then
        local named = _G[tooltipName .. "TextLeft" .. index]
        if named then
            return named
        end
    end
    if tooltip.GetLeftLine then
        local ok, line = pcall(tooltip.GetLeftLine, tooltip, index)
        if ok and line then
            return line
        end
    end
    return nil
end

local function GetTooltipTitleText(tooltip)
    local firstLine = GetLeftFontString(tooltip, 1)
    if not firstLine or not firstLine.GetText then
        return nil
    end
    local ok, text = pcall(firstLine.GetText, firstLine)
    if ok and type(text) == "string" and not IsSecret(text) and text ~= "" then
        return text
    end
    return nil
end

local function RecordSeenItem(state, itemLink, itemId)
    if not state then return nil, nil end
    local validLink = (type(itemLink) == "string" and not IsSecret(itemLink) and ExtractIdFromLink(itemLink)) and itemLink or nil
    local validId = NormalizePositiveId(itemId) or ExtractIdFromLink(validLink)
    if not validId then
        return nil, nil
    end
    state.seenItems = state.seenItems or {}
    state.seenOrder = state.seenOrder or {}
    if state.seenItems[validId] == nil then
        state.seenItems[validId] = validLink or false
        table.insert(state.seenOrder, validId)
    elseif validLink and not state.seenItems[validId] then
        state.seenItems[validId] = validLink
    end
    local storedLink = state.seenItems[validId] or nil
    return storedLink, validId
end

local function QueryContainerItemLinkAndId(bag, slot)
    if type(bag) ~= "number" or type(slot) ~= "number" then
        return nil, nil
    end

    if _G.C_Container then
        if _G.C_Container.GetContainerItemInfo then
            local ok, info = pcall(_G.C_Container.GetContainerItemInfo, bag, slot)
            if ok and type(info) == "table" and not IsSecret(info) then
                local link = (type(info.hyperlink) == "string" and not IsSecret(info.hyperlink)) and info.hyperlink or nil
                local id = NormalizePositiveId(info.itemID) or ExtractIdFromLink(link)
                if id then
                    return link, id
                end
            end
        end
        if _G.C_Container.GetContainerItemLink then
            local ok, link = pcall(_G.C_Container.GetContainerItemLink, bag, slot)
            if ok and type(link) == "string" and not IsSecret(link) then
                local id = ExtractIdFromLink(link)
                if id then
                    return link, id
                end
            end
        end
    end

    if _G.GetContainerItemLink then
        local ok, link = pcall(_G.GetContainerItemLink, bag, slot)
        if ok and type(link) == "string" and not IsSecret(link) then
            local id = ExtractIdFromLink(link)
            if id then
                return link, id
            end
        end
    end

    if _G.GetContainerItemInfo then
        local ok, _, _, _, _, _, _, link, _, _, itemId = pcall(_G.GetContainerItemInfo, bag, slot)
        if ok then
            local cleanLink = (type(link) == "string" and not IsSecret(link)) and link or nil
            local id = NormalizePositiveId(itemId) or ExtractIdFromLink(cleanLink)
            if id then
                return cleanLink, id
            end
        end
    end

    return nil, nil
end

local function QueryContainerStackCount(bag, slot, expectedItemId)
    if type(bag) ~= "number" or type(slot) ~= "number" then
        return nil
    end

    if _G.C_Container and _G.C_Container.GetContainerItemInfo then
        local ok, info = pcall(_G.C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" and not IsSecret(info) and info.stackCount and not IsSecret(info.stackCount) and info.stackCount > 1 then
            local slotItemId = NormalizePositiveId(info.itemID)
            if not expectedItemId or not slotItemId or slotItemId == expectedItemId then
                return math.floor(info.stackCount)
            end
        end
    end

    if _G.GetContainerItemInfo then
        local ok, _, itemCount, _, _, _, _, link = pcall(_G.GetContainerItemInfo, bag, slot)
        if ok and not IsSecret(itemCount) and type(itemCount) == "number" and itemCount > 1 then
            local slotItemId = ExtractIdFromLink(link)
            if not expectedItemId or not slotItemId or slotItemId == expectedItemId then
                return math.floor(itemCount)
            end
        end
    end

    return nil
end

local function GetSafeOwner(tooltip)
    if not tooltip then return nil end
    local ok, resolved = pcall(function()
        local owner = tooltip.GetOwner and tooltip:GetOwner()
        if not owner or IsSecret(owner) or type(owner) ~= "table" then
            return nil
        end
        -- Action bar buttons are secure action buttons and do not represent container stacks.
        -- In modern WoW (Patch 11.0.5+ / 12.0+), their text/counts are protected secret values.
        local hasAction = IsSecret(owner.action) or (owner.action ~= nil)
        local hasButtonType = IsSecret(owner.buttonType) or (owner.buttonType ~= nil)
        local isProtected = owner.IsProtected and owner:IsProtected()
        if hasAction or hasButtonType or isProtected then
            return nil
        end
        return owner
    end)
    if ok then
        return resolved
    end
    return nil
end

local function ExtractOwnerBagAndSlot(owner)
    if not owner then return nil, nil end
    local bag = (owner.GetBagID and owner:GetBagID())
        or owner.bagID
        or (owner.GetParent and owner:GetParent() and owner:GetParent().GetID and owner:GetParent():GetID())
    local slot = (owner.GetSlotIndex and owner:GetSlotIndex())
        or owner.slotID
        or (owner.GetID and owner:GetID())
    if IsSecret(bag) or IsSecret(slot) or type(bag) ~= "number" or type(slot) ~= "number" then
        return nil, nil
    end
    return bag, slot
end

local function ExtractOwnerItem(tooltip)
    local owner = GetSafeOwner(tooltip)
    if not owner then
        return nil, nil
    end

    local linkFields = { owner.itemLink, owner.hyperlink, owner.link }
    for i = 1, 3 do
        local candidate = linkFields[i]
        if type(candidate) == "string" and not IsSecret(candidate) then
            local id = ExtractIdFromLink(candidate)
            if id then
                return candidate, id
            end
        end
    end

    if type(owner.itemKey) == "table" and not IsSecret(owner.itemKey) then
        local keyId = NormalizePositiveId(owner.itemKey.itemID)
        if keyId then
            return nil, keyId
        end
    end

    if type(owner.rowData) == "table" and not IsSecret(owner.rowData) then
        local rowLink = owner.rowData.itemLink
        if type(rowLink) == "string" and not IsSecret(rowLink) then
            local rowLinkId = ExtractIdFromLink(rowLink)
            if rowLinkId then
                return rowLink, rowLinkId
            end
        end
        if type(owner.rowData.itemKey) == "table" and not IsSecret(owner.rowData.itemKey) then
            local rowKeyId = NormalizePositiveId(owner.rowData.itemKey.itemID)
            if rowKeyId then
                return nil, rowKeyId
            end
        end
    end

    local directOwnerId = NormalizePositiveId(owner.itemID)
    if directOwnerId then
        return nil, directOwnerId
    end

    local bag, slot = ExtractOwnerBagAndSlot(owner)
    if bag and slot then
        return QueryContainerItemLinkAndId(bag, slot)
    end

    return nil, nil
end

local function ExtractDataItem(tooltipData)
    if type(tooltipData) ~= "table" or IsSecret(tooltipData) then
        return nil, nil
    end
    local link = nil
    if type(tooltipData.hyperlink) == "string" and not IsSecret(tooltipData.hyperlink) then
        if ExtractIdFromLink(tooltipData.hyperlink) then
            link = tooltipData.hyperlink
        end
    end
    local id = NormalizePositiveId(tooltipData.id) or ExtractIdFromLink(link)
    return link, id
end

local function ExtractNestedItemFromData(tooltipData, excludeId)
    if type(tooltipData) ~= "table" or IsSecret(tooltipData) then
        return nil, nil
    end
    local lines = tooltipData.lines
    if type(lines) ~= "table" or IsSecret(lines) then
        return nil, nil
    end

    local itemDataType = (_G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Item) or 0
    local nestedBlockType = (_G.Enum and _G.Enum.TooltipDataLineType and _G.Enum.TooltipDataLineType.NestedBlock) or 19

    for i = 1, #lines do
        local line = lines[i]
        if type(line) == "table" and not IsSecret(line) then
            if type(line.tooltipData) == "table" and not IsSecret(line.tooltipData) then
                local tdType = line.tooltipData.type
                if tdType == nil or (not IsSecret(tdType) and tdType == itemDataType) then
                    local nestedLink, nestedId = ExtractDataItem(line.tooltipData)
                    if nestedId and nestedId ~= excludeId then
                        return nestedLink, nestedId
                    end
                end
            end

            local lineType = line.type
            local ttType = line.tooltipType
            if (not IsSecret(lineType) and lineType == nestedBlockType) or (not IsSecret(ttType) and ttType == itemDataType) then
                if ttType == nil or (not IsSecret(ttType) and ttType == itemDataType) then
                    local nestedId = NormalizePositiveId(line.tooltipID)
                    if nestedId and nestedId ~= excludeId then
                        return nil, nestedId
                    end
                end
            end

            if type(line.args) == "table" and not IsSecret(line.args) then
                local argTooltipId = nil
                local argTooltipType = nil
                local argNestedLink = nil
                for j = 1, #line.args do
                    local arg = line.args[j]
                    if type(arg) == "table" and not IsSecret(arg) and not IsSecret(arg.field) then
                        if arg.field == "tooltipData" and type(arg.tooltipDataVal) == "table" and not IsSecret(arg.tooltipDataVal) then
                            local nLink, nId = ExtractDataItem(arg.tooltipDataVal)
                            if nId and nId ~= excludeId then
                                return nLink, nId
                            end
                        elseif arg.field == "tooltipID" then
                            argTooltipId = NormalizePositiveId(arg.intVal)
                        elseif arg.field == "tooltipType" and not IsSecret(arg.intVal) then
                            argTooltipType = arg.intVal
                        elseif arg.field == "hyperlink" and type(arg.stringVal) == "string" and not IsSecret(arg.stringVal) then
                            argNestedLink = arg.stringVal
                        end
                    end
                end
                if argTooltipId and argTooltipId ~= excludeId and (argTooltipType == nil or argTooltipType == itemDataType) then
                    return argNestedLink, argTooltipId
                end
            end
        end
    end

    return nil, nil
end

local function ExtractGetItemFromTooltip(tooltip)
    if tooltip and tooltip.GetItem then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok and type(link) == "string" and not IsSecret(link) then
            local id = ExtractIdFromLink(link)
            if id then
                return link, id
            end
        end
    end

    if _G.TooltipUtil and type(_G.TooltipUtil.GetDisplayedItem) == "function" and tooltip then
        local ok, _, link, id = pcall(_G.TooltipUtil.GetDisplayedItem, tooltip)
        if ok then
            local cleanLink = (type(link) == "string" and not IsSecret(link) and ExtractIdFromLink(link)) and link or nil
            local cleanId = NormalizePositiveId(id) or ExtractIdFromLink(cleanLink)
            if cleanId then
                return cleanLink, cleanId
            end
        end
    end

    return nil, nil
end

local function ExtractStackCount(tooltip, state, itemId)
    if not tooltip then return 1 end

    if state and type(state.stackCount) == "number" and state.stackCount > 1 then
        return math.floor(state.stackCount)
    end

    if type(tooltip) == "table" then
        local mockCount = rawget(tooltip, "_pcfStackCount")
        if type(mockCount) == "number" and mockCount > 1 then
            return math.floor(mockCount)
        end
    end

    local owner = GetSafeOwner(tooltip)
    if not owner then return 1 end

    if not IsSecret(owner.count) and type(owner.count) == "number" and owner.count > 1 then
        return math.floor(owner.count)
    end
    if not IsSecret(owner.stackCount) and type(owner.stackCount) == "number" and owner.stackCount > 1 then
        return math.floor(owner.stackCount)
    end

    local ownerName = owner.GetName and owner:GetName()
    local countRegion = owner.Count or (ownerName and not IsSecret(ownerName) and _G[ownerName .. "Count"])
    local parsed = SafeGetNumberFromRegion(countRegion)
    if parsed and parsed > 1 then
        return math.floor(parsed)
    end

    local bag, slot = ExtractOwnerBagAndSlot(owner)
    local containerCount = QueryContainerStackCount(bag, slot, itemId)
    if containerCount and containerCount > 1 then
        return containerCount
    end

    return 1
end

local function IsPCFPriceLine(text)
    if text == nil or IsSecret(text) then return false end
    return SafeFind(text, "^AH%s+Price:") ~= nil
        or SafeFind(text, "^%s*Item%s+Price:") ~= nil
        or SafeFind(text, "^Recipe%s+Price:") ~= nil
end

local function UpdateOrAddTooltipPriceLines(tooltip, desiredLines)
    if not tooltip or type(desiredLines) ~= "table" or #desiredLines == 0 then
        return
    end

    local existingRegions = {}
    local numLines = tooltip.NumLines and tooltip:NumLines() or 0
    if numLines > 0 then
        for i = 1, numLines do
            local leftFontString = GetLeftFontString(tooltip, i)
            if leftFontString and leftFontString.GetText then
                local ok, existingText = pcall(leftFontString.GetText, leftFontString)
                if ok and IsPCFPriceLine(existingText) then
                    table.insert(existingRegions, leftFontString)
                end
            end
        end
    end

    for idx = 1, #desiredLines do
        local lineText = desiredLines[idx]
        local region = existingRegions[idx]
        if region and region.SetText then
            pcall(region.SetText, region, lineText)
        elseif tooltip.AddLine then
            pcall(tooltip.AddLine, tooltip, lineText, 1, 1, 1)
        end
    end

    if #existingRegions > #desiredLines then
        for idx = #desiredLines + 1, #existingRegions do
            local extraRegion = existingRegions[idx]
            if extraRegion and extraRegion.SetText then
                pcall(extraRegion.SetText, extraRegion, "")
            end
        end
    end

    if tooltip.Show then
        pcall(tooltip.Show, tooltip)
    end
end

function PCF.Tooltip.OnTooltipSetItem(tooltip, tooltipData)
    if not tooltip or IsForbiddenTooltip(tooltip) then return end

    pcall(function()
        local state = GetTooltipState(tooltip, true)

        local currentTitle = GetTooltipTitleText(tooltip)
        if currentTitle and state.titleText and currentTitle ~= state.titleText then
            ResetTooltipState(tooltip)
            state = GetTooltipState(tooltip, true)
        end
        if currentTitle then
            state.titleText = currentTitle
        end

        local primaryData = nil
        if tooltip.GetPrimaryTooltipData then
            local okPrimary, pd = pcall(tooltip.GetPrimaryTooltipData, tooltip)
            if okPrimary and type(pd) == "table" and not IsSecret(pd) then
                primaryData = pd
            end
        end

        local primaryDataLink, primaryDataId = ExtractDataItem(primaryData)
        local callDataLink, callDataId = ExtractDataItem(tooltipData)

        -- If TooltipDataProcessor invokes a post-call for an embedded NestedBlock item
        -- before the outer recipe finishes ProcessLines (including Blizzard_MoneyFrame),
        -- record the embedded crafted item ID without mutating tooltip regions mid-render.
        if primaryDataId and callDataId and callDataId ~= primaryDataId and not state.renderedOnce then
            RecordSeenItem(state, callDataLink, callDataId)
            return
        end

        local _, explicitId = RecordSeenItem(state, state.explicitLink, state.explicitId)
        local ownerId = nil
        if not explicitId then
            local rawOwnerLink, rawOwnerId = ExtractOwnerItem(tooltip)
            _, ownerId = RecordSeenItem(state, rawOwnerLink, rawOwnerId)
        end
        primaryDataLink, primaryDataId = RecordSeenItem(state, primaryDataLink, primaryDataId)
        callDataLink, callDataId = RecordSeenItem(state, callDataLink, callDataId)
        local getItemLink, getItemId = ExtractGetItemFromTooltip(tooltip)
        getItemLink, getItemId = RecordSeenItem(state, getItemLink, getItemId)

        -- Determine outer hovered item candidate
        local outerId = explicitId or ownerId or primaryDataId or callDataId or state.recipeId
        if not outerId and state.seenOrder then
            for i = 1, #state.seenOrder do
                local seenId = state.seenOrder[i]
                local seenLink = state.seenItems and state.seenItems[seenId] or nil
                if IsRecipeItem(seenLink, seenId) then
                    outerId = seenId
                    break
                end
            end
        end
        outerId = outerId or getItemId
        if not outerId then
            return
        end

        local outerLink = (state.seenItems and state.seenItems[outerId]) or nil
        outerLink = ResolveItemLinkFallback(outerLink, outerId)

        -- Check nested block lines on primaryData / tooltipData (e.g. modern recipe NestedBlock)
        local nestedLink, nestedId = ExtractNestedItemFromData(primaryData or tooltipData, outerId)
        if not nestedId and primaryData and tooltipData and primaryData ~= tooltipData then
            nestedLink, nestedId = ExtractNestedItemFromData(tooltipData, outerId)
        end
        if nestedId then
            nestedLink, nestedId = RecordSeenItem(state, nestedLink, nestedId)
        end

        local isRecipe = (state.recipeId ~= nil and state.recipeId == outerId)
            or IsRecipeItem(outerLink, outerId)

        -- If an earlier pass was not recognized as a recipe yet, check if any seen item is a recipe
        if not isRecipe and state.seenOrder then
            for i = 1, #state.seenOrder do
                local seenId = state.seenOrder[i]
                local seenLink = state.seenItems and state.seenItems[seenId] or nil
                if IsRecipeItem(seenLink, seenId) then
                    outerId = seenId
                    outerLink = ResolveItemLinkFallback(seenLink, outerId)
                    isRecipe = true
                    break
                end
            end
        end

        state.renderedOnce = true
        state.primaryResolvedId = outerId

        if isRecipe then
            local recipeId = outerId
            local recipeLink = outerLink
            state.recipeId = recipeId
            state.recipeLink = recipeLink

            local craftedId = nil
            if nestedId and nestedId ~= recipeId then
                craftedId = nestedId
            elseif getItemId and getItemId ~= recipeId then
                craftedId = getItemId
            elseif callDataId and callDataId ~= recipeId then
                craftedId = callDataId
            elseif state.craftedId and state.craftedId ~= recipeId then
                craftedId = state.craftedId
            elseif state.seenOrder then
                for i = 1, #state.seenOrder do
                    local seenId = state.seenOrder[i]
                    if seenId ~= recipeId then
                        craftedId = seenId
                        break
                    end
                end
            end

            local craftedLink = nil
            if craftedId then
                craftedLink = (state.seenItems and state.seenItems[craftedId]) or nestedLink or nil
                craftedLink = ResolveItemLinkFallback(craftedLink, craftedId)
                state.craftedId = craftedId
                state.craftedLink = craftedLink
            end

            -- Always resolve both AH prices first so TSM/Auctionator users passively harvest
            -- hovered recipe and crafted item prices into PCF_DB.prices even when showTooltip is off
            local recipePrice = PCF.ProviderRegistry.ResolveAHPrice(recipeLink, recipeId)
            local craftedPrice = nil
            if craftedId then
                craftedPrice = PCF.ProviderRegistry.ResolveAHPrice(craftedLink, craftedId)
            end

            if PCF_DB and PCF_DB.settings and PCF_DB.settings.showTooltip == false then
                return
            end

            local stackCount = ExtractStackCount(tooltip, state, recipeId)
            state.stackCountUsed = stackCount

            local recipeLine
            if recipePrice and recipePrice > 0 then
                local unitFormatted = PCF.Formatter.FormatTooltipMoney(recipePrice)
                if stackCount and stackCount > 1 then
                    local stackFormatted = PCF.Formatter.FormatTooltipMoney(recipePrice * stackCount)
                    recipeLine = string.format("Recipe Price: %s (%s)", stackFormatted, unitFormatted)
                else
                    recipeLine = string.format("Recipe Price: %s", unitFormatted)
                end
            else
                recipeLine = "Recipe Price: ??"
            end

            if craftedId then
                local craftedLine
                if craftedPrice and craftedPrice > 0 then
                    local craftedFormatted = PCF.Formatter.FormatTooltipMoney(craftedPrice)
                    craftedLine = string.format("   Item Price: %s", craftedFormatted)
                else
                    craftedLine = "   Item Price: ??"
                end
                UpdateOrAddTooltipPriceLines(tooltip, { craftedLine, recipeLine })
            else
                UpdateOrAddTooltipPriceLines(tooltip, { recipeLine })
            end
            return
        end

        -- Standard (non-recipe) item tooltip
        local itemLink = outerLink
        local itemId = outerId
        local ahPrice = PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)

        if PCF_DB and PCF_DB.settings and PCF_DB.settings.showTooltip == false then
            return
        end

        local stackCount = ExtractStackCount(tooltip, state, itemId)
        state.stackCountUsed = stackCount

        local lineText
        if ahPrice and ahPrice > 0 then
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

        UpdateOrAddTooltipPriceLines(tooltip, { lineText })
    end)
end

function PCF.Tooltip.RefreshVisibleTooltip()
    if _G.GameTooltip and (not _G.GameTooltip.IsShown or _G.GameTooltip:IsShown()) then
        PCF.Tooltip.OnTooltipSetItem(_G.GameTooltip)
    end
    if _G.ItemRefTooltip and (not _G.ItemRefTooltip.IsShown or _G.ItemRefTooltip:IsShown()) then
        PCF.Tooltip.OnTooltipSetItem(_G.ItemRefTooltip)
    end
end

local SETTER_LINK_RESOLVERS = {
    SetHyperlink = function(link)
        return link, nil, nil
    end,
    SetItemByID = function(itemId)
        return nil, itemId, nil
    end,
    SetItemKey = function(itemIdOrKey)
        if type(itemIdOrKey) == "table" and not IsSecret(itemIdOrKey) then
            return nil, itemIdOrKey.itemID, nil
        end
        return nil, itemIdOrKey, nil
    end,
    SetBagItem = function(bag, slot)
        local link, id = QueryContainerItemLinkAndId(bag, slot)
        local count = QueryContainerStackCount(bag, slot, id)
        return link, id, count
    end,
    SetAuctionItem = function(listType, index)
        if _G.GetAuctionItemLink then
            return _G.GetAuctionItemLink(listType, index), nil, nil
        end
    end,
    SetMerchantItem = function(index)
        if _G.GetMerchantItemLink then
            return _G.GetMerchantItemLink(index), nil, nil
        end
    end,
    SetBuybackItem = function(index)
        if _G.GetBuybackItemLink then
            return _G.GetBuybackItemLink(index), nil, nil
        end
    end,
    SetLootItem = function(slot)
        if _G.GetLootSlotLink then
            return _G.GetLootSlotLink(slot), nil, nil
        end
    end,
    SetLootRollItem = function(rollId)
        if _G.GetLootRollItemLink then
            return _G.GetLootRollItemLink(rollId), nil, nil
        end
    end,
    SetInboxItem = function(index, attachIndex)
        if _G.GetInboxItemLink then
            return _G.GetInboxItemLink(index, attachIndex or 1), nil, nil
        end
    end,
    SetSendMailItem = function(index)
        if _G.GetSendMailItemLink then
            return _G.GetSendMailItemLink(index), nil, nil
        end
    end,
    SetInventoryItem = function(unit, slot)
        if _G.GetInventoryItemLink then
            return _G.GetInventoryItemLink(unit, slot), nil, nil
        end
    end,
    SetGuildBankItem = function(tab, slot)
        if _G.GetGuildBankItemLink then
            return _G.GetGuildBankItemLink(tab, slot), nil, nil
        end
    end,
    SetQuestItem = function(qType, index)
        if _G.GetQuestItemLink then
            return _G.GetQuestItemLink(qType, index), nil, nil
        end
    end,
    SetQuestLogItem = function(qType, index)
        if _G.GetQuestLogItemLink then
            return _G.GetQuestLogItemLink(qType, index), nil, nil
        end
    end,
    SetTradePlayerItem = function(index)
        if _G.GetTradePlayerItemLink then
            return _G.GetTradePlayerItemLink(index), nil, nil
        end
    end,
    SetTradeTargetItem = function(index)
        if _G.GetTradeTargetItemLink then
            return _G.GetTradeTargetItemLink(index), nil, nil
        end
    end,
}

local function ApplyExplicitTooltipItem(tooltip, rawLink, rawId, stackCount)
    if not tooltip or IsForbiddenTooltip(tooltip) then return end
    local cleanLink = (type(rawLink) == "string" and not IsSecret(rawLink) and ExtractIdFromLink(rawLink)) and rawLink or nil
    local cleanId = NormalizePositiveId(rawId) or ExtractIdFromLink(cleanLink)
    local cleanStack = (not IsSecret(stackCount) and type(stackCount) == "number" and stackCount > 1) and math.floor(stackCount) or nil

    if not cleanId and not cleanStack then
        return
    end

    local state = GetTooltipState(tooltip, true)
    local needsRefresh = false
    if cleanStack and cleanStack ~= state.stackCountUsed then
        state.stackCount = cleanStack
        needsRefresh = true
    end

    if cleanId then
        state.explicitId = cleanId
        state.explicitLink = cleanLink
        RecordSeenItem(state, cleanLink, cleanId)
        if state.primaryResolvedId ~= cleanId then
            needsRefresh = true
        end
    end

    if needsRefresh and state.renderedOnce then
        PCF.Tooltip.OnTooltipSetItem(tooltip)
    end
end

local function HookTooltip(tooltip, skipScriptSetItem)
    if not tooltip or IsForbiddenTooltip(tooltip) or hookedTooltips[tooltip] then return end
    hookedTooltips[tooltip] = true

    if tooltip.HookScript then
        if not skipScriptSetItem then
            pcall(function()
                tooltip:HookScript("OnTooltipSetItem", function(self)
                    PCF.Tooltip.OnTooltipSetItem(self)
                end)
            end)
        end
        pcall(function()
            tooltip:HookScript("OnTooltipCleared", function(self)
                ResetTooltipState(self)
            end)
        end)
        pcall(function()
            tooltip:HookScript("OnHide", function(self)
                ResetTooltipState(self)
            end)
        end)
    end

    if _G.hooksecurefunc then
        if type(tooltip.ClearLines) == "function" then
            pcall(_G.hooksecurefunc, tooltip, "ClearLines", function(self)
                ResetTooltipState(self)
            end)
        end

        for methodName, resolver in pairs(SETTER_LINK_RESOLVERS) do
            if type(tooltip[methodName]) == "function" then
                pcall(_G.hooksecurefunc, tooltip, methodName, function(self, a, b)
                    if IsSecret(a) or IsSecret(b) then return end
                    local ok, link, id, stackCount = pcall(resolver, a, b)
                    if ok then
                        ApplyExplicitTooltipItem(self, link, id, stackCount)
                    end
                end)
            end
        end
    end
end

local function IsSupportedItemTooltip(tooltip)
    if not tooltip or IsForbiddenTooltip(tooltip) then
        return false
    end
    return tooltip == _G.GameTooltip
        or tooltip == _G.ItemRefTooltip
        or tooltip == _G.ShoppingTooltip1
        or tooltip == _G.ShoppingTooltip2
end

function PCF.Tooltip.Init()
    local hasTooltipDataProcessor = (_G.TooltipDataProcessor
        and _G.TooltipDataProcessor.AddTooltipPostCall
        and _G.Enum
        and _G.Enum.TooltipDataType
        and _G.Enum.TooltipDataType.Item) ~= nil

    HookTooltip(_G.GameTooltip, hasTooltipDataProcessor)
    HookTooltip(_G.ItemRefTooltip, hasTooltipDataProcessor)
    HookTooltip(_G.ShoppingTooltip1, hasTooltipDataProcessor)
    HookTooltip(_G.ShoppingTooltip2, hasTooltipDataProcessor)

    if hasTooltipDataProcessor then
        if not PCF.Tooltip._processorHooked then
            _G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Item, function(tooltip, data)
                if IsSupportedItemTooltip(tooltip) then
                    HookTooltip(tooltip, true)
                    PCF.Tooltip.OnTooltipSetItem(tooltip, data)
                end
            end)
            PCF.Tooltip._processorHooked = true
        end
    end
end
