# PriceCheckerForever (PCF)

**PriceCheckerForever** is a lightweight World of Warcraft addon that responds to guild and whisper price-check queries (`?[Item Link]` or `pc [Item Link]`), displays last-known Auction House prices on item tooltips, and synchronizes market data across guild members via a decentralized peer-to-peer mesh protocol.

---

## Features
- **Automated Chat Price Checks**: Replies to `?[Item Link]` and `pc [Item Link]` (including optional stack multipliers such as `?[Item Link]x10` or `?[Item Link]*10`) in Guild Chat and Whispers with decentralized peer deduplication (`PCF_SYNC`) so only one guild member responds.
- **Multi-Tier Pricing Pipeline**: Evaluates `TradeSkillMaster` -> `Auctionator` -> `Native AH Cache / Mesh / Sniff` -> `Vendor Fallback`.
- **Non-Blocking AH Scanner & Passive Sniffing**: Includes an on-window `PCF Scan` button with a live progress/ETA bar, plus opportunistic passive page sniffing while browsing the Auction House.
- **Peer-to-Peer Guild Mesh Sync**: Shares delta-compressed price updates (`<245` bytes per chunk) across guild members with strict anti-chattiness cooldowns.
- **Item Tooltip Integration**: Displays `AH  Price:` with gold/silver/copper coin icons aligned directly beneath `Sell Price:`. Automatically yields its scan button and tooltip when `TradeSkillMaster` or `Auctionator` is installed.

---

## Slash Commands (`/pcf`)
- `/pcf scan` — Start a full Auction House scan (with the AH window open)
- `/pcf toggle` — Enable or disable automatic chat price-check replies
- `/pcf button` — Toggle the Auction House `PCF Scan` button on or off
- `/pcf tooltip` — Toggle item tooltip `AH  Price:` display on or off
- `/pcf sniff` — Toggle passive AH browse-sniffing on or off
- `/pcf sync` — Toggle guild peer-to-peer mesh sync on or off

---

## Developer API & Suite Embedding

`PriceCheckerForever` exposes a global table `_G.PCF_API` and can either be queried as an optional external dependency or embedded directly inside a host UI suite (such as `ThiccUI` or `ElvUI`).

### 1. Public Lua API (`PCF_API`)

```lua
-- Check if PCF is initialized and ready
if PCF_API and PCF_API.IsReady() then
    -- 1. Query price by Item Link or numeric Item ID
    -- Returns: priceInCopper (number|nil), sourceName ("TSM"|"Auctionator"|"Native"|"Mesh"|"Sniff"|"Vendor"|"None"), detailedSource (string)
    local copper, source, detail = PCF_API.GetPrice(19019)
    if copper then
        print("Market Price:", PCF_API.FormatMoney(copper), "via", source)
    end

    -- 2. Format copper into "Xg Ys Zc" or coin-icon tooltip string
    local text = PCF_API.FormatMoney(3501250)         -- "350g 12s 50c"
    local coins = PCF_API.FormatTooltipMoney(3501250) -- Coin texture string

    -- 3. Check when an item's cached price was last updated (epoch timestamp or nil)
    local lastUpdated = PCF_API.GetPriceTimestamp(19019)

    -- 4. Programmatically trigger a price-check response in GUILD, PARTY, RAID, or WHISPER
    PCF_API.RequestPriceCheck(itemLink, "GUILD")
end
```

### 2. Embedding in a Host UI Suite (`.pkgmeta` & `.toc`)

#### Step A: Declare in `.pkgmeta`
```yaml
externals:
  Libs/PriceCheckerForever:
    url: https://github.com/doodadrood/PriceCheckerForever.git
    tag: latest
```

#### Step B: Declare in Host `.toc`
Add `PriceCheckerForever` to `OptionalDeps` (so standalone installs load first) and reference `Embed.xml`:
```toc
## OptionalDeps: PriceCheckerForever, TradeSkillMaster, Auctionator
## SavedVariables: ThiccUI_DB, PCF_DB

Libs\PriceCheckerForever\Embed.xml
```

*(Optional)* If your suite prefers storing PCF data inside its own SavedVariables table instead of `PCF_DB`, call:
```lua
PCF_API.SetSavedVariables(ThiccUI_DB.PriceChecker)
```

> **Note:** If a player has both standalone `PriceCheckerForever` and your host suite installed, `_G.PCF_INITIALIZED` automatically prevents double-initialization and links both to the single active instance.
