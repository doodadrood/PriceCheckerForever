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
local link1, id1 = PCF.ItemParser.Parse("?[|cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r]")
Assert(id1 == 19019, "Parse standard ?[item] link")

local link2, id2 = PCF.ItemParser.Parse("   pc   |cffff8000|Hitem:19019:0:0:0|h[Thunderfury]|h|r")
Assert(id2 == 19019, "Parse pc[item] with irregular spacing")

local link3, id3 = PCF.ItemParser.Parse("what is the price of this item?")
Assert(id3 == nil, "Reject input without trigger or item link")

-- 2. Currency Formatter Tests
Assert(PCF.Formatter.FormatMoney(0) == "0c", "Format 0 copper")
Assert(PCF.Formatter.FormatMoney(85) == "85c", "Format copper only")
Assert(PCF.Formatter.FormatMoney(1250) == "12s 50c", "Format silver and copper")
Assert(PCF.Formatter.FormatMoney(3501250) == "350g 12s 50c", "Format gold, silver, copper")
Assert(PCF.Formatter.FormatTooltipMoney(nil) == "??", "Format unknown tooltip money as ??")
Assert(PCF.Formatter.FormatTooltipMoney(0) == "??", "Format 0 tooltip money as ??")
Assert(PCF.Formatter.FormatTooltipMoney(303) == "3s3c", "Format compact tooltip money 3s3c")
Assert(PCF.Formatter.FormatTooltipMoney(3501250) == "350g12s50c", "Format compact tooltip money XgXsXc")

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
Assert(type(SlashCmdList["GUILDPRICECHECK"]) == "function", "Register /gpc slash command on ADDON_LOADED")

-- Simulate opening Auction House window
tocAddonTable.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
Assert(tocAddonTable.Scanner.scanButton ~= nil, "Create 'PCF Scan' button on AuctionFrame when AH opens")
Assert(tocAddonTable.Scanner.scanButton:GetText() == "PCF Scan", "Initial AH scan button label is 'PCF Scan'")

-- Start scan via clicking the AH Scan button
tocAddonTable.Scanner.scanButton:Click()
Assert(tocAddonTable.Scanner.scanButton:GetText() == "Stop Scan", "Button switches to 'Stop Scan' while scanning")

-- Simulate Page 1 of 2 arriving after 1 second
Mock.currentTime = Mock.currentTime + 1.0
tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
Assert(tocAddonTable.Scanner.progressBar:GetValue() == 1, "Progress bar updates to page 1 of 2")
Assert(tocAddonTable.Scanner.progressText:GetText():find("50%%") ~= nil, "Progress text displays 50% and ETA")

-- Simulate Page 2 of 2 arriving
_G.GetNumAuctionItems = function() return 50, 100 end
Mock.currentTime = Mock.currentTime + 1.0
tocAddonTable.Scanner.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
Assert(tocAddonTable.Scanner.scanButton:GetText() == "PCF Scan", "Button resets to 'PCF Scan' on scan completion")
Assert(tocAddonTable.Scanner.progressText:GetText():find("100%% Done") ~= nil, "Progress text shows 100% Done on completion")
Assert(PCF_DB.prices[12360] and PCF_DB.prices[12360].minBuyout == 145000, "Scanner computes unit buyout (290000 / 2 = 145000c)")

-- 7. Tooltip AH Price Display Tests
_G.TSM_API = nil
_G.Auctionator = nil
_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Linen Cloth")
_G.GameTooltip:AddLine("Sell Price: 3s3c")
_G.GameTooltip:SetItem("Linen Cloth", "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r")
Assert(_G.GameTooltip.lines[#_G.GameTooltip.lines] == "AH Price: ??", "Tooltip displays 'AH Price: ??' below Sell Price when AH price is unknown")

_G.GameTooltip:ClearLines()
_G.GameTooltip:AddLine("Arcanite Bar")
_G.GameTooltip:AddLine("Sell Price: 10s")
_G.GameTooltip:SetItem("Arcanite Bar", "|cff1eff00|Hitem:12360:0:0:0|h[Arcanite Bar]|h|r")
Assert(_G.GameTooltip.lines[#_G.GameTooltip.lines] == "AH Price: 14g50s", "Tooltip displays 'AH Price: 14g50s' below Sell Price when AH price is known")

print("\n--- All Unit Tests Passed Successfully ---")
