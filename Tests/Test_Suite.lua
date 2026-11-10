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
