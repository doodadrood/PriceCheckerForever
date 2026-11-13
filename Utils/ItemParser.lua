local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.ItemParser = {}

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

-- Matches standard WoW item links (hex color or modern named color)
local ITEM_LINK_HEX_PATTERN = "^%[?(|c%x+|Hitem:%d+.-|h%[.-%]|h|r)"
local ITEM_LINK_NAMED_PATTERN = "^%[?(|cn[^:]+:|Hitem:%d+.-|h%[.-%]|h|r)"
local ITEM_LINK_RAW_PATTERN = "^%[?(|Hitem:%d+.-|h%[.-%]|h)"

local function ExtractLeadingTriggerRest(msg)
    local ok, rest = pcall(function()
        local r = msg:match("^%s*%?%s*(.+)$")
        if r then
            return r
        end

        r = msg:match("^%s*[pP][cC]%s*(.+)$")
        if r and (r:find("^%[?|") or msg:find("^%s*[pP][cC]%s+")) then
            return r
        end

        return nil
    end)
    if ok and rest then
        return rest
    end
    return nil
end

function PCF.ItemParser.Parse(msg)
    if type(msg) ~= "string" or IsSecret(msg) then return nil, nil, nil end

    local rest = ExtractLeadingTriggerRest(msg)
    if not rest then return nil, nil, nil end

    local leadingQtyStr, afterLeading = rest:match("^(%d+)%s*[xX%*]%s*(.+)$")
    if not leadingQtyStr then
        leadingQtyStr, afterLeading = rest:match("^[xX%*]%s*(%d+)%s*(.+)$")
    end
    if leadingQtyStr and afterLeading then
        rest = afterLeading
    end

    local _, e, itemLink = rest:find(ITEM_LINK_HEX_PATTERN)
    if not itemLink then
        _, e, itemLink = rest:find(ITEM_LINK_NAMED_PATTERN)
    end
    if not itemLink then
        _, e, itemLink = rest:find(ITEM_LINK_RAW_PATTERN)
    end

    if itemLink then
        local itemId = itemLink:match("item:(%d+)")
        if itemId then
            local tail = rest:sub((e or #itemLink) + 1)
            local trailingQtyStr = tail:match("^%]?%s*[xX%*]%s*(%d+)")
                or tail:match("^%]?%s*(%d+)%s*[xX%*]")
            local quantity = tonumber(trailingQtyStr) or tonumber(leadingQtyStr) or 1
            if not (quantity >= 1) or quantity >= math.huge then
                quantity = 1
            else
                quantity = math.floor(quantity) + 0
            end
            return itemLink, tonumber(itemId), quantity
        end
    end

    return nil, nil, nil
end
