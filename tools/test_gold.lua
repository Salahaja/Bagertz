--[[
    test_gold.lua - gold across accounts, and Bagshui's gold tooltip.

    Usage (from the repo root):
        lua tools/test_gold.lua [path/to/Bagertz.lua]

    Like test_files.lua: two clients, loaded separately, sharing one folder.
    Bagshui is stood in for by the few pieces of it that Bagertz touches, in
    the shape Bagshui 1.0.5 has them.
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

local function plain(s)
    return (string.gsub(string.gsub(s or "", "|c%x%x%x%x%x%x%x%x", ""), "|r", ""))
end

RAID_CLASS_COLORS = {
    MAGE = { r = 0.41, g = 0.8, b = 0.94 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
}

local FILES = {}
local NOW = 1000
local activate

--- A character on its own client, with its own gold, class and account label.
local function newClient(charName, class, money, account)
    Stub.Reset()
    Stub.SetRoster({ player = charName, party = {} })
    -- Every frame the addon makes, so its event frame can be found.
    local frames, create = {}, CreateFrame
    CreateFrame = function(kind, name, parent)
        local f = create(kind, name, parent)
        table.insert(frames, f)
        return f
    end
    GetNumPartyMembers = function() return 0 end
    GetNumRaidMembers = function() return 0 end
    IsInGuild = function() return nil end
    time = function() return NOW end
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    ItemRefTooltip = Stub.CreateFrame("Frame", "ItemRefTooltip")
    GetLootSlotLink = function() return nil end
    GetInventoryItemLink = function() return nil end

    BZ = nil
    dofile(ADDON_PATH)
    local client = { BZ = BZ, name = charName, class = class, money = money, frames = frames }
    BZ.data, BZ.config = {}, { account = account }
    activate(client)
    return client
end

function activate(client)
    BZ = client.BZ
    UnitName = function(unit) return unit == "player" and client.name or nil end
    UnitClass = function(unit)
        if unit == "player" then return client.class, client.class end
    end
    GetMoney = function() return client.money end
    GetRealmName = function() return client.realm or "N'Zoth" end
    WriteCustomFile = function(name, text, mode)
        if mode == "a" then FILES[name] = (FILES[name] or "") .. text
        else FILES[name] = text end
    end
    ReadCustomFile = function(name) return FILES[name] end
    client.addon = client.addon or {}
    SendAddonMessage = function(prefix, msg, channel)
        table.insert(client.addon, { prefix = prefix, msg = msg, channel = channel })
    end
    GetContainerNumSlots = function() return 0 end
    GetContainerItemLink = function() return nil end
    GetContainerItemInfo = function() return nil end
end

--[[ What PLAYER_ENTERING_WORLD does, in the same order. The forced write
     belongs to logging in: a character whose gold and bags are exactly as it
     left them still has to stamp its file. ]]
local function login(client)
    activate(client)
    client.BZ.JoinRoster()
    client.BZ.UpdateOwnData()
    client.BZ.WriteOwn(true)
    client.BZ.ReadOthers()
end

-- The addon's own event frame: the one listening for gold.
local function eventFrame(client)
    for _, f in ipairs(client.frames) do
        if f._events and f._events["PLAYER_MONEY"] then return f end
    end
end
local function fire(client, ev)
    activate(client)
    Stub.FireScript(eventFrame(client), "OnEvent", ev)
end
local function tick(client, seconds)
    activate(client)
    Stub.FireScript(eventFrame(client), "OnUpdate", nil, seconds)
end

print("\nBagertz: gold across accounts\n")

----------------------------------------------------------------------
-- in the file
----------------------------------------------------------------------
do
    local alice = newClient("Alice", "MAGE", 1234567, "Main")
    login(alice)
    local file = FILES["Bagertz_NZoth_Alice.txt"]
    check("gold goes into the file", string.find(file, "\nG~1234567\n", 1, true) ~= nil, true)
    check("  with the class", string.find(file, "\nC~MAGE\n", 1, true) ~= nil, true)
    local _, e = alice.BZ.Deserialize(file)
    check("and both come back out", e.money .. " " .. e.class, "1234567 MAGE")
    local _, old = alice.BZ.Deserialize("BAGERTZ1\nM~Old~N'Zoth~900~0\nB~2589~5\n")
    check("a file from before 2.1 has no gold, not zero gold", old.money, nil)
end

----------------------------------------------------------------------
-- two accounts, one folder
----------------------------------------------------------------------
for k in pairs(FILES) do FILES[k] = nil end
local alice = newClient("Alice", "MAGE", 1234567, "Main")
local bob = newClient("Bob", "WARRIOR", 89000, "Alt")
login(alice)
login(bob)
do
    activate(bob)
    local list = bob.BZ.GoldList()
    check("the other account's gold is counted", table.getn(list), 2)
    check("  richest first", list[1].name .. " " .. list[1].money, "Alice 1234567")
    check("  with that account's label", list[1].account, "Main")
    check("  and the character's class", list[1].class, "MAGE")
    check("your own is counted too, under your label",
        list[2].name .. " " .. list[2].money .. " " .. list[2].account, "Bob 89000 Alt")

    -- Gold changes; after the short wait it is on disk, and over there.
    alice.money = 2000000
    NOW = NOW + 10
    fire(alice, "PLAYER_MONEY")
    tick(alice, 3)
    check("a change of gold reaches the file",
        string.find(FILES["Bagertz_NZoth_Alice.txt"], "\nG~2000000\n", 1, true) ~= nil, true)
    activate(bob)
    bob.BZ.ReadOthers()
    check("  and the other account", bob.BZ.GoldList()[1].money, 2000000)

    -- Somebody else's gold, another realm's, and gold nobody knows.
    bob.BZ.data["Partner"] = { realm = "N'Zoth", money = 999999999, fromChannel = NOW }
    bob.BZ.data["Faraway"] = { realm = "Kel'Thuzad", money = 5 }
    bob.BZ.data["Ghost"] = { realm = "N'Zoth" }
    local names = {}
    for _, c in ipairs(bob.BZ.GoldList()) do names[c.name] = true end
    check("a linked partner's gold is not yours", names.Partner, nil)
    check("another realm's is left out", names.Faraway, nil)
    check("a character whose gold is unknown is not counted as broke", names.Ghost, nil)
    bob.BZ.data["Partner"], bob.BZ.data["Faraway"], bob.BZ.data["Ghost"] = nil, nil, nil

    Stub.chat = {}
    SlashCmdList["BAGERTZ"]("gold")
    local said = plain(table.concat(Stub.chat, "\n"))
    check("/bz gold lists every account",
        string.find(said, "Alice (Main)  200g 0s 0c", 1, true) ~= nil and
        string.find(said, "Bob (Alt)  8g 90s 0c", 1, true) ~= nil, true)
    check("  and adds it up", string.find(said, "total: 208g 90s 0c", 1, true) ~= nil, true)
end

----------------------------------------------------------------------
-- Bagshui's gold tooltip
----------------------------------------------------------------------
do
    local lines, calls = {}, 0
    local tip = {
        AddDoubleLine = function(self, l, r) table.insert(lines, plain(l) .. " | " .. plain(r)) end,
    }
    -- Bagshui 1.0.5, as far as Bagertz reaches into it.
    Bagshui = {
        environment = { BS_CATALOG_LOCATIONS = { MONEY = "$$$" } },
        components = {
            Util = { FormatMoneyString = function(c) return "<" .. c .. ">" end },
            Catalog = {
                initialized = true,
                totals = { ["N'Zoth"] = { _sortedCharacterList = { "Bob" } } },
                GetTotal = function(self, storage, subtotal, key) return 89000 end,
                AddTooltipInfo = function(self, itemString, tooltip)
                    calls = calls + 1
                    tooltip:AddDoubleLine("N'Zoth", "<89000>")
                    return true
                end,
            },
        },
    }
    local catalog = Bagshui.components.Catalog

    fire(bob, "PLAYER_ENTERING_WORLD")
    local added = catalog:AddTooltipInfo("$$$", tip)
    check("Bagshui's own gold lines come first", lines[1], "N'Zoth | <89000>")
    check("  then your other account", lines[2], "Other accounts | <2000000>")
    check("  each character by name and label", lines[3], "  Alice (Main) | <2000000>")
    check("  then every account together", lines[4], "All accounts | <2089000>")
    check("  and nobody Bagshui lists is listed twice", table.getn(lines), 4)
    check("the tooltip still says it added lines", added, true)
    check("Bagshui's own function still runs, once", calls, 1)

    lines = {}
    catalog:AddTooltipInfo("item:2589:0:0:0", tip)
    check("an item's tooltip is left to Bagshui", table.getn(lines), 1)

    catalog.initialized = false
    lines = {}
    catalog:AddTooltipInfo("$$$", tip)
    check("before Bagshui has read its data, nothing is added", table.getn(lines), 1)
    catalog.initialized = true

    fire(bob, "PLAYER_ENTERING_WORLD")
    lines, calls = {}, 0
    catalog:AddTooltipInfo("$$$", tip)
    check("another loading screen does not hook it twice", table.getn(lines) .. "/" .. calls, "4/1")

    catalog.totals["N'Zoth"]._sortedCharacterList = { "Alice", "Bob" }
    lines = {}
    catalog:AddTooltipInfo("$$$", tip)
    check("with nobody Bagshui does not know, nothing is added", table.getn(lines), 1)
    catalog.totals["N'Zoth"]._sortedCharacterList = { "Bob" }

    Bagshui.components.Util = nil
    lines = {}
    catalog:AddTooltipInfo("$$$", tip)
    check("without Bagshui's money format, Bagertz's own", lines[2], "Other accounts | 200g 0s 0c")

    catalog.GetTotal = function() error("Bagshui changed") end
    lines = {}
    local ok = pcall(catalog.AddTooltipInfo, catalog, "$$$", tip)
    check("a Bagshui that has changed costs the total line, not an error",
        tostring(ok) .. " " .. table.getn(lines), "true 3")

    -- No Bagshui at all.
    Bagshui = nil
    local carl = newClient("Carl", "WARRIOR", nil, nil)
    local fine = pcall(function() login(carl) fire(carl, "PLAYER_ENTERING_WORLD") end)
    check("without Bagshui nothing is hooked, and nothing breaks", fine, true)
    Stub.chat = {}
    for k in pairs(FILES) do FILES[k] = nil end
    carl.BZ.data = {}
    SlashCmdList["BAGERTZ"]("gold")
    check("with no gold known, /bz gold says why",
        string.find(plain(table.concat(Stub.chat, "\n")), "no gold known yet", 1, true) ~= nil, true)
end


----------------------------------------------------------------------
-- two accounts logged in at once
--
-- The case the folder exists for, and the one where "only write when
-- something changed" could go wrong: both clients are live, each is the only
-- author of its own file, and each has to notice the other's gold moving
-- without anybody telling it to look.
----------------------------------------------------------------------
do
    for k in pairs(FILES) do FILES[k] = nil end
    NOW = NOW + 1000

    local a = newClient("Alice", "MAGE", 1000000, "Main")
    local b = newClient("Bob", "WARRIOR", 250000, "Alt")
    login(a)
    login(b)
    activate(a) a.BZ.ReadOthers()   -- Bob's file exists now

    activate(a)
    check("Alice sees Bob's gold", a.BZ.data["Bob"] and a.BZ.data["Bob"].money, 250000)
    activate(b)
    check("Bob sees Alice's gold", b.BZ.data["Alice"] and b.BZ.data["Alice"].money, 1000000)

    --[[ Bob earns some. The write is what the other client has to see, and
         with "only write when changed" it happens only because the content key
         covers gold as well as bags -- which is exactly the thing a bag-only
         key would have missed. ]]
    activate(b)
    b.money = 275000
    NOW = NOW + 10
    fire(b, "PLAYER_MONEY")
    tick(b, 3)                       -- past the scan debounce
    check("Bob's own figure updates", b.BZ.data["Bob"].money, 275000)
    check("and reaches his file",
        string.find(FILES["Bagertz_NZoth_Bob.txt"] or "", "G~275000", 1, true) ~= nil, true)

    activate(a)
    NOW = NOW + 10
    a.BZ.ReadOthers()
    check("Alice picks the new figure up", a.BZ.data["Bob"].money, 275000)

    -- And the other way, both still live.
    activate(a)
    a.money = 1500000
    NOW = NOW + 10
    fire(a, "PLAYER_MONEY")
    tick(a, 3)
    activate(b)
    NOW = NOW + 10
    b.BZ.ReadOthers()
    check("Bob picks up Alice's", b.BZ.data["Alice"].money, 1500000)

    --[[ Spending it, not just earning. A key that compared only "is there a
         gold line" rather than its value would pass everything above. ]]
    activate(b)
    b.money = 1000
    NOW = NOW + 10
    fire(b, "PLAYER_MONEY")
    tick(b, 3)
    activate(a)
    NOW = NOW + 10
    a.BZ.ReadOthers()
    check("a figure that went down is picked up too", a.BZ.data["Bob"].money, 1000)

    -- Gold that did not move must not cost a write.
    activate(b)
    local writes = 0
    local realWrite = WriteCustomFile
    WriteCustomFile = function(n, t, m) writes = writes + 1 return realWrite(n, t, m) end
    NOW = NOW + 10
    fire(b, "PLAYER_MONEY")
    tick(b, 3)
    check("being paid nothing writes nothing", writes, 0)
    WriteCustomFile = realWrite

    ----------------------------------------------------------------------
    -- and what each of them reports
    ----------------------------------------------------------------------
    activate(a)
    Stub.chat = {}
    SlashCmdList["BAGERTZ"]("gold")
    local said = plain(table.concat(Stub.chat, "\n"))
    check("Alice's report names her", string.find(said, "Alice", 1, true) ~= nil, true)
    check("and Bob", string.find(said, "Bob", 1, true) ~= nil, true)
    check("and both account labels",
        string.find(said, "Main", 1, true) ~= nil
            and string.find(said, "Alt", 1, true) ~= nil, true)
    check("and totals the two", string.find(said, "total", 1, true) ~= nil, true)

    activate(b)
    Stub.chat = {}
    SlashCmdList["BAGERTZ"]("gold")
    said = plain(table.concat(Stub.chat, "\n"))
    check("Bob's report names Alice too", string.find(said, "Alice", 1, true) ~= nil, true)
    check("and himself", string.find(said, "Bob", 1, true) ~= nil, true)

    --[[ A character that has never logged in since gold was added has no
         figure at all, and must be left out rather than counted as zero --
         which would quietly understate the total. ]]
    FILES["Bagertz_NZoth_Carol.txt"] =
        "BAGERTZ1\nM~Carol~N'Zoth~" .. NOW .. "~0\nB~2589~5\n"
    FILES["Bagertz_roster.txt"] = (FILES["Bagertz_roster.txt"] or "") .. "R~Carol~N'Zoth\n"
    activate(a)
    NOW = NOW + 10
    a.BZ.ReadOthers()
    check("a character with no gold line is read", a.BZ.data["Carol"] ~= nil, true)
    check("but has no figure", a.BZ.data["Carol"].money, nil)
    local inList = false
    local list = a.BZ.GoldList()
    for i = 1, table.getn(list) do
        if list[i].name == "Carol" then inList = true end
    end
    check("and is left out of the gold report rather than counted as zero", inList, false)
end


----------------------------------------------------------------------
-- the folder outranks the channel
--
-- Two accounts on one machine share the folder. Link them over the channel as
-- well -- which /bz share lets you do, and which costs nothing to leave on --
-- and each relays what it read from the folder to the other. That is right for
-- a partner on another PC, who has no folder access. Here it is an echo.
--
-- The echo used to be applied, and applying it was expensive: the wire format
-- carries bags and bank but NO GOLD, and the receiving client marked those
-- characters as channel-sourced, which drops them straight out of /bz gold.
-- You saw "Bagertz: updated N characters" and your other account's gold
-- disappeared in the same breath.
----------------------------------------------------------------------
do
    for k in pairs(FILES) do FILES[k] = nil end
    NOW = NOW + 1000

    local a = newClient("Ann", "MAGE", 900000, "Main")
    local b = newClient("Ben", "WARRIOR", 400000, "Alt")
    login(a)
    login(b)
    activate(a) a.BZ.ReadOthers()

    activate(a)
    check("Ann reads Ben's gold out of the folder",
        a.BZ.data["Ben"] and a.BZ.data["Ben"].money, 400000)
    local function counted(client, who)
        activate(client)
        local list = client.BZ.GoldList()
        for i = 1, table.getn(list) do
            if list[i].name == who then return true end
        end
        return false
    end
    check("and counts it", counted(a, "Ben"), true)

    --[[ Now link them, as /bz share does, and let Ben broadcast. Both ends
         need the same secret or the transfer is refused before it is read. ]]
    activate(a) a.BZ.config.password = "shared"
    activate(b) b.BZ.config.password = "shared"
    b.BZ.peers["Ann"] = { time = NOW, channel = "PARTY" }
    b.BZ.lastSent = {}
    b.BZ.SendInventory("all")
    while table.getn(b.BZ.sendQueue) > 0 do b.BZ.DrainQueue() end
    local sent = b.addon
    b.addon = {}
    check("Ben actually broadcast something", table.getn(sent) > 0, true)

    activate(a)
    for i = 1, table.getn(sent) do
        a.BZ.OnAddonMessage(sent[i].msg, "Ben")
    end

    --[[ The check that matters. Ben's entry came from the folder and the
         channel has nothing better; it must not be demoted to a wire entry
         that no longer counts. ]]
    check("Ben's gold survives the broadcast",
        a.BZ.data["Ben"] and a.BZ.data["Ben"].money, 400000)
    check("he is still counted as coming from the folder",
        a.BZ.data["Ben"].fromFile ~= nil, true)
    check("and not as a channel entry", a.BZ.data["Ben"].fromChannel, nil)
    check("so he is still in the gold report", counted(a, "Ben"), true)

    Stub.chat = {}
    SlashCmdList["BAGERTZ"]("gold")
    check("which still names him",
        string.find(plain(table.concat(Stub.chat, "\n")), "Ben", 1, true) ~= nil, true)

    --[[ And it has to stay fixed. The read cache skips a file whose bytes have
         not changed, so if anything ever does overwrite a file-backed entry,
         the cache must notice and re-parse rather than go on skipping the one
         file that would put it right. Simulated here by demoting the entry by
         hand, which is precisely what the old receive path did. ]]
    a.BZ.data["Ben"].fromFile = nil
    a.BZ.data["Ben"].fromChannel = NOW
    NOW = NOW + 10
    a.BZ.ReadOthers()
    check("a demoted entry is restored from its file on the next read",
        a.BZ.data["Ben"].fromFile ~= nil, true)
    check("with its gold back", a.BZ.data["Ben"].money, 400000)
    check("and counting again", counted(a, "Ben"), true)

    --[[ A genuine partner is still heard. The guard must key on "we have their
         file", not on "a password is set", or linking with someone on another
         PC would stop working entirely. ]]
    activate(a)
    a.BZ.OnAddonMessage("B~123456~" .. tostring(a.BZ.Tag("123456")) .. "~Zoe", "Zoe")
    check("a stranger with the right secret is still paired with",
        a.BZ.peers["Zoe"] ~= nil, true)
end

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
