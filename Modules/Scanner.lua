local _, PCF = ...
PCF = type(PCF) == "table" and PCF or _G.PCF or {}
_G.PCF = PCF

PCF.Scanner = {}

local isScanning = false
local waitingForPage = false
local timerPending = false
local usingModernReplicate = false

local scanFrame = CreateFrame("Frame")
local scanPage = 0
local totalPages = 0
local totalAuctionsCount = 0
local scannedAuctionsCount = 0
local uniqueItemsScanned = 0
local scanStartTime = 0
local seenInScan = {}
local seenInSniff = {}
local sniffBatchId = 0

-- UI Elements attached to AuctionFrame / AuctionHouseFrame
local uiCreated = false
local scanButton = nil
local statusContainer = nil
local progressBar = nil
local progressText = nil

local function FormatDuration(seconds)
    seconds = math.max(0, math.ceil(seconds or 0))
    if seconds >= 60 then
        return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
    end
    return string.format("%ds", seconds)
end

local function CountDatabaseItems()
    if not PCF_DB or not PCF_DB.prices then return 0 end
    local n = 0
    for _ in pairs(PCF_DB.prices) do
        n = n + 1
    end
    return n
end

local function IsScanButtonEnabled()
    if PCF_DB and PCF_DB.settings and PCF_DB.settings.showScanButton == false then
        return false
    end
    return true
end

local function IsPassiveSniffingEnabled()
    if PCF_DB and PCF_DB.settings and PCF_DB.settings.enablePassiveSniffing == false then
        return false
    end
    return true
end

local function SafeUnregisterScanEvents()
    if usingModernReplicate then
        pcall(scanFrame.UnregisterEvent, scanFrame, "REPLICATE_ITEM_LIST_UPDATE")
        usingModernReplicate = false
    end
end

local function UpdateScanUI(state, messageOverride)
    if not uiCreated or not scanButton or not progressBar or not progressText then
        return
    end

    if not IsScanButtonEnabled() then
        scanButton:Hide()
        statusContainer:Hide()
        return
    end

    scanButton:Show()

    if state == "SCANNING" then
        scanButton:SetText("Stop Scan")
        statusContainer:Show()

        if totalPages > 0 and scanPage > 0 then
            local displayPage = math.min(scanPage, totalPages)
            local pct = math.min(100, math.floor((displayPage / totalPages) * 100))
            progressBar:SetMinMaxValues(0, totalPages)
            progressBar:SetValue(displayPage)
            progressBar:SetStatusBarColor(0.15, 0.60, 0.95, 0.90)

            local elapsed = math.max(0.01, GetTime() - scanStartTime)
            local avgPerPage = elapsed / displayPage
            local remainingPages = math.max(0, totalPages - displayPage)
            local etaSeconds = remainingPages * avgPerPage

            progressText:SetText(string.format(
                "%d%%  (%d/%d pg)  ETA: %s",
                pct,
                displayPage,
                totalPages,
                FormatDuration(etaSeconds)
            ))
        else
            progressBar:SetMinMaxValues(0, 1)
            progressBar:SetValue(0)
            progressBar:SetStatusBarColor(0.15, 0.60, 0.95, 0.90)
            local elapsed = math.max(0, GetTime() - scanStartTime)
            progressText:SetText(messageOverride or string.format("Scanning AH... (%s)", FormatDuration(elapsed)))
        end
    elseif state == "COMPLETE" then
        scanButton:SetText("PCF Scan")
        statusContainer:Show()
        progressBar:SetMinMaxValues(0, 1)
        progressBar:SetValue(1)
        progressBar:SetStatusBarColor(0.10, 0.75, 0.25, 0.90)
        local elapsed = math.max(1, math.floor(GetTime() - scanStartTime))
        progressText:SetText(messageOverride or string.format("100%% Done: %d items (%ds)", uniqueItemsScanned, elapsed))
    elseif state == "ABORTED" then
        scanButton:SetText("PCF Scan")
        statusContainer:Show()
        progressBar:SetMinMaxValues(0, 1)
        progressBar:SetValue(1)
        progressBar:SetStatusBarColor(0.75, 0.20, 0.20, 0.90)
        progressText:SetText(messageOverride or "Scan Aborted")
    else
        -- IDLE state
        scanButton:SetText("PCF Scan")
        if PCF_DB and PCF_DB.lastFullScan and PCF_DB.lastFullScan > 0 then
            statusContainer:Show()
            progressBar:SetMinMaxValues(0, 1)
            progressBar:SetValue(1)
            progressBar:SetStatusBarColor(0.25, 0.25, 0.25, 0.80)
            local ageMin = math.max(0, math.floor((time() - PCF_DB.lastFullScan) / 60))
            local ageStr = ageMin >= 60 and string.format("%dh %dm ago", math.floor(ageMin / 60), ageMin % 60) or string.format("%dm ago", ageMin)
            progressText:SetText(string.format("PCF Ready (%d items, %s)", CountDatabaseItems(), ageStr))
        else
            statusContainer:Show()
            progressBar:SetMinMaxValues(0, 1)
            progressBar:SetValue(0)
            progressBar:SetStatusBarColor(0.25, 0.25, 0.25, 0.80)
            progressText:SetText("PCF: No AH scan yet")
        end
    end
