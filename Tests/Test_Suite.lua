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
    Mock.chatMessages[#Mock.chatMessages].msg == "Price check for |cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r: 9s 50c (95c ea) [Native AH Scan (0m ago)]",
    "Format stack and unit price in chat response for ?[item]x10"
)
-- Advance time by 14 minutes (840s) and verify chat reply says (14m ago) matching AH banner
Mock.currentTime = 1080.0 + (14 * 60)
PCF.ChatListener.frame:Trigger("CHAT_MSG_WHISPER", "?|cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r*5", "GuildMate")
Assert(
    Mock.chatMessages[#Mock.chatMessages].msg == "Price check for |cffffffff|Hitem:2450:0:0:0|h[Briarthorn]|h|r: 4s 75c (95c ea) [Native AH Scan (14m ago)]",
    "Format stack and unit price with exact minute age (14m ago) for ?[item]*5"
)
PCF_DB.prices[2450] = nil
PCF_DB.lastFullScan = 0

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

-- Modern C_AuctionHouse scan test within 15-minute ReplicateItems cooldown (uses SendBrowseQuery fallback)
local savedQueryAuctionItems = _G.QueryAuctionItems
_G.QueryAuctionItems = nil
local browseQueryCalled = false
local browseResultsData = {
    { itemKey = { itemID = 13468 }, minPrice = 42000, totalQuantity = 12 },
}
_G.C_AuctionHouse = {
    ReplicateItems = function() end,
    SendBrowseQuery = function()
        browseQueryCalled = true
    end,
    GetBrowseResults = function()
        return browseResultsData
    end,
    HasFullBrowseResults = function()
        return true
    end,
}
Mock.currentTime = Mock.currentTime + 540 -- 9 minutes after previous scan
PCF_DB.lastReplicateScan = time() - 540 -- a real ReplicateItems scan ran 9 minutes ago (< 15m server cooldown)
tocAddonTable.Scanner.scanButton:Click()
Assert(browseQueryCalled == true, "Use C_AuctionHouse.SendBrowseQuery when ReplicateItems is within 15-minute cooldown")
tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
Assert(tocAddonTable.Scanner.scanButton:GetText() == "PCF Scan", "Browse-all scan completes cleanly without hanging")
Assert(PCF_DB.prices[13468] and PCF_DB.prices[13468].minBuyout == 42000, "Browse-all scan records item minPrice accurately")

-- Replicate-first API scan: waits for REPLICATE_ITEM_LIST_UPDATE and only falls back to browse after the timeout
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

print("\n--- All Unit Tests Passed Successfully ---")
