--[[
    test_tooltips.lua - counts appear on EVERY kind of item tooltip, not just
    the ones in your bags.

    Usage (from the repo root):
        lua tools/test_tooltips.lua [path/to/Bagertz.lua]

    v1.2.0 hooked four tooltip methods, so counts showed in bags and nowhere
    else - crafting frames, merchants and the auction house each call a
    different Set* method and got nothing. The suite never caught it because it
    tested AddTooltipLines directly and never drove a single hook.

    So this drives the hooks: install them on a mock tooltip, call the methods
    the game calls, and check what lands.
--]]

local Stub = dofile("tools/wow_stub.lua")
local ADDON_PATH = arg[1] or "Bagertz.lua"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

local function link(itemID, name)
    return "|cffffffff|Hitem:" .. itemID .. ":0:0:0|h[" .. (name or "Thing") .. "]|h|r"
end

local lines, origCalls

-- A tooltip carrying the Set* methods the real GameTooltip has. Each records
-- that it ran, so a hook that calls the original twice (or not at all) shows up.
local function makeTooltip(name, methods)
    local tip = Stub.CreateFrame("Frame", name)
    tip.AddLine = function(self, text) table.insert(lines, text) end
    tip.Show = function() end
    for _, m in ipairs(methods) do
        tip[m] = function(self, ...)
            origCalls[m] = (origCalls[m] or 0) + 1
            return "orig:" .. m
        end
    end
    return tip
end

local GAME_TOOLTIP_METHODS = {
    "SetBagItem", "SetInventoryItem", "SetHyperlink", "SetLootItem", "SetLootRollItem",
    "SetMerchantItem", "SetBuybackItem", "SetCraftItem", "SetCraftSpell",
    "SetTradeSkillItem", "SetQuestItem", "SetQuestLogItem", "SetTradePlayerItem",
    "SetTradeTargetItem", "SetAuctionItem",
}

local function boot()
    Stub.Reset()
    lines, origCalls = {}, {}
    time = os.time
    GetRealmName = function() return "N'Zoth" end
    GetNumPartyMembers = function() return 0 end
    GetNumRaidMembers = function() return 0 end
    IsInGuild = function() return nil end
    GetContainerNumSlots = function() return 0 end
    GetContainerItemLink = function() return link(2589, "Linen Cloth") end
    GetContainerItemInfo = function() return nil end

    -- The link getters behind each tooltip method.
    GetInventoryItemLink       = function() return link(2589) end
    GetLootSlotLink            = function() return link(2589) end
    GetLootRollItemLink        = function() return link(2589) end
    GetMerchantItemLink        = function() return link(2589) end
    GetBuybackItemLink         = function() return link(2589) end
    GetCraftItemLink           = function() return link(2589) end
    GetCraftReagentItemLink    = function() return link(2589) end
    GetTradeSkillItemLink      = function() return link(2589) end
    GetTradeSkillReagentItemLink = function() return link(2589) end
    GetQuestItemLink           = function() return link(2589) end
    GetQuestLogItemLink        = function() return link(2589) end
    GetTradePlayerItemLink     = function() return link(2589) end
    GetTradeTargetItemLink     = function() return link(2589) end
    GetAuctionItemLink         = function() return link(2589) end

    GameTooltip = makeTooltip("GameTooltip", GAME_TOOLTIP_METHODS)
    -- ItemRefTooltip really does have far fewer methods; hooking must skip the
    -- rest rather than erroring on them.
    ItemRefTooltip = makeTooltip("ItemRefTooltip", { "SetHyperlink" })

    BZ, Bagertz_Data, Bagertz_Config = nil, nil, nil
    dofile(ADDON_PATH)
    BZ.data, BZ.config = {}, {}

    -- Somebody else is holding 40 Linen Cloth, so any working tooltip says so.
    BZ.data["Salabeard"] = {
        realm = "N'Zoth", time = os.time(), bags = { [2589] = 40 },
    }
    BZ.HookTooltips()
end