end

local function CreateAuctionHouseUI()
    if not IsScanButtonEnabled() then
        if uiCreated then
            if scanButton then scanButton:Hide() end
            if statusContainer then statusContainer:Hide() end
        end
        return
    end

    local parent = _G.AuctionFrame or _G.AuctionHouseFrame
    if not parent then return end

    if uiCreated and scanButton and scanButton.GetParent and scanButton:GetParent() == parent then
        scanButton:Show()
        statusContainer:Show()
        UpdateScanUI(isScanning and "SCANNING" or "IDLE")
        return
    end

    local isLegacyFrame = (_G.AuctionFrame ~= nil and parent == _G.AuctionFrame)
    local offsetX = isLegacyFrame and -34 or -30
    local offsetY = isLegacyFrame and -13 or -3

    -- 1. Scan / Stop Button on the Auction House header
    scanButton = CreateFrame("Button", "PCF_AuctionScanButton", parent, "UIPanelButtonTemplate")
    if scanButton.SetSize then
        scanButton:SetSize(88, 20)
    else
        if scanButton.SetWidth then scanButton:SetWidth(88) end
        if scanButton.SetHeight then scanButton:SetHeight(20) end
    end
    if scanButton.SetPoint then
        scanButton:SetPoint("TOPRIGHT", parent, "TOPRIGHT", offsetX, offsetY)
    end
    if scanButton.SetFrameStrata then
        scanButton:SetFrameStrata("HIGH")
    end
    if scanButton.SetText then
        scanButton:SetText("PCF Scan")
    end

    scanButton:SetScript("OnClick", function()
        if isScanning then
            PCF.Scanner.StopScan("Scan stopped by user.")
        else
            PCF.Scanner.StartScan()
        end
    end)

    scanButton:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("PriceCheckerForever AH Scanner", 0, 1, 0)
        if isScanning then
            local displayPage = totalPages > 0 and math.min(scanPage, totalPages) or scanPage
            local pct = totalPages > 0 and math.min(100, math.floor((displayPage / totalPages) * 100)) or 0
            GameTooltip:AddLine(string.format("Progress: %d%% (Page %d of %d)", pct, displayPage, totalPages), 1, 1, 1)
            GameTooltip:AddLine(string.format("Auctions Scanned: %d / %d", scannedAuctionsCount, totalAuctionsCount), 0.8, 0.8, 0.8)
            GameTooltip:AddLine(string.format("Unique Items Updated: %d", uniqueItemsScanned), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Click to stop the current scan.", 1, 0.4, 0.4)
        else
            local itemCount = CountDatabaseItems()
            GameTooltip:AddLine(string.format("Cached Items: %d", itemCount), 1, 1, 1)
            if PCF_DB and PCF_DB.lastFullScan and PCF_DB.lastFullScan > 0 then
                local ageMin = math.max(0, math.floor((time() - PCF_DB.lastFullScan) / 60))
                GameTooltip:AddLine(string.format("Last Full Scan: %d min ago", ageMin), 0.8, 0.8, 0.8)
            else
                GameTooltip:AddLine("Last Full Scan: Never", 0.8, 0.8, 0.8)
            end
            GameTooltip:AddLine("Click to start a full Auction House scan.", 0.2, 0.9, 0.2)
        end
        GameTooltip:Show()
    end)

    scanButton:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    -- 2. Status / Progress Bar Container next to the Scan Button
    statusContainer = CreateFrame("Frame", "PCF_AuctionScanStatusContainer", parent)
    if statusContainer.SetSize then
        statusContainer:SetSize(220, 18)
    else
        if statusContainer.SetWidth then statusContainer:SetWidth(220) end
        if statusContainer.SetHeight then statusContainer:SetHeight(18) end
    end
    if statusContainer.SetPoint then
        statusContainer:SetPoint("RIGHT", scanButton, "LEFT", -6, 0)
    end
    if statusContainer.SetFrameStrata then
        statusContainer:SetFrameStrata("HIGH")
    end

    -- Dark background texture for the progress bar
    if statusContainer.CreateTexture then
        local bg = statusContainer:CreateTexture(nil, "BACKGROUND")
        if bg.SetAllPoints then bg:SetAllPoints(statusContainer) end
        if bg.SetColorTexture then
            bg:SetColorTexture(0.05, 0.05, 0.05, 0.85)
        elseif bg.SetTexture then
            bg:SetTexture(0.05, 0.05, 0.05, 0.85)
        end
    end

    progressBar = CreateFrame("StatusBar", "PCF_AuctionScanProgressBar", statusContainer)
    if progressBar.SetPoint then
        progressBar:SetPoint("TOPLEFT", statusContainer, "TOPLEFT", 1, -1)
        progressBar:SetPoint("BOTTOMRIGHT", statusContainer, "BOTTOMRIGHT", -1, 1)
    end
    if progressBar.SetStatusBarTexture then
        progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    end
    if progressBar.SetMinMaxValues then
        progressBar:SetMinMaxValues(0, 1)
        progressBar:SetValue(0)
    end
    if progressBar.SetStatusBarColor then
        progressBar:SetStatusBarColor(0.15, 0.60, 0.95, 0.90)
    end

    if progressBar.CreateFontString then
        progressText = progressBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if progressText.SetPoint then
            progressText:SetPoint("CENTER", progressBar, "CENTER", 0, 0)
        end
        if progressText.SetText then
            progressText:SetText("PCF Ready")
        end
    end

    uiCreated = true
    PCF.Scanner.scanButton = scanButton
    PCF.Scanner.progressBar = progressBar
    PCF.Scanner.progressText = progressText

    UpdateScanUI(isScanning and "SCANNING" or "IDLE")
