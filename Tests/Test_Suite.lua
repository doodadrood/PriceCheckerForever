package.path = package.path .. ";../?.lua;./?.lua"

local Mock = require("Tests.MockWoWAPI")

-- Namespace Setup
_G.PCF = {}

require("Config")
require("Utils.Formatter")
require("Utils.ItemParser")
require("Providers.ProviderRegistry")
require("Providers.TSMProvider")
require("Providers.AuctionatorProvider")
require("Providers.NativeProvider")
require("Modules.Consensus")
require("Modules.MeshSync")
require("Modules.Scanner")
require("Modules.ChatListener")
require("Modules.Tooltip")
require("Core")

local function Assert(condition, testName)
    if condition then
        print(string.format("[PASS] %s", testName))
    else
        print(string.format("[FAIL] %s", testName))
        error("Test assertion failed: " .. testName)
    end
end

-- 1. Parser Tests
local link1, id1, qty1 = PCF.ItemParser.Parse("?[|cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r]")
Assert(id1 == 19019 and qty1 == 1, "Parse standard ?[item] link")

local link2, id2, qty2 = PCF.ItemParser.Parse("   pc   |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r")
Assert(id2 == 19019 and qty2 == 1, "Parse pc[item] with irregular spacing")

local linkX, idX, qtyX = PCF.ItemParser.Parse("?|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|rx10")
Assert(idX == 2450 and qtyX == 10 and linkX == "|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r", "Parse ?[item]x10 stack multiplier")

local linkStar, idStar, qtyStar = PCF.ItemParser.Parse("? |cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r * 20")
Assert(idStar == 2450 and qtyStar == 20 and linkStar == "|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r", "Parse ?[item] * 20 stack multiplier")

-- Leading space & internal space variations for both ? and pc
local heavyLeatherLink = "|cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|r"
local lLeadQ, idLeadQ, qtyLeadQ = PCF.ItemParser.Parse(" ?|cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|rx20")
Assert(idLeadQ == 4234 and qtyLeadQ == 20 and lLeadQ == heavyLeatherLink, "Parse leading space before ?[item]x20")

local lNbspQ, idNbspQ, qtyNbspQ = PCF.ItemParser.Parse("\194\160 ?\194\160|cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|r\194\160x\194\16020")
Assert(idNbspQ == 4234 and qtyNbspQ == 20 and lNbspQ == heavyLeatherLink, "Parse UTF-8 non-breaking spaces in ? [item] x 20")

local lIntQ, idIntQ, qtyIntQ = PCF.ItemParser.Parse("  ?   |cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|r   x   20  ")
Assert(idIntQ == 4234 and qtyIntQ == 20 and lIntQ == heavyLeatherLink, "Parse leading, internal, and trailing spaces in ? [item] x 20")

local lLeadPC, idLeadPC, qtyLeadPC = PCF.ItemParser.Parse(" pc|cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|rx20")
Assert(idLeadPC == 4234 and qtyLeadPC == 20 and lLeadPC == heavyLeatherLink, "Parse leading space before pc[item]x20")

local lIntPC, idIntPC, qtyIntPC = PCF.ItemParser.Parse("   pc   |cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|r   x   20   ")
Assert(idIntPC == 4234 and qtyIntPC == 20 and lIntPC == heavyLeatherLink, "Parse leading and internal spaces in pc [item] x 20")

local lLeadQtyPC, idLeadQtyPC, qtyLeadQtyPC = PCF.ItemParser.Parse(" pc 20 x |cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|r")
Assert(idLeadQtyPC == 4234 and qtyLeadQtyPC == 20 and lLeadQtyPC == heavyLeatherLink, "Parse leading and internal spaces in pc 20 x [item]")

local link3, id3 = PCF.ItemParser.Parse("what is the price of this item?")
Assert(id3 == nil, "Reject input without trigger or item link")

-- 2. Currency Formatter Tests
Assert(PCF.Formatter.FormatMoney(0) == "0c", "Format 0 copper")
Assert(PCF.Formatter.FormatMoney(85) == "85c", "Format copper only")
Assert(PCF.Formatter.FormatMoney(1250) == "12s 50c", "Format silver and copper")
Assert(PCF.Formatter.FormatMoney(3501250) == "350g 12s 50c", "Format gold, silver, copper")
Assert(PCF.Formatter.FormatTooltipMoney(nil) == "??", "Format unknown tooltip money as ??")
Assert(PCF.Formatter.FormatTooltipMoney(0) == "??", "Format 0 tooltip money as ??")
Assert(PCF.Formatter.FormatTooltipMoney(303) == "3|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t 3|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t", "Format tooltip money with silver and copper coin icons")
Assert(PCF.Formatter.FormatTooltipMoney(3501250) == "350|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t 12|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t 50|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t", "Format tooltip money with gold, silver, and copper coin icons")

-- 3. Provider Fallback Test (Vendor Sell)
local price, source = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(price == 250000, "Resolve vendor price when 3rd party providers are missing")
Assert(source == "Vendor Base", "Correct source label for vendor fallback")

-- 4. Provider Priority Hierarchy Tests (Native -> Auctionator -> TSM)
PCF.LoadConfig()
PCF_DB.prices[19019] = { minBuyout = 500000, lastUpdated = math.floor(Mock.currentTime) - 3600, count = 2 }
local nativePrice, nativeSource = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(nativePrice == 500000 and nativeSource == "Native AH Scan (1h ago)", "Resolve Native AH cache over Vendor fallback")

_G.Auctionator = {
    API = {
        v1 = {
            GetAuctionPriceByItemLink = function(caller, link)
                return 750000
            end
        }
    }
}
local aucPrice, aucSource = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(aucPrice == 750000 and aucSource == "Auctionator", "Resolve Auctionator over Native AH cache")

_G.TSM_API = {
    GetCustomPriceValue = function(priceSource, itemStr)
        if priceSource == "DBMarket" then
            return 900000
        end
    end
}
local tsmPrice, tsmSource = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(tsmPrice == 900000 and tsmSource == "TSM DBMarket", "Resolve TSM DBMarket as highest priority provider")

-- TSM timestamp tests
-- A. TSM:GetLastScanTime(itemId) (e.g. 1 hour 15 minutes ago)
_G.TSM = {
    GetLastScanTime = function(self, itemId)
        if itemId == id1 then
            return time() - (75 * 60)
        end
    end
}
local tsmPriceWithTime, tsmSourceWithTime = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(tsmPriceWithTime == 900000 and tsmSourceWithTime == "TSM DBMarket (1h 15m ago)", "Resolve TSM DBMarket with relative timestamp from TSM:GetLastScanTime (1h 15m ago)")

-- B. TSM.db.realm.appDataUpdate (e.g. 35 minutes ago)
_G.TSM = {
    db = {
        realm = {
            appDataUpdate = time() - (35 * 60),
        }
    }
}
local _, tsmSourceApp = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(tsmSourceApp == "TSM DBMarket (35m ago)", "Resolve TSM DBMarket with relative timestamp from appDataUpdate (35m ago)")

-- C. TSM_API.GetPriceTimestamp (e.g. 2 hours ago)
_G.TSM = nil
_G.TSM_API.GetPriceTimestamp = function(source, target)
    return time() - (120 * 60)
end
local _, tsmSourceApi = PCF.ProviderRegistry.ResolvePrice(link1, id1)
Assert(tsmSourceApi == "TSM DBMarket (2h ago)", "Resolve TSM DBMarket with relative timestamp from TSM_API.GetPriceTimestamp (2h ago)")
_G.TSM_API.GetPriceTimestamp = nil

-- D. Chat price check message formatting with TSM timestamp
_G.TSM = {
    GetLastScanTime = function(self, itemId)
        if itemId == id1 then
            return time() - (75 * 60)
        end
    end
}
local _, chatReply = PCF.ChatListener.DispatchPriceReply(link1, id1, "WHISPER", "Friend", "Friend_TSM_Test", 1)
Assert(chatReply:find("%[TSM DBMarket %(1h 15m ago%)%]") ~= nil, "Format chat response with TSM relative timestamp (1h 15m ago)")
_G.TSM = nil
Mock.chatMessages = {}

-- 5. ChatListener & Consensus Protocol Tests
PCF.Consensus.Init()
PCF.ChatListener.Init()