-- ---------------------------------------------------------------------------
print("hooks install on both tooltips, skipping methods a frame lacks")
do
    boot()
    check("a good number of hooks went on", BZ.hookCount >= 15, true)
    check("ItemRefTooltip got the one it has", ItemRefTooltip.bzHookedSetHyperlink, true)
    check("  and not one it lacks", ItemRefTooltip.bzHookedSetCraftItem, nil)
end

-- ---------------------------------------------------------------------------
print("the crafting frames show counts (the reported bug)")
do
    boot()
    lines = {}
    GameTooltip:SetCraftItem(1, 2)      -- a reagent of an enchant
    check("Craft reagent gets a line", table.getn(lines), 1)
    check("  naming the holder and count", lines[1], "Salabeard: 40 in bags")

    lines = {}
    GameTooltip:SetCraftSpell(1)        -- the enchant itself
    check("Craft spell gets a line", table.getn(lines), 1)

    lines = {}
    GameTooltip:SetTradeSkillItem(3, 1) -- a reagent in any other profession
    check("TradeSkill reagent gets a line", table.getn(lines), 1)

    lines = {}
    GameTooltip:SetTradeSkillItem(3)    -- the crafted item itself
    check("TradeSkill product gets a line", table.getn(lines), 1)
end

-- ---------------------------------------------------------------------------
print("and everywhere else an item can appear")
do
    local cases = {
        { "SetBagItem", 0, 1 },
        { "SetInventoryItem", "player", 16 },
        { "SetHyperlink", link(2589) },
        { "SetLootItem", 1 },
        { "SetLootRollItem", 1 },
        { "SetMerchantItem", 1 },
        { "SetBuybackItem", 1 },
        { "SetQuestItem", "required", 1 },
        { "SetQuestLogItem", "required", 1 },
        { "SetTradePlayerItem", 1 },
        { "SetTradeTargetItem", 1 },
        { "SetAuctionItem", "list", 1 },
    }
    for _, case in ipairs(cases) do
        boot()
        lines = {}
        GameTooltip[case[1]](GameTooltip, case[2], case[3])
        check(case[1] .. " gets a line", table.getn(lines), 1)
    end
end

-- ---------------------------------------------------------------------------
print("a linked item in chat works from either tooltip")
do
    boot()
    lines = {}
    GameTooltip:SetHyperlink(link(2589))
    check("hovering a link", table.getn(lines), 1)

    lines = {}
    ItemRefTooltip:SetHyperlink(link(2589))
    check("clicking a link", table.getn(lines), 1)
end

-- ---------------------------------------------------------------------------
print("the original method runs exactly once, and its return is passed through")
do
    boot()
    local ret = GameTooltip:SetCraftItem(1, 2)
    check("original called once, not twice", origCalls["SetCraftItem"], 1)
    check("  and its return value survives the hook", ret, "orig:SetCraftItem")
end

-- ---------------------------------------------------------------------------
print("a broken link getter costs the counts, never the tooltip")
do
    boot()
    GetCraftReagentItemLink = function() error("server-custom item exploded") end
    lines = {}
    local ok, ret = pcall(function() return GameTooltip:SetCraftItem(1, 2) end)
    check("the tooltip still works", ok, true)
    check("  the original still ran", origCalls["SetCraftItem"], 1)
    check("  and returned normally", ret, "orig:SetCraftItem")
    check("  we simply add nothing", table.getn(lines), 0)
end

-- ---------------------------------------------------------------------------
print("an item nobody else holds adds nothing")
do
    boot()
    GetMerchantItemLink = function() return link(99999) end
    lines = {}
    GameTooltip:SetMerchantItem(1)
    check("no line for an unheld item", table.getn(lines), 0)
end

-- ---------------------------------------------------------------------------
print("hooking twice does not double the lines")
do
    boot()
    BZ.HookTooltips() -- e.g. another reload path calling it again
    lines = {}
    GameTooltip:SetBagItem(0, 1)
    check("still exactly one line", table.getn(lines), 1)
end

-- ---------------------------------------------------------------------------
print("")
if failures == 0 then
    print("all " .. checks .. " checks passed")
    os.exit(0)
else
    print(failures .. " of " .. checks .. " checks FAILED")
    os.exit(1)
end