end

local function RecordItemAuction(itemId, count, minBid, buyoutPrice, now, sourceTag, batchMap, currentBatchId)
    if not itemId or not buyoutPrice or buyoutPrice <= 0 or not count or count <= 0 then
        return
    end

    local unitBuyout = math.floor(buyoutPrice / count)
    if unitBuyout <= 0 then return end
    local unitBid = (minBid and minBid > 0) and math.floor(minBid / count) or unitBuyout

    PCF_DB = PCF_DB or {}
    PCF_DB.prices = PCF_DB.prices or {}

    local existing = PCF_DB.prices[itemId]
    local isFirstInBatch = (batchMap[itemId] ~= currentBatchId)

    if isFirstInBatch or not existing then
        batchMap[itemId] = currentBatchId
        if sourceTag == "Scan" then
            uniqueItemsScanned = uniqueItemsScanned + 1
        end
        if existing then
            existing.minBuyout = unitBuyout
            existing.minBid = unitBid
            existing.lastUpdated = now
            existing.count = count
            existing.source = sourceTag
        else
            PCF_DB.prices[itemId] = {
                minBuyout = unitBuyout,
                minBid = unitBid,
                lastUpdated = now,
                count = count,
                source = sourceTag,
            }
        end
    else
        existing.count = (existing.count or 0) + count
        existing.lastUpdated = now
        existing.source = sourceTag
        if unitBuyout < existing.minBuyout then
            existing.minBuyout = unitBuyout
        end
        if not existing.minBid or unitBid < existing.minBid then
            existing.minBid = unitBid
        end
    end

    if PCF.MeshSync and PCF.MeshSync.MarkDirty then
        PCF.MeshSync.MarkDirty(itemId)
    end