-- Whisper response test
PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "GuildMate")
Assert(#Mock.chatMessages == 1 and Mock.chatMessages[1].channel == "WHISPER" and Mock.chatMessages[1].target == "GuildMate", "Send immediate whisper response on valid query")

-- Rate-limit cooldown test (same sender within 3s)
PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "GuildMate")
Assert(#Mock.chatMessages == 1, "Enforce 3.0s per-sender rate limit cooldown")

-- Self-message ignore test
PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "LocalPlayer")
Assert(#Mock.chatMessages == 1, "Ignore queries sent by LocalPlayer")

-- Guild consensus deduplication test
Mock.currentTime = 1010.0
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "pc |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "GuildMate")
Assert(#Mock.timers == 1, "Schedule backoff timer for Guild query")
Mock.timers[1].callback()
Assert(#Mock.addonMessages == 1 and Mock.addonMessages[1].prefix == "PCF_SYNC", "Broadcast PCF_SYNC CLAIM before guild chat response")
Assert(#Mock.chatMessages == 2 and Mock.chatMessages[2].channel == "GUILD", "Broadcast price response to GUILD chat")

-- Peer claim suppression test
Mock.currentTime = 1080.0
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "GuildMate")
local pendingTimer = Mock.timers[#Mock.timers]
local expectedBucket = math.floor(Mock.currentTime / 60)
PCF.Consensus.frame:Trigger("CHAT_MSG_ADDON", "PCF_SYNC", string.format("CLAIM:19019_%d", expectedBucket), "GUILD", "OtherNode")
pendingTimer.callback()
Assert(#Mock.chatMessages == 2, "Suppress Guild chat response when peer claims hash first")

-- Stack quantity multiplier chat response test (?[Briarthorn]x10 and *10) & exact minute scan age
local savedTSM, savedAuc = _G.TSM_API, _G.Auctionator
_G.TSM_API, _G.Auctionator = nil, nil
PCF_DB.lastFullScan = math.floor(Mock.currentTime)
PCF_DB.prices[2450] = { minBuyout = 95, minBid = 90, lastUpdated = math.floor(Mock.currentTime), count = 1, source = "Scan" }
Mock.currentTime = 1100.0
PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "?|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|rx10", "GuildMate")
Assert(
    Mock.chatMessages[#Mock.chatMessages].msg == "Price check for |cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r: 9s 50c (95c ea) {Vendor: N/A} [Native AH Scan (0m ago)]",
    "Format stack and unit price in chat response for ?[item]x10 (unsellable / N/A vendor)"
)
-- Advance time by 14 minutes (840s) and verify chat reply says (14m ago) matching AH banner
Mock.currentTime = 1080.0 + (14 * 60)
PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "?|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r*5", "GuildMate")
Assert(
    Mock.chatMessages[#Mock.chatMessages].msg == "Price check for |cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r: 4s 75c (95c ea) {Vendor: N/A} [Native AH Scan (14m ago)]",
    "Format stack and unit price with exact minute age (14m ago) for ?[item]*5"
)
PCF_DB.prices[2450] = nil
PCF_DB.lastFullScan = 0

-- Vendor price formatting in chat response (single item, stack, and No AH data fallback)
local origGetItemInfo = _G.GetItemInfo
_G.GetItemInfo = function(itemId)
    if itemId == 8831 then
        -- Purple Lotus: vendor sell 3s (300c)
        return "Purple Lotus", nil, 1, 45, 0, "Trade Goods", "Herb", 20, "", 1, 300
    end
    return origGetItemInfo(itemId)
end
local purpleLotusLink = "|cffffffff|Hitem:8831:0:0:0|h[Purple Lotus]|h|r"
PCF_DB.prices[8831] = { minBuyout = 605, minBid = 600, lastUpdated = math.floor(Mock.currentTime) - (52 * 60), count = 20, source = "PCF Sniff" }
local _, lotusStackReply = PCF.ChatListener.DispatchPriceReply(purpleLotusLink, 8831, "WHISPER", "GuildMate", "Lotus_Stack_Test", 20)
Assert(
    lotusStackReply == "Price check for |cffffffff|Hitem:8831:0:0:0|h[Purple Lotus]|h|r: 1g 21s (6s 5c ea) {Vendor: 60s / 3s ea} [PCF Sniff (52m ago)]",
    "Format stack AH price and stack/unit vendor price in squiggly brackets"
)
local _, lotusSingleReply = PCF.ChatListener.DispatchPriceReply(purpleLotusLink, 8831, "WHISPER", "GuildMate", "Lotus_Single_Test", 1)
Assert(
    lotusSingleReply == "Price check for |cffffffff|Hitem:8831:0:0:0|h[Purple Lotus]|h|r: 6s 5c {Vendor: 3s} [PCF Sniff (52m ago)]",
    "Format single-item AH price and unit vendor price in squiggly brackets"
)
PCF_DB.prices[8831] = nil
local _, lotusNoAHStackReply = PCF.ChatListener.DispatchPriceReply(purpleLotusLink, 8831, "WHISPER", "GuildMate", "Lotus_NoAH_Stack_Test", 20)
Assert(
    lotusNoAHStackReply == "Price check for |cffffffff|Hitem:8831:0:0:0|h[Purple Lotus]|h|r: No AH data {Vendor: 60s / 3s ea}",
    "Format No AH data with stack/unit vendor price when no AH price exists"
)
local _, lotusNoAHSingleReply = PCF.ChatListener.DispatchPriceReply(purpleLotusLink, 8831, "WHISPER", "GuildMate", "Lotus_NoAH_Single_Test", 1)
Assert(
    lotusNoAHSingleReply == "Price check for |cffffffff|Hitem:8831:0:0:0|h[Purple Lotus]|h|r: No AH data {Vendor: 3s}",
    "Format No AH data with unit vendor price when no AH price exists"
)
local _, noAHNoVendorReply = PCF.ChatListener.DispatchPriceReply("|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r", 2450, "WHISPER", "GuildMate", "Briar_NoAH_NoVendor_Test", 1)
Assert(
    noAHNoVendorReply == "Price check for |cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r: No AH data {Vendor: N/A}",
    "Format No AH data with {Vendor: N/A} when neither AH nor vendor price exists"
)
_G.GetItemInfo = origGetItemInfo

-- Guild consensus: claims are keyed by item only (GetTime() differs on every machine, so no clock in the key)
Mock.currentTime = 2000.0
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "GuildMate")
local itemClaimTimer = Mock.timers[#Mock.timers]
local chatBeforeItemClaim = #Mock.chatMessages
PCF.Consensus.frame:Trigger("CHAT_MSG_ADDON", "PCF_SYNC", "CLAIM:19019", "GUILD", "OtherNode")
itemClaimTimer.callback()
Assert(#Mock.chatMessages == chatBeforeItemClaim, "Suppress Guild chat response on item-only CLAIM payload")

-- A visible reply from another player also counts as a claim
Mock.currentTime = 2100.0
local timersBeforeVisible = #Mock.timers
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "Price check for |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r: 50g 00s 00c [Native AH Scan (1h ago)]", "OtherNode")
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "GuildMate")
Assert(#Mock.timers == timersBeforeVisible, "Stay silent when another player's price reply was already seen in guild chat")

-- Follow-up guild queries for the same item after the 3s sender cooldown (including leading & internal spaces) still get answered
PCF_DB.prices[4234] = { minBuyout = 250, minBid = 200, lastUpdated = math.floor(Mock.currentTime), count = 20, source = "PCF Sniff" }
Mock.currentTime = 2110.0
local chatBeforeFollowUp = #Mock.chatMessages
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "?|cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|rx20", "Ferris Zeusler")
Mock.timers[#Mock.timers].callback()
Assert(#Mock.chatMessages == chatBeforeFollowUp + 1, "First guild query ?[Heavy Leather]x20 responds")

Mock.currentTime = 2115.0 -- 5s later (> 3s sender cooldown, previously blocked by 60s claim window)
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", " ?|cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|rx20", "Ferris Zeusler")
Mock.timers[#Mock.timers].callback()
Assert(#Mock.chatMessages == chatBeforeFollowUp + 2, "Second guild query with leading space ' ?[Heavy Leather]x20' responds after 3s cooldown")

Mock.currentTime = 2120.0 -- another 5s later with internal spaces
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? |cffffffff|Hitem:4234:0:0:0|h[Heavy Leather]|h|r x 20", "Ferris Zeusler")
Mock.timers[#Mock.timers].callback()
Assert(#Mock.chatMessages == chatBeforeFollowUp + 3, "Third guild query with internal spaces '? [Heavy Leather] x 20' responds")
PCF_DB.prices[4234] = nil

-- Players with no data wait their turn (>= 3s) and ask peers for just that item
Mock.currentTime = 2200.0
local mysteryLink = "|cffffffff|Hitem:77001:0:0:0|h[Mystery Item]|h|r"
local timersBeforeNoData, addonMsgsBeforeNoData = #Mock.timers, #Mock.addonMessages
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? " .. mysteryLink, "GuildMate")
local noDataTimer
for i = timersBeforeNoData + 1, #Mock.timers do
    if Mock.timers[i].delay >= 3.0 then noDataTimer = Mock.timers[i] end
end
Assert(noDataTimer ~= nil, "Players with no data wait at least 3s before answering a guild price check")
for i = timersBeforeNoData + 1, #Mock.timers do
    if Mock.timers[i].delay < 1.0 then Mock.timers[i].callback() end
end
local sentReqItem = false
for i = addonMsgsBeforeNoData + 1, #Mock.addonMessages do
    if Mock.addonMessages[i].msg == "REQ_ITEM:77001" and Mock.addonMessages[i].prefix == "PCF_SYNC" then sentReqItem = true end
end
Assert(sentReqItem, "No-data guild price check broadcasts REQ_ITEM for just that item")

-- Same item again: no repeat REQ_ITEM within the 5 minute per-item cooldown (only the answer timer is added)
Mock.currentTime = 2210.0
local timersBeforeRepeat = #Mock.timers
PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? " .. mysteryLink, "GuildMate2")
Assert(#Mock.timers == timersBeforeRepeat + 1, "Do not re-request the same item within the per-item cooldown")

-- If peer data arrives while waiting, the delayed reply uses it (price is re-resolved at send time)
PCF.MeshSync.ApplyDeltaPayload(string.format("DELTA:77001:5000:%d", time() - 100))
local chatBeforeLate = #Mock.chatMessages
noDataTimer.callback()
local lateReply = Mock.chatMessages[#Mock.chatMessages]
Assert(#Mock.chatMessages == chatBeforeLate + 1 and lateReply.channel == "GUILD" and lateReply.msg:find("50s", 1, true) and lateReply.msg:find("PCF Mesh", 1, true), "Delayed guild reply uses peer data that arrived while waiting")
PCF_DB.prices[77001] = nil

-- Secret sender in dungeon/instance chat tests
local secretChatSender = setmetatable({}, {
    __eq = function()
        error("attempt to compare local 'sender' (a secret string value, while execution tainted by 'PriceCheckerForever')")
    end,
    __index = function(_, k)
        error("attempt to index local 'sender' (a secret string value, while execution tainted by 'PriceCheckerForever')")
    end,
    __tostring = function() return "SecretSender" end,
})
_G.issecretvalue = function(v) return v == secretChatSender end

local okGuildSecret = pcall(function()
    PCF.ChatListener.frame:Trigger("CHAT_MSG_GUILD", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", secretChatSender)
end)
Assert(okGuildSecret == true, "Guild chat query with secret sender does not crash in dungeon")

local okWhisperSecret = pcall(function()
    PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "? |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", secretChatSender)
end)
Assert(okWhisperSecret == true, "Whisper query with secret sender does not crash and safely drops")

_G.issecretvalue = nil

_G.TSM_API, _G.Auctionator = savedTSM, savedAuc

-- 6. AH Scanner, UI Button, Progress Bar & TOC Loader Integration Test
_G.AuctionFrame = CreateFrame("Frame", "AuctionFrame")
_G.CanSendAuctionQuery = function() return true end
_G.QueryAuctionItems = function() end
_G.GetNumAuctionItems = function() return 50, 100 end -- 2 pages total
_G.GetAuctionItemInfo = function(_, index)
    return "Arcanite Bar", nil, 2, 1, nil, 1, nil, 280000, 0, 290000, 0, nil, 0, "Seller", nil, 0, 12360
end

local tocAddonTable = {}
for line in io.lines("PriceCheckerForever.toc") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#") then
        local chunk, err = loadfile(trimmed)
        Assert(chunk ~= nil, "TOC file loadable: " .. trimmed .. (err and (" (" .. err .. ")") or ""))
        chunk("PriceCheckerForever", tocAddonTable)
    end
end

tocAddonTable.coreFrame:Trigger("ADDON_LOADED", "PriceCheckerForever")
Assert(type(SlashCmdList["PRICECHECKERFOREVER"]) == "function" and SLASH_PRICECHECKERFOREVER1 == "/pcf", "Register /pcf slash command on ADDON_LOADED")

-- Verify auto-disable of scan button & tooltip when TSM/Auctionator are detected
Assert(PCF_DB.settings.showScanButton == false and PCF_DB.settings.showTooltip == false, "Auto-disable AH scan button and tooltip when TSM/Auctionator are installed")

tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
Assert(tocAddonTable.Scanner.scanButton == nil, "Prevent AH scan button creation when showScanButton is off")

_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Linen Cloth")
_G.GameTooltip:AddLine("Sell Price: 3s3c")
_G.GameTooltip:SetItem("Linen Cloth", "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r")
Assert(_G.GameTooltip.lines[#_G.GameTooltip.lines] == "Sell Price: 3s3c", "Prevent tooltip AH Price line when showTooltip is off")

-- Enable scan button via /pcf button and tooltip via /pcf tooltip
SlashCmdList["PRICECHECKERFOREVER"]("button")
Assert(PCF_DB.settings.showScanButton == true, "/pcf button toggles showScanButton ON")
Assert(tocAddonTable.Scanner.scanButton ~= nil and tocAddonTable.Scanner.scanButton.shown == true, "Create and show 'PCF Scan' button on AuctionFrame when toggled ON")
Assert(tocAddonTable.Scanner.scanButton:GetText() == "PCF Scan", "Initial AH scan button label is 'PCF Scan'")

SlashCmdList["PRICECHECKERFOREVER"]("tooltip")
Assert(PCF_DB.settings.showTooltip == true, "/pcf tooltip toggles showTooltip ON")

-- Start scan via clicking the AH Scan button
tocAddonTable.Scanner.scanButton:Click()
Assert(tocAddonTable.Scanner.scanButton:GetText() == "Stop Scan", "Button switches to 'Stop Scan' while scanning")

-- Simulate Page 1 of 2 arriving after 1 second
Mock.currentTime = Mock.currentTime + 1.0
tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
Assert(tocAddonTable.Scanner.progressBar:GetValue() == 1, "Progress bar updates to page 1 of 2")
Assert(tocAddonTable.Scanner.progressText:GetText():find("50%%") ~= nil, "Progress text displays 50% and ETA")

-- Simulate duplicate AUCTION_ITEM_LIST_UPDATE events for the same page (item cache updates)
tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
Assert(tocAddonTable.Scanner.progressBar:GetValue() == 1, "Ignore duplicate AUCTION_ITEM_LIST_UPDATE events before next page query")

-- Fire the scheduled next-page timer to request Page 2 of 2, then trigger AUCTION_ITEM_LIST_UPDATE
Mock.timers[#Mock.timers].callback()
_G.GetNumAuctionItems = function() return 50, 100 end
Mock.currentTime = Mock.currentTime + 1.0
tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
Assert(tocAddonTable.Scanner.scanButton:GetText() == "PCF Scan", "Button resets to 'PCF Scan' on scan completion")
Assert(tocAddonTable.Scanner.progressText:GetText():find("100%% Done") ~= nil, "Progress text shows 100% Done on completion")
Assert(PCF_DB.prices[12360] and PCF_DB.prices[12360].minBuyout == 145000, "Scanner computes unit buyout (290000 / 2 = 145000c)")

-- Modern C_AuctionHouse scan test: uses SendBrowseQuery as primary fast path with empty sorts = {}
local savedQueryAuctionItems = _G.QueryAuctionItems
_G.QueryAuctionItems = nil
local browseQueryCalled = false
local capturedBrowseQuery = nil
local replicateCalledDuringPrimary = false
local browseResultsData = {
    { itemKey = { itemID = 13468 }, minPrice = 42000, totalQuantity = 12 },
}
_G.C_AuctionHouse = {
    ReplicateItems = function()
        replicateCalledDuringPrimary = true
    end,
    SendBrowseQuery = function(q)
        browseQueryCalled = true
        capturedBrowseQuery = q
    end,
    GetBrowseResults = function()
        return browseResultsData
    end,
    HasFullBrowseResults = function()
        return true
    end,
}
Mock.currentTime = Mock.currentTime + 540
PCF_DB.lastReplicateScan = 0 -- Even when ReplicateItems is off cooldown, SendBrowseQuery is primary
tocAddonTable.Scanner.scanButton:Click()
Assert(browseQueryCalled == true and replicateCalledDuringPrimary == false, "Use C_AuctionHouse.SendBrowseQuery as primary modern scan path without calling ReplicateItems")
Assert(type(capturedBrowseQuery) == "table" and type(capturedBrowseQuery.sorts) == "table" and #capturedBrowseQuery.sorts == 0, "Pass empty sorts = {} in StartModernBrowseScan")
tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
Assert(tocAddonTable.Scanner.scanButton:GetText() == "PCF Scan", "Browse-all scan completes cleanly without hanging")
Assert(PCF_DB.prices[13468] and PCF_DB.prices[13468].minBuyout == 42000, "Browse-all scan records item minPrice accurately")

-- Replicate-first API scan (/pcf replicate mode): waits for REPLICATE_ITEM_LIST_UPDATE and only falls back to browse after the timeout
SlashCmdList["PRICECHECKERFOREVER"]("replicate")
Assert(PCF_DB.settings.preferReplicateScan == true, "/pcf replicate enables preferReplicateScan mode")
local replicateCalls, replicateBrowseCalls = 0, 0
local replicateData = {}
_G.C_AuctionHouse = {
    ReplicateItems = function() replicateCalls = replicateCalls + 1 end,
    SendBrowseQuery = function() replicateBrowseCalls = replicateBrowseCalls + 1 end,
    GetBrowseResults = function() return {} end,
    HasFullBrowseResults = function() return true end,
    GetNumReplicateItems = function() return #replicateData end,
    GetReplicateItemInfo = function(index)
        local e = replicateData[index + 1]
        return nil, nil, e.count, 1, nil, 1, nil, e.minBid, 0, e.buyoutPrice, 0, nil, 0, nil, nil, 0, e.itemId
    end,
}
local scanner = tocAddonTable.Scanner
local function FindTimerByDelay(delay, startIndex)
    for i = #Mock.timers, startIndex, -1 do
        if Mock.timers[i].delay == delay then return Mock.timers[i] end
    end
end

-- A. API data arrives: processed without ever starting browse pagination
PCF_DB.lastReplicateScan = 0
replicateData = { { count = 1, minBid = 900, buyoutPrice = 1000, itemId = 14001 } }
scanner.scanButton:Click()
Assert(replicateCalls == 1 and replicateBrowseCalls == 0, "Replicate-first scan calls ReplicateItems without starting browse pagination")
scanner.frame:Trigger("REPLICATE_ITEM_LIST_UPDATE")
Assert(PCF_DB.prices[14001] and PCF_DB.prices[14001].minBuyout == 1000 and scanner.scanButton:GetText() == "PCF Scan", "Replicate scan records API data and completes")
Assert(PCF_DB.lastReplicateScan > 0, "Replicate scan stamps lastReplicateScan")

-- B. An empty first REPLICATE_ITEM_LIST_UPDATE keeps waiting instead of dropping to browse
PCF_DB.lastReplicateScan = 0
replicateData = {}
scanner.scanButton:Click()
scanner.frame:Trigger("REPLICATE_ITEM_LIST_UPDATE")
Assert(replicateBrowseCalls == 0 and scanner.scanButton:GetText() == "Stop Scan", "Empty first REPLICATE_ITEM_LIST_UPDATE keeps waiting instead of falling back to browse")
replicateData = { { count = 2, minBid = 1800, buyoutPrice = 2000, itemId = 14002 } }
scanner.frame:Trigger("REPLICATE_ITEM_LIST_UPDATE")
Assert(PCF_DB.prices[14002] and PCF_DB.prices[14002].minBuyout == 1000 and scanner.scanButton:GetText() == "PCF Scan", "Replicate scan completes once real data follows an empty update")

-- C. Timeout falls back to browse (after 15s), but late API data still takes over
PCF_DB.lastReplicateScan = 0
replicateData = {}
local timersBeforeC = #Mock.timers
scanner.scanButton:Click()
local timeoutTimer = FindTimerByDelay(15.0, timersBeforeC + 1)
Assert(timeoutTimer ~= nil, "Replicate scan waits 15s for API data before falling back")
timeoutTimer.callback()
Assert(replicateBrowseCalls == 1 and scanner.scanButton:GetText() == "Stop Scan", "Fall back to browse scan after replicate timeout")
replicateData = { { count = 1, minBid = 7000, buyoutPrice = 7500, itemId = 14003 } }
scanner.frame:Trigger("REPLICATE_ITEM_LIST_UPDATE")
Assert(PCF_DB.prices[14003] and PCF_DB.prices[14003].minBuyout == 7500 and scanner.scanButton:GetText() == "PCF Scan", "Late API data takes over from the browse fallback")

-- D. A timed-out replicate still burned the server cooldown: an immediate retry goes straight to browse
PCF_DB.lastReplicateScan = 0
replicateData = {}
local timersBeforeD = #Mock.timers
scanner.scanButton:Click()
local callsAfterRequest = replicateCalls
FindTimerByDelay(15.0, timersBeforeD + 1).callback()
scanner.scanButton:Click() -- Stop Scan
Assert(scanner.scanButton:GetText() == "PCF Scan", "Stop Scan aborts the browse fallback")
local browseBeforeRetry = replicateBrowseCalls
scanner.scanButton:Click()
Assert(replicateCalls == callsAfterRequest and replicateBrowseCalls == browseBeforeRetry + 1, "Retry after a timed-out replicate goes straight to browse")
scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
Assert(scanner.scanButton:GetText() == "PCF Scan", "Browse retry completes cleanly")
SlashCmdList["PRICECHECKERFOREVER"]("replicate")
Assert(PCF_DB.settings.preferReplicateScan == false, "/pcf replicate toggles preferReplicateScan back OFF")
_G.C_AuctionHouse = nil
_G.QueryAuctionItems = savedQueryAuctionItems

-- 7. Tooltip AH Price Display Tests
_G.TSM_API = nil
_G.Auctionator = nil
PCF_DB.prices[2589] = nil
_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Linen Cloth")
_G.GameTooltip:AddLine("Sell Price: 3s3c")
_G.GameTooltip:SetItem("Linen Cloth", "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r")
Assert(_G.GameTooltip.lines[#_G.GameTooltip.lines] == "AH  Price: ??", "Tooltip displays aligned 'AH  Price: ??' below Sell Price when AH price is unknown")

_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Arcanite Bar")
_G.GameTooltip:AddLine("Sell Price: 10s")
_G.GameTooltip:SetItem("Arcanite Bar", "|cff1eff00|Hitem:12360:0:0:0|h[Arcanite Bar]|h|r")
Assert(_G.GameTooltip.lines[#_G.GameTooltip.lines] == "AH  Price: 14|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t 50|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t", "Tooltip displays aligned 'AH  Price:' with coin icons when AH price is known")

-- Stack tooltip test: stack of 5 items at 10c each -> "AH  Price: 50c (10c)" with coin icons
PCF_DB.prices[99901] = { minBuyout = 10, minBid = 10, lastUpdated = math.floor(Mock.currentTime), count = 5, source = "Scan" }
_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Peacebloom")
_G.GameTooltip:AddLine("Sell Price: 15c")
_G.GameTooltip:SetItem("Peacebloom", "|cffffffff|Hitem:99901:0:0:0|h[Peacebloom]|h|r", 5)
Assert(
    _G.GameTooltip.lines[#_G.GameTooltip.lines] == "AH  Price: 50|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t (10|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t)",
    "Tooltip displays stack price followed by unit price in parentheses for stacks > 1"
)
PCF_DB.prices[99901] = nil

-- Secret string value & ActionButton security tests
local secretString = setmetatable({}, {
    __index = function(_, k)
        error("attempt to index local 'text' (a secret string value, while execution tainted by 'PriceCheckerForever')")
    end,
    __tostring = function() return "secret" end,
})
_G.issecretvalue = function(v) return v == secretString end

-- A. ActionButton owner with action property and secret count
local mockActionButton = {
    action = 1,
    IsProtected = function() return true end,
    Count = {
        GetText = function() return secretString end,
        IsShown = function() return true end,
    },
}
_G.GameTooltip:SetOwner(mockActionButton)
_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Health Potion")
local okActionHover = pcall(function()
    _G.GameTooltip:SetItem("Health Potion", "|cffffffff|Hitem:12360:0:0:0|h[Arcanite Bar]|h|r")
end)
Assert(okActionHover == true, "ActionButton hover with secret count text does not crash")
Assert(_G.GameTooltip.lines[#_G.GameTooltip.lines]:find("^AH%s+Price:"), "ActionButton hover adds AH Price line safely")

-- B. Tooltip with existing secret text line does not crash when scanned for AH Price prefix
_G.GameTooltip:SetOwner(nil)
_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Spell Tooltip")
-- Inject a line whose GetText returns a secret value
_G.GameTooltipTextLeft1 = {
    GetText = function() return secretString end,
    SetText = function() end,
}
local okSecretLine = pcall(function()
    _G.GameTooltip:SetItem("Health Potion", "|cffffffff|Hitem:12360:0:0:0|h[Arcanite Bar]|h|r")
end)
Assert(okSecretLine == true, "Tooltip line with secret text does not crash when inspecting lines")
_G.issecretvalue = nil

-- Verify toggling off hides button and suppresses tooltip again
SlashCmdList["PRICECHECKERFOREVER"]("button")
Assert(PCF_DB.settings.showScanButton == false and tocAddonTable.Scanner.scanButton.shown == false, "/pcf button hides AH scan button when toggled OFF")
SlashCmdList["PRICECHECKERFOREVER"]("tooltip")
Assert(PCF_DB.settings.showTooltip == false, "/pcf tooltip toggles showTooltip OFF")

-- 8. Passive Browse-Sniffing Tests (AUCTION_ITEM_LIST_UPDATE while not scanning)
Mock.auctionListings = {
    { name = "Lesser Moonstone", itemId = 1705, count = 5, minBid = 3000, buyoutPrice = 3500 }, -- 700c unit
    { name = "Lesser Moonstone", itemId = 1705, count = 2, minBid = 1200, buyoutPrice = 1240 }, -- 620c unit (lowest!)
    { name = "Dreamfoil", itemId = 13463, count = 20, minBid = 180000, buyoutPrice = 200000 }, -- 10000c unit (1g)
}
_G.GetNumAuctionItems = function() return #Mock.auctionListings, #Mock.auctionListings end
_G.GetAuctionItemInfo = function(_, index)
    local e = Mock.auctionListings[index]
    if not e then return nil end
    return e.name, nil, e.count, 1, nil, 1, nil, e.minBid, 0, e.buyoutPrice, 0, nil, 0, "Seller", nil, 0, e.itemId
end

tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
Assert(PCF_DB.prices[1705] and PCF_DB.prices[1705].minBuyout == 620, "Passive browse-sniffing computes lowest unit buyout (1240 / 2 = 620c)")
Assert(PCF_DB.prices[1705].source == "PCF Sniff", "Passive browse-sniffing tags entry source as 'PCF Sniff'")
Assert(PCF_DB.prices[13463] and PCF_DB.prices[13463].minBuyout == 10000, "Passive browse-sniffing records multiple unique items from visible page")

local sniffPrice, sniffSource = tocAddonTable.ProviderRegistry.ResolvePrice("|cff1eff00|Hitem:1705:0:0:0|h[Lesser Moonstone]|h|r", 1705)
Assert(sniffPrice == 620 and sniffSource:find("^PCF Sniff") ~= nil, "NativeProvider reports 'PCF Sniff' source tag for sniffed items")

-- Sell window sniffing: COMMODITY_SEARCH_RESULTS_UPDATED & ITEM_SEARCH_RESULTS_UPDATED overwrite stale stored price
_G.C_AuctionHouse = {
    GetNumCommoditySearchResults = function(itemId)
        return itemId == 1705 and 2 or 0
    end,
    GetCommoditySearchResultInfo = function(itemId, index)
        if itemId == 1705 then
            if index == 1 then return { itemID = 1705, quantity = 10, unitPrice = 940 } end
            if index == 2 then return { itemID = 1705, quantity = 5, unitPrice = 1100 } end
        end
        return nil
    end,
    GetNumItemSearchResults = function(itemKey)
        return (type(itemKey) == "table" and itemKey.itemID == 12360) and 1 or 0
    end,
    GetItemSearchResultInfo = function(itemKey, index)
        if type(itemKey) == "table" and itemKey.itemID == 12360 and index == 1 then
            return { itemKey = itemKey, buyoutAmount = 165000, minBid = 150000, quantity = 1 }
        end
        return nil
    end,
}
tocAddonTable.Scanner.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 1705)
Assert(PCF_DB.prices[1705] and PCF_DB.prices[1705].minBuyout == 940 and PCF_DB.prices[1705].count == 15, "Sell window COMMODITY_SEARCH_RESULTS_UPDATED updates stored item price to current sell price")

tocAddonTable.Scanner.frame:Trigger("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 12360 })
Assert(PCF_DB.prices[12360] and PCF_DB.prices[12360].minBuyout == 165000, "Sell window ITEM_SEARCH_RESULTS_UPDATED updates stored item price to current sell price")
_G.C_AuctionHouse = nil

-- 9. Third-Party Addon Channel Eavesdropping Tests
tocAddonTable.MeshSync.frame:Trigger("CHAT_MSG_ADDON", "TSM_SYNC", "16203:85000|16204:12000", "GUILD", "OtherGuildie")
Assert(PCF_DB.prices[16203] and PCF_DB.prices[16203].minBuyout == 85000 and PCF_DB.prices[16203].source == "PCF Sniff", "Eavesdrop external addon channel and cache item market value as 'PCF Sniff'")

-- 10. Peer-to-Peer Mesh Sync Chunking (<255 bytes), Deserialization, and 30-Min Cooldown Tests
for i = 1, 35 do
    local fakeItemId = 30000 + i
    PCF_DB.prices[fakeItemId] = {
        minBuyout = 100000 + (i * 500),
        minBid = 100000,
        lastUpdated = math.floor(Mock.currentTime),
        count = 1,
        source = "Scan",
    }
end

local deltaChunks = tocAddonTable.MeshSync.BuildDeltaChunks(0)
Assert(#deltaChunks >= 4, "Split large delta set into multiple addon message chunks")
for idx, chunk in ipairs(deltaChunks) do
    Assert(#chunk <= 255 and chunk:find("^DELTA:") ~= nil, string.format("Chunk %d respects <255 byte limit (%d bytes)", idx, #chunk))
end

-- Clear and deserialize chunks back into PCF_DB.prices
PCF_DB.prices = {}
local totalApplied = 0
for _, chunk in ipairs(deltaChunks) do
    totalApplied = totalApplied + tocAddonTable.MeshSync.ApplyDeltaPayload(chunk)
end
Assert(totalApplied >= 35 and PCF_DB.prices[30001] and PCF_DB.prices[30001].minBuyout == 100500, "Deserialize all chunked DELTA payloads accurately")
Assert(PCF_DB.prices[30001].source == "PCF Mesh", "Tag peer-synced items with 'PCF Mesh' source")

local meshPrice, meshSource = tocAddonTable.ProviderRegistry.ResolvePrice("|cffffffff|Hitem:30001:0:0:0|h[Item]|h|r", 30001)
Assert(meshPrice == 100500 and meshSource:find("^PCF Mesh") ~= nil, "NativeProvider reports 'PCF Mesh' source tag for peer-synced items")

-- 30-Minute Digest Request Cooldown Verification
tocAddonTable.MeshSync.ResetCooldowns()
local msgCountBefore = #Mock.addonMessages
local sent1 = tocAddonTable.MeshSync.RequestDigest(false)
Assert(sent1 == true and #Mock.addonMessages == msgCountBefore + 1, "Send initial REQ_DIGEST when not on cooldown")

Mock.currentTime = Mock.currentTime + 600 -- Only 10 minutes later (< 30 minutes)
local sent2 = tocAddonTable.MeshSync.RequestDigest(false)
Assert(sent2 == false and #Mock.addonMessages == msgCountBefore + 1, "Suppress duplicate REQ_DIGEST within 30-minute cooldown window")

Mock.currentTime = Mock.currentTime + 1300 -- Now > 30 minutes (1900s total) elapsed
local sent3 = tocAddonTable.MeshSync.RequestDigest(false)
Assert(sent3 == true and #Mock.addonMessages == msgCountBefore + 2, "Allow REQ_DIGEST after 30-minute cooldown expires")

-- Targeted REQ_ITEM: peers holding the item answer with a DELTA covering only that item
tocAddonTable.MeshSync.ResetCooldowns()
PCF_DB.prices[88001] = { minBuyout = 4242, minBid = 4242, lastUpdated = math.floor(Mock.currentTime), count = 1, source = "Scan" }
PCF_DB.prices[88002] = { minBuyout = 4300, minBid = 4300, lastUpdated = math.floor(Mock.currentTime), count = 1, source = "Scan" }
local reqMsgsBefore = #Mock.addonMessages
tocAddonTable.MeshSync.frame:Trigger("CHAT_MSG_ADDON", "PCF_SYNC", "REQ_ITEM:88001", "GUILD", "OtherGuildie")
Mock.timers[#Mock.timers].callback()
local reqReply = Mock.addonMessages[#Mock.addonMessages]
Assert(#Mock.addonMessages == reqMsgsBefore + 1 and reqReply.msg:find("^DELTA:88001:4242:") ~= nil and reqReply.msg:find("88002", 1, true) == nil, "Answer REQ_ITEM with a DELTA covering only the requested item")

-- Another peer's DELTA for the same item suppresses our pending answer
tocAddonTable.MeshSync.ResetCooldowns()
reqMsgsBefore = #Mock.addonMessages
tocAddonTable.MeshSync.frame:Trigger("CHAT_MSG_ADDON", "PCF_SYNC", "REQ_ITEM:88002", "GUILD", "OtherGuildie")
local suppressedReplyTimer = Mock.timers[#Mock.timers]
tocAddonTable.MeshSync.frame:Trigger("CHAT_MSG_ADDON", "PCF_SYNC", string.format("DELTA:88002:4300:%d", time()), "GUILD", "AnotherPeer")
suppressedReplyTimer.callback()
Assert(#Mock.addonMessages == reqMsgsBefore, "Suppress REQ_ITEM answer when another peer's DELTA already covers the item")

-- Peers without data for the item stay silent
tocAddonTable.MeshSync.ResetCooldowns()
local timersBeforeNoDataReq = #Mock.timers
tocAddonTable.MeshSync.frame:Trigger("CHAT_MSG_ADDON", "PCF_SYNC", "REQ_ITEM:99999999", "GUILD", "OtherGuildie")
Assert(#Mock.timers == timersBeforeNoDataReq, "Do not answer REQ_ITEM for items we have no data on")
PCF_DB.prices[88001], PCF_DB.prices[88002] = nil, nil

-- 11. Local TSM / Auctionator -> Mesh Bridge & Background Refresh Tests
_G.TSM_API = {
    GetCustomPriceValue = function(priceSource, itemStr)
        if itemStr == "i:30001" then
            return 155000
        elseif itemStr == "i:45000" or (type(itemStr) == "string" and itemStr:find("item:45000")) then
            return 225000
        end
        return nil
    end
}
PCF_DB.settings.showTooltip = false
_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Edgemaster's Handguards")
_G.GameTooltip:SetItem("Edgemaster's Handguards", "|cffa335ee|Hitem:45000:0:0:0|h[Edgemaster's Handguards]|h|r")
Assert(#_G.GameTooltip.lines == 1, "Do not add PCF tooltip line when TSM is active and showTooltip is off")
Assert(PCF_DB.prices[45000] and PCF_DB.prices[45000].minBuyout == 225000 and PCF_DB.prices[45000].source == "PCF Sniff", "Silently harvest TSM price into PCF_DB.prices on item hover for guild mesh sharing")

local refreshedCount = tocAddonTable.MeshSync.RefreshExternalAddonPrices()
Assert(refreshedCount >= 1 and PCF_DB.prices[30001].minBuyout == 155000, "RefreshExternalAddonPrices updates cached items with latest TSM market values")
_G.TSM_API = nil

-- 12. Public Developer API (_G.PCF_API) & Double-Load Guard Tests
Assert(_G.PCF_API ~= nil and _G.PCF_API.IsReady() == true, "PCF_API is exposed globally and IsReady() returns true")

local apiPriceLink, apiSourceLink = _G.PCF_API.GetPrice("|cff1eff00|Hitem:45000:0:0:0|h[Edgemaster's Handguards]|h|r")
Assert(apiPriceLink == 225000 and apiSourceLink == "Sniff", "PCF_API.GetPrice resolves item link and normalizes source name")

local apiPriceId, apiSourceId = _G.PCF_API.GetPrice(30001)
Assert(apiPriceId == 155000 and apiSourceId == "Sniff", "PCF_API.GetPrice resolves raw numeric item ID")

PCF_DB.prices[19019] = nil
local apiVendorPrice, apiVendorSource = _G.PCF_API.GetPrice(19019)
Assert(apiVendorPrice == 250000 and apiVendorSource == "Vendor", "PCF_API.GetPrice resolves Vendor fallback with normalized 'Vendor' source")

Assert(_G.PCF_API.FormatMoney(0) == "0c", "PCF_API.FormatMoney formats zero copper")
Assert(_G.PCF_API.FormatMoney(85) == "85c", "PCF_API.FormatMoney formats copper-only")
Assert(_G.PCF_API.FormatMoney(1250) == "12s 50c", "PCF_API.FormatMoney formats silver-copper")
Assert(_G.PCF_API.FormatMoney(3501250) == "350g 12s 50c", "PCF_API.FormatMoney formats gold-silver-copper")

local ts30001 = _G.PCF_API.GetPriceTimestamp(30001)
Assert(type(ts30001) == "number" and ts30001 > 0, "PCF_API.GetPriceTimestamp returns valid epoch timestamp from PCF_DB.prices")
Assert(_G.PCF_API.GetPriceTimestamp(999999) == nil, "PCF_API.GetPriceTimestamp returns nil for unknown item ID")

Mock.currentTime = Mock.currentTime + 10.0
local chatBeforeApi = #Mock.chatMessages
local reqOk = _G.PCF_API.RequestPriceCheck("|cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r", "PARTY")
Assert(reqOk == true and #Mock.chatMessages == chatBeforeApi + 1 and Mock.chatMessages[#Mock.chatMessages].channel == "PARTY", "PCF_API.RequestPriceCheck dispatches lookup reply to specified channel")

-- Verify double-initialization guard when loaded a second time (embedded + standalone)
local secondInitResult = PCF.Initialize()
Assert(secondInitResult == false, "PCF.Initialize() guard prevents double initialization")
local coreChunk = loadfile("Core.lua")
local embeddedTable = {}
coreChunk("ThiccUI", embeddedTable)
Assert(embeddedTable.coreFrame == nil, "Core.lua aborts secondary ADDON_LOADED frame registration when _G.PCF_INITIALIZED is set")

-- 13. Large Copper Prices & WoW 32-bit string.format Integer Overflow Protection
do
    local origFormat = string.format
    local INT32_MIN, INT32_MAX = -2147483648, 2147483647
    string.format = function(fmt, ...)
        local args = { ... }
        local argIdx = 0
        local i = 1
        while i <= #fmt do
            if fmt:sub(i, i) == "%" then
                if fmt:sub(i + 1, i + 1) == "%" then
                    i = i + 2
                else
                    local specStart, specEnd, spec = fmt:find("^%%[-+ #0]*[%d%*]*%.?[%d%*]*([cdiouxXeEfFgGqs])", i)
                    assert(specStart, "Unsupported format specifier: " .. fmt:sub(i))
                    argIdx = argIdx + 1
                    if spec == "d" or spec == "i" or spec == "u" or spec == "x" or spec == "X" or spec == "o" then
                        local val = tonumber(args[argIdx])
                        assert(val ~= nil, "bad argument to %" .. spec)
                        if val ~= val or val < INT32_MIN or val > INT32_MAX then
                            error("integer overflow attempting to store " .. tostring(val))
                        end
                    end
                    i = specEnd + 1
                end
            else
                i = i + 1
            end
        end
        return origFormat(fmt, ...)
    end

    local okOverflowSuite, overflowErr = pcall(function()
        local savedPrices = PCF_DB.prices
        local savedLastSync = PCF_DB.lastPeerSync
        local savedTime = Mock.currentTime

        -- Exact reproducer: itemId 18401 at 9,999,999g 01s 00c (99999990100c > INT32_MAX)
        Mock.currentTime = 1794501500
        PCF_DB.prices = {
            [18401] = { minBuyout = 99999990100, minBid = 99999990100, lastUpdated = 1794501499, count = 1, source = "Scan" },
            [2589] = { minBuyout = 150, minBid = 150, lastUpdated = 1794501400, count = 10, source = "Scan" },
        }
        local largeChunks = tocAddonTable.MeshSync.BuildDeltaChunks(0)
        Assert(#largeChunks == 1 and largeChunks[1]:find("18401:99999990100:1794501499", 1, true) ~= nil, "BuildDeltaChunks serializes >32-bit copper buyout without integer overflow")

        PCF_DB.prices = {}
        local appliedLarge = tocAddonTable.MeshSync.ApplyDeltaPayload("DELTA:18401:99999990100:1794501499|18402:100000000000:1794501499")
        Assert(appliedLarge == 1 and PCF_DB.prices[18401] and PCF_DB.prices[18401].minBuyout == 99999990100 and PCF_DB.prices[18402] == nil, "ApplyDeltaPayload accepts 9,999,999g cap (<1e11c) and rejects >=1e11c")

        -- Edge cases: NaN, inf, sub-copper, negative timestamp, oversized corrupted entry
        PCF_DB.prices = {
            [1] = { minBuyout = 0 / 0, lastUpdated = 100 },
            [2] = { minBuyout = 1 / 0, lastUpdated = 100 },
            [3] = { minBuyout = 0.5, lastUpdated = 100 },
            [4] = { minBuyout = 100, lastUpdated = -5 },
            [5] = { minBuyout = 100, lastUpdated = 1 / 0 },
            [6] = { minBuyout = 1e260, lastUpdated = 100 },
            [18401] = { minBuyout = 99999990100.9, lastUpdated = 1794501499.7 },
        }
        local filteredChunks = tocAddonTable.MeshSync.BuildDeltaChunks(0)
        Assert(#filteredChunks == 1 and filteredChunks[1] == "DELTA:18401:99999990100:1794501499", "BuildDeltaChunks skips NaN, inf, sub-copper, negative timestamps, and >245B entries")

        -- Post-2038 timestamp in RequestDigest
        tocAddonTable.MeshSync.ResetCooldowns()
        PCF_DB.lastPeerSync = 2500000000
        local digestBefore = #Mock.addonMessages
        tocAddonTable.MeshSync.RequestDigest(true)
        Assert(#Mock.addonMessages == digestBefore + 1 and Mock.addonMessages[#Mock.addonMessages].msg == "REQ_DIGEST:2500000000", "RequestDigest formats timestamps > INT32_MAX without overflow")

        -- SniffExternalMessage consistency with 9,999,999g cap
        PCF_DB.prices = {}
        local sniffLarge = tocAddonTable.MeshSync.SniffExternalMessage("TSM_SYNC", "18401:99999990100|18402:100000000000", "Peer")
        Assert(sniffLarge == 1 and PCF_DB.prices[18401].minBuyout == 99999990100 and PCF_DB.prices[18402] == nil, "SniffExternalMessage accepts <1e11c and rejects >=1e11c")

        -- Stack money formatting when gold itself exceeds INT32_MAX (99999990100 * 500 = 4999999505g)
        Assert(PCF.Formatter.FormatMoney(99999990100 * 500) == "4999999505g", "FormatMoney formats stacks where gold exceeds INT32_MAX")
        Assert(PCF.Formatter.FormatTooltipMoney(99999990100 * 500):find("4999999505", 1, true) ~= nil, "FormatTooltipMoney formats stacks where gold exceeds INT32_MAX")
        Assert(PCF.Formatter.FormatMoney(0 / 0) == "0c" and PCF.Formatter.FormatTooltipMoney(1 / 0) == "??", "Formatters safely handle NaN and inf")

        _G.GetCoinTextureString = function(copper)
            return string.format("%dg", math.floor(copper / 10000))
        end
        Assert(PCF.Formatter.FormatTooltipMoney(99999990100 * 500):find("4999999505", 1, true) ~= nil, "FormatTooltipMoney falls back cleanly if GetCoinTextureString overflows")
        _G.GetCoinTextureString = nil

        -- Huge quantity parsing & large item ID in RequestPriceCheck
        local _, parsedLargeId, parsedHugeQty = PCF.ItemParser.Parse("? " .. string.rep("9", 400) .. "x |cffffffff|Hitem:18401:0:0:0|h[Item]|h|r")
        Assert(parsedLargeId == 18401 and parsedHugeQty == 1, "ItemParser clamps infinite stack multiplier to 1")
        Assert(_G.PCF_API.RequestPriceCheck(99999999999, "WHISPER", "AskerLarge") == true, "RequestPriceCheck handles large numeric item ID without %d overflow")

        PCF_DB.prices = savedPrices
        PCF_DB.lastPeerSync = savedLastSync
        Mock.currentTime = savedTime
    end)

    string.format = origFormat
    if not okOverflowSuite then
        error(overflowErr)
    end
end

-- 14. AH Scanning, Provider & Configuration Optimizations (1-6)
do
    local savedQuery = _G.QueryAuctionItems
    local savedCAH = _G.C_AuctionHouse
    local savedCItem = _G.C_Item
    local savedAuc = _G.Auctionator
    local savedAucVars = _G.AUCTIONATOR_SAVEDVARS
    local savedAucDB = _G.AUCTIONATOR_PRICE_DATABASE
    local savedListings = Mock.auctionListings
    local savedTime14 = Mock.currentTime
    Mock.currentTime = 1794501500
    Mock.auctionListings = {}
    _G.QueryAuctionItems = nil

    -- Ensure scan button is enabled for scanner tests
    PCF_DB.settings.showScanButton = true
    PCF_DB.settings.userSetScanButton = true
    tocAddonTable.Scanner.UpdateVisibility()

    -- (2a) Direct delta processing on AUCTION_HOUSE_BROWSE_RESULTS_ADDED during full scan
    local getBrowseResultsCalls = 0
    local requestMoreCalls = 0
    local hasFullBrowse = false
    local page1Browse = {
        { itemKey = { itemID = 50001 }, minPrice = 1100, totalQuantity = 7 },
    }
    local page2Delta = {
        { itemKey = { itemID = 50002 }, minPrice = 2200, totalQuantity = 19 },
    }
    _G.C_AuctionHouse = {
        SendBrowseQuery = function() end,
        GetBrowseResults = function()
            getBrowseResultsCalls = getBrowseResultsCalls + 1
            return page1Browse
        end,
        HasFullBrowseResults = function()
            return hasFullBrowse
        end,
        RequestMoreBrowseResults = function()
            requestMoreCalls = requestMoreCalls + 1
        end,
    }
    local timersBeforeDeltaScan = #Mock.timers
    tocAddonTable.Scanner.StartScan()
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Assert(getBrowseResultsCalls == 1 and PCF_DB.prices[50001] and PCF_DB.prices[50001].minBuyout == 1100 and PCF_DB.prices[50001].count == 7, "Initial AUCTION_HOUSE_BROWSE_RESULTS_UPDATED fetches page 1 via GetBrowseResults")

    local moreTimer = FindTimerByDelay(0.02, timersBeforeDeltaScan + 1)
    Assert(moreTimer ~= nil, "Schedule RequestMoreBrowseResults with fast 0.02s delay")
    moreTimer.callback()
    Assert(requestMoreCalls == 1, "RequestMoreBrowseResults invoked for next browse batch")

    hasFullBrowse = true
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", page2Delta)
    Assert(getBrowseResultsCalls == 1, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED processes addedResults delta directly without calling GetBrowseResults()")
    Assert(PCF_DB.prices[50002] and PCF_DB.prices[50002].minBuyout == 2200 and PCF_DB.prices[50002].count == 19, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED records delta items and totalQuantity")

    -- (2b) Passive sniffing with addedResults delta & uncapped (>500) GetBrowseResults
    local sniffGetBrowseCalls = 0
    local largeBrowseResults = {}
    for i = 1, 650 do
        largeBrowseResults[i] = { itemKey = { itemID = 60000 + i }, minPrice = 500 + i, totalQuantity = 3 }
    end
    _G.C_AuctionHouse = {
        GetBrowseResults = function()
            sniffGetBrowseCalls = sniffGetBrowseCalls + 1
            return largeBrowseResults
        end,
    }
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {
        { itemKey = { itemID = 59999 }, minPrice = 8888, totalQuantity = 4 },
    })
    Assert(sniffGetBrowseCalls == 0 and PCF_DB.prices[59999] and PCF_DB.prices[59999].minBuyout == 8888, "Passive SniffVisiblePage(addedResults) processes delta without calling GetBrowseResults()")

    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    Assert(sniffGetBrowseCalls == 1 and PCF_DB.prices[60650] and PCF_DB.prices[60650].minBuyout == 1150, "Passive SniffVisiblePage() captures browse results past index 500 (index 650)")

    -- (3) In-memory batch aggregation & ghost-item filtering in ProcessModernReplicate
    local markDirtyCalls = {}
    local origMarkDirty = tocAddonTable.MeshSync.MarkDirty
    tocAddonTable.MeshSync.MarkDirty = function(itemId)
        markDirtyCalls[itemId] = (markDirtyCalls[itemId] or 0) + 1
        return origMarkDirty(itemId)
    end
    _G.C_Item = {
        DoesItemExistByID = function(itemId)
            return itemId ~= 99999 -- 99999 is a ghost item
        end,
    }
    local repRows = {
        { itemId = 99999, count = 1, minBid = 100, buyoutPrice = 200 }, -- ghost item (filtered out)
        { itemId = 70001, count = 5, minBid = 450, buyoutPrice = 500 }, -- 100c unit buyout, 90c unit bid
        { itemId = 70001, count = 10, minBid = 800, buyoutPrice = 850 }, -- 85c unit buyout, 80c unit bid
        { itemId = 70001, count = 20, minBid = 1900, buyoutPrice = 2000 }, -- 100c unit buyout, 95c unit bid
    }
    _G.C_AuctionHouse = {
        ReplicateItems = function() end,
        GetNumReplicateItems = function() return #repRows end,
        GetReplicateItemInfo = function(index)
            local r = repRows[index + 1]
            return nil, nil, r.count, 1, nil, 1, nil, r.minBid, 0, r.buyoutPrice, 0, nil, 0, nil, nil, 0, r.itemId
        end,
    }
    PCF_DB.lastReplicateScan = 0
    tocAddonTable.Scanner.StartScan(true) -- force replicate mode
    tocAddonTable.Scanner.frame:Trigger("REPLICATE_ITEM_LIST_UPDATE")
    Assert(PCF_DB.prices[99999] == nil and markDirtyCalls[99999] == nil, "Filter out ghost items where C_Item.DoesItemExistByID returns false")
    Assert(PCF_DB.prices[70001] and PCF_DB.prices[70001].minBuyout == 85 and PCF_DB.prices[70001].minBid == 80 and PCF_DB.prices[70001].count == 35, "Aggregate minBuyout, minBid, and total count across replicate stacks in memory")
    Assert(markDirtyCalls[70001] == 1, "Call MeshSync.MarkDirty only once per unique itemId at end of replicate scan")
    tocAddonTable.MeshSync.MarkDirty = origMarkDirty
    _G.C_Item = savedCItem

    -- (4) AuctionatorProvider accurate scan timestamp, age label, quantity harvesting & fresh-only MarkDirty
    local nowTs = time()
    local dirtyTracker = {}
    tocAddonTable.MeshSync.MarkDirty = function(itemId)
        dirtyTracker[itemId] = (dirtyTracker[itemId] or 0) + 1
        return origMarkDirty(itemId)
    end
    _G.AUCTIONATOR_PRICE_DATABASE = {
        ["Forever_Alliance"] = {
            ["71001"] = { m = 12345, a = { [100] = 4, [105] = 27 } },
            ["71002"] = { m = 54321, a = { [102] = 9 } },
        },
    }
    _G.Auctionator = {
        SavedState = {
            TimeOfLastBrowseScan = nowTs - (25 * 60), -- 25m ago
            TimeOfLastReplicateScan = nowTs - (120 * 60),
        },
        API = {
            v1 = {
                GetAuctionPriceByItemLink = function(_, link)
                    if link and link:find("item:71001") then return 12345 end
                    if link and link:find("item:71002") then return 54321 end
                end,
                GetAuctionAgeByItemLink = function(_, link)
                    if link and link:find("item:71001") then return 0 end -- seen in latest scan (25m ago)
                    if link and link:find("item:71002") then return 3 end -- 3 days old (> 6h)
                end,
            },
        },
    }
    local pFresh, srcFresh = tocAddonTable.ProviderRegistry.ResolvePrice("|cffffffff|Hitem:71001:0:0:0|h[FreshItem]|h|r", 71001)
    Assert(pFresh == 12345 and srcFresh == "Auctionator (25m ago)", "Format Auctionator source label with relative age from TimeOfLastBrowseScan (25m ago)")
    Assert(PCF_DB.prices[71001] and PCF_DB.prices[71001].count == 27 and PCF_DB.prices[71001].lastUpdated == nowTs - (25 * 60), "Harvest available quantity (count = 27) and exact scan timestamp from Auctionator")
    Assert(dirtyTracker[71001] == 1, "MarkDirty called when external provider timestamp is known and fresh (< 6h)")

    local pStale, srcStale = tocAddonTable.ProviderRegistry.ResolvePrice("|cffffffff|Hitem:71002:0:0:0|h[StaleItem]|h|r", 71002)
    Assert(pStale == 54321 and srcStale == "Auctionator (72h ago)", "Adjust Auctionator timestamp by GetAuctionAgeByItemLink when ageDays > 0 (72h ago)")
    Assert(PCF_DB.prices[71002] and PCF_DB.prices[71002].count == 9 and PCF_DB.prices[71002].lastUpdated == nowTs - (3 * 86400), "Store real 3-day-old timestamp instead of stamping now()")
    Assert(dirtyTracker[71002] == nil, "Do not call MarkDirty for stale (> 6h old) external provider entries")
    tocAddonTable.MeshSync.MarkDirty = origMarkDirty

    -- (5) Preserve user /pcf button and /pcf tooltip overrides across reloads (PCF.LoadConfig)
    PCF_DB.settings.showScanButton = false
    PCF_DB.settings.showTooltip = false
    PCF_DB.settings.userSetScanButton = false
    PCF_DB.settings.userSetTooltip = false
    SlashCmdList["PRICECHECKERFOREVER"]("button")
    SlashCmdList["PRICECHECKERFOREVER"]("tooltip")
    Assert(PCF_DB.settings.showScanButton == true and PCF_DB.settings.userSetScanButton == true, "/pcf button sets userSetScanButton = true")
    Assert(PCF_DB.settings.showTooltip == true and PCF_DB.settings.userSetTooltip == true, "/pcf tooltip sets userSetTooltip = true")
    PCF.LoadConfig(PCF_DB) -- Simulate /reload while _G.Auctionator is present
    Assert(PCF_DB.settings.showScanButton == true and PCF_DB.settings.showTooltip == true, "PCF.LoadConfig preserves user-enabled showScanButton and showTooltip across reloads when external addon is installed")

    -- (6) Optional cooldown-gated auto-scan on AUCTION_HOUSE_SHOW (/pcf autoscan)
    Assert(PCF_DB.settings.autoScanOnOpen == true and PCF_DB.settings.autoScanCooldownSeconds == 900, "Default config enables autoScanOnOpen with 900s (15m) cooldown")
    SlashCmdList["PRICECHECKERFOREVER"]("autoscan")
    Assert(PCF_DB.settings.autoScanOnOpen == false, "/pcf autoscan toggles autoScanOnOpen OFF")
    SlashCmdList["PRICECHECKERFOREVER"]("autoscan")
    Assert(PCF_DB.settings.autoScanOnOpen == true, "/pcf autoscan toggles autoScanOnOpen back ON")

    local autoScanStarted = 0
    _G.C_AuctionHouse = {
        SendBrowseQuery = function()
            autoScanStarted = autoScanStarted + 1
        end,
        GetBrowseResults = function() return {} end,
        HasFullBrowseResults = function() return true end,
    }
    _G.AuctionFrame:Show()

    -- A. Within 15-minute cooldown: does not auto-scan
    PCF_DB.lastFullScan = time() - 300 -- 5 minutes ago (< 900s)
    local timersBeforeAutoCooldown = #Mock.timers
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
    Assert(FindTimerByDelay(0.5, timersBeforeAutoCooldown + 1) == nil, "Suppress auto-scan on AUCTION_HOUSE_SHOW when lastFullScan is within 15m cooldown")

    -- B. Cooldown elapsed (>= 900s), but AH closes before 0.5s timer fires: does not start scan
    PCF_DB.lastFullScan = time() - 1200 -- 20 minutes ago (>= 900s)
    local timersBeforeAutoClose = #Mock.timers
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
    local autoTimerClosed = FindTimerByDelay(0.5, timersBeforeAutoClose + 1)
    Assert(autoTimerClosed ~= nil, "Schedule 0.5s auto-scan timer on AUCTION_HOUSE_SHOW when cooldown has elapsed")
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_CLOSED")
    autoTimerClosed.callback()
    Assert(autoScanStarted == 0, "Abort scheduled auto-scan if AUCTION_HOUSE_CLOSED fires before 0.5s delay")

    -- C. Cooldown elapsed and AH remains open: starts scan after 0.5s delay
    local timersBeforeAutoOpen = #Mock.timers
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
    local autoTimerOpen = FindTimerByDelay(0.5, timersBeforeAutoOpen + 1)
    Assert(autoTimerOpen ~= nil, "Schedule 0.5s auto-scan timer when AH opens")
    autoTimerOpen.callback()
    Assert(autoScanStarted == 1, "Auto-scan triggers PCF.Scanner.StartScan() after 0.5s when AH remains open")
    tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")

    _G.QueryAuctionItems = savedQuery
    _G.C_AuctionHouse = savedCAH
    _G.Auctionator = savedAuc
    _G.AUCTIONATOR_SAVEDVARS = savedAucVars
    _G.AUCTIONATOR_PRICE_DATABASE = savedAucDB
    Mock.auctionListings = savedListings
    Mock.currentTime = savedTime14
end

print("\n--- All Unit Tests Passed Successfully ---")
