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
    if type(msg) ~= "string" then return nil, nil, nil end

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
            if quantity < 1 then
                quantity = 1
            else
                quantity = math.floor(quantity)
            end
            return itemLink, tonumber(itemId), quantity
        end
    end

    return nil, nil, nil
end