end

-- Passively sniffs up to 50 visible items on the current AH page in a single pass
-- without triggering server queries or pagination calls.
function PCF.Scanner.SniffVisiblePage()
    if isScanning or not IsPassiveSniffingEnabled() then
        return 0
    end
    if not GetNumAuctionItems or not GetAuctionItemInfo then
        return 0
    end

    local numBatchAuctions = GetNumAuctionItems("list") or 0
    if numBatchAuctions <= 0 then
        return 0
    end

    local limit = math.min(numBatchAuctions, 50)
    local now = time()
    sniffBatchId = sniffBatchId + 1
    local currentBatchId = sniffBatchId
    local sniffedItems = 0

    for i = 1, limit do
        local _, _, count, _, _, _, _, minBid, _, buyoutPrice, _, _, _, _, _, _, itemId = GetAuctionItemInfo("list", i)
        if itemId and buyoutPrice and buyoutPrice > 0 and count and count > 0 then
            local wasSeen = (seenInSniff[itemId] == currentBatchId)
            RecordItemAuction(itemId, count, minBid, buyoutPrice, now, "PCF Sniff", seenInSniff, currentBatchId)
            if not wasSeen and seenInSniff[itemId] == currentBatchId then
                sniffedItems = sniffedItems + 1
            end
        end
    end

    return sniffedItems
end

local function FinishScan()
    isScanning = false
    waitingForPage = false
    timerPending = false
    SafeUnregisterScanEvents()
    PCF_DB = PCF_DB or {}
    PCF_DB.lastFullScan = time()
    UpdateScanUI("COMPLETE")
    print(string.format("|cff00ff00[PCF]|r Full AH scan complete! (%d unique items updated)", uniqueItemsScanned))
end

local function ScheduleNextLegacyPage(delay)
    if timerPending or not isScanning then return end
    timerPending = true
    C_Timer.After(delay or 0.15, function()
        timerPending = false
        if not isScanning then return end
        if totalPages > 0 and scanPage >= totalPages then
            FinishScan()
            return
        end
        if CanSendAuctionQuery and CanSendAuctionQuery() then
            waitingForPage = true
            QueryAuctionItems("", nil, nil, 0, 0, 0, scanPage, false, -1, false)
        else
            ScheduleNextLegacyPage(0.15)
        end
    end)
end

local function ProcessPage()
    if not isScanning or not waitingForPage then
        return
    end
    -- Immediately clear waitingForPage so secondary AUCTION_ITEM_LIST_UPDATE
    -- events for the same page (as item names/sellers resolve) are ignored
    waitingForPage = false

    local numBatchAuctions, totalAuctions = GetNumAuctionItems("list")
    numBatchAuctions = numBatchAuctions or 0
    totalAuctions = totalAuctions or 0
    totalAuctionsCount = totalAuctions
    totalPages = math.max(1, math.ceil(totalAuctions / 50))

    local now = time()
    for i = 1, numBatchAuctions do
        local name, _, count, _, _, _, _, minBid, _, buyoutPrice, _, _, _, _, _, _, itemId = GetAuctionItemInfo("list", i)
        RecordItemAuction(itemId, count, minBid, buyoutPrice, now, "Scan", seenInScan, true)
    end

    scanPage = scanPage + 1
    scannedAuctionsCount = math.min(totalAuctions, (scanPage - 1) * 50 + numBatchAuctions)
    UpdateScanUI("SCANNING")

    if numBatchAuctions >= 50 and scanPage < totalPages and isScanning then
        ScheduleNextLegacyPage(0.15)
    else
        FinishScan()
    end
end

