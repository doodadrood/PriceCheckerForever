local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.ItemParser = {}

-- Matches standard WoW item links (hex color or modern named color)
local ITEM_LINK_HEX_PATTERN = "^%[?(|c%x+|Hitem:%d+.-|h%[.-%]|h|r)"
local ITEM_LINK_NAMED_PATTERN = "^%[?(|cn[^:]+:|Hitem:%d+.-|h%[.-%]|h|r)"
local ITEM_LINK_RAW_PATTERN = "^%[?(|Hitem:%d+.-|h%[.-%]|h)"

local function ExtractLeadingTriggerRest(msg)
    local rest = msg:match("^%s*%?%s*(.+)$")
    if rest then
        return rest
    end

    rest = msg:match("^%s*[pP][cC]%s*(.+)$")
    if rest and (rest:find("^%[?|") or msg:find("^%s*[pP][cC]%s+")) then
        return rest
    end

    return nil
end

function PCF.ItemParser.Parse(msg)
    if type(msg) ~= "string" then return nil, nil end

    local rest = ExtractLeadingTriggerRest(msg)
    if not rest then return nil, nil end

    local itemLink = rest:match(ITEM_LINK_HEX_PATTERN)
        or rest:match(ITEM_LINK_NAMED_PATTERN)
        or rest:match(ITEM_LINK_RAW_PATTERN)

    if itemLink then
        local itemId = itemLink:match("item:(%d+)")
        if itemId then
            return itemLink, tonumber(itemId)
        end
    end

    return nil, nil
end