local function ProcessModernReplicate()
    if not isScanning or not waitingForPage then
        return
    end
    waitingForPage = false

    if not C_AuctionHouse or not C_AuctionHouse.GetNumReplicateItems then
        FinishScan()
        return
    end

    local numItems = C_AuctionHouse.GetNumReplicateItems() or 0
    totalAuctionsCount = numItems
    local batchSize = 500
    totalPages = math.max(1, math.ceil(numItems / batchSize))
    scanPage = 0

    local now = time()
    local index = 0

    local function ProcessBatch()
        if not isScanning then return end
        local limit = math.min(index + batchSize - 1, numItems - 1)
        for i = index, limit do
            local _, _, count, _, _, _, _, minBid, _, buyoutPrice, _, _, _, _, _, _, itemId = C_AuctionHouse.GetReplicateItemInfo(i)
            RecordItemAuction(itemId, count, minBid, buyoutPrice, now, "Scan", seenInScan, true)
        end
        index = limit + 1
        scanPage = scanPage + 1
        scannedAuctionsCount = math.min(numItems, index)
        UpdateScanUI("SCANNING")

        if index < numItems then
            C_Timer.After(0.02, ProcessBatch)
        else
            FinishScan()
        end
    end

    ProcessBatch()
end

function PCF.Scanner.UpdateVisibility()
    if IsScanButtonEnabled() then
        CreateAuctionHouseUI()
    else
        if isScanning then
            PCF.Scanner.StopScan("Scan stopped (AH scan button disabled).")
        end
        if scanButton then scanButton:Hide() end
        if statusContainer then statusContainer:Hide() end
    end
end

function PCF.Scanner.StopScan(reason)
    if not isScanning then return end
    isScanning = false
    waitingForPage = false
    timerPending = false
    SafeUnregisterScanEvents()
    UpdateScanUI("ABORTED", reason or "Scan Aborted")
    print("|cffff0000[PCF]|r " .. (reason or "Scan aborted."))
end

function PCF.Scanner.StartScan()
    if not IsScanButtonEnabled() then
        print("|cffff0000[PCF]|r AH scanning is disabled. Use /pcf button to enable.")
        return
    end

    CreateAuctionHouseUI()

    if isScanning then
        print("|cffff0000[PCF]|r Scan already in progress.")
        return
    end

    -- Modern C_AuctionHouse replication path if legacy QueryAuctionItems is unavailable
    if not QueryAuctionItems and C_AuctionHouse and C_AuctionHouse.ReplicateItems then
        isScanning = true
        waitingForPage = true
        timerPending = false
        usingModernReplicate = true
        scanPage = 0
        totalPages = 0
        totalAuctionsCount = 0
        scannedAuctionsCount = 0
        uniqueItemsScanned = 0
        scanStartTime = GetTime()
        seenInScan = {}
        UpdateScanUI("SCANNING", "Requesting AH data...")

        pcall(scanFrame.RegisterEvent, scanFrame, "REPLICATE_ITEM_LIST_UPDATE")
        C_AuctionHouse.ReplicateItems()
        print("|cff00ff00[PCF]|r Starting full AH scan...")
        return
    end

    if not CanSendAuctionQuery or not CanSendAuctionQuery() then
        UpdateScanUI("ABORTED", "AH busy — wait a moment")
        print("|cffff0000[PCF]|r Auction House is busy. Please wait.")
        return
    end

    isScanning = true
    waitingForPage = true
    timerPending = false
    usingModernReplicate = false
    scanPage = 0
    totalPages = 0
    totalAuctionsCount = 0
    scannedAuctionsCount = 0
    uniqueItemsScanned = 0
    scanStartTime = GetTime()
    seenInScan = {}
    UpdateScanUI("SCANNING", "Starting scan (Page 1)...")

    scanFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    QueryAuctionItems("", nil, nil, 0, 0, 0, 0, false, -1, false)
    print("|cff00ff00[PCF]|r Starting full AH scan...")
end

-- Unified event handler for AH window lifecycle, full scan paging, and passive browse-sniffing
function PCF.Scanner.Init()
    if PCF.Scanner._initialized then return end
    PCF.Scanner._initialized = true

    scanFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    scanFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    scanFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    scanFrame:SetScript("OnEvent", function(_, event)
        if event == "AUCTION_HOUSE_SHOW" then
            CreateAuctionHouseUI()
        elseif event == "AUCTION_HOUSE_CLOSED" then
            if isScanning then
                PCF.Scanner.StopScan("AH closed. Scan aborted.")
            end
        elseif event == "AUCTION_ITEM_LIST_UPDATE" then
            if isScanning then
                ProcessPage()
            else
                PCF.Scanner.SniffVisiblePage()
            end
        elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
            if isScanning then
                ProcessModernReplicate()
            end
        end
    end)
end

PCF.Scanner.frame = scanFrame
