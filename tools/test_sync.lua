--[[
    test_sync.lua - runs two simulated clients against each other and checks that
    one ends up knowing the other's bags.

    Usage (from the repo root):
        lua tools/test_sync.lua [path/to/Bagertz.lua]

    The parts worth testing here are the ones that are expensive to debug in
    game: the password tag, the payload obfuscation round-trip, chunk
    reassembly, and - most importantly - that a client with the WRONG password
    is ignored. A bug in any of those is either silent (no data) or corrupting
    (wrong counts), and neither announces itself while you're playing.

    Rather than mocking BZ's own functions, this loads the addon twice into two
    separate global environments, so "client A" and "client B" are genuinely two
    independent copies of the addon, and messages are handed between them the
    way the server would.
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

-- One simulated client: its own BZ table, its own saved variables, its own bags.
local activate
local function newClient(charName, bags, bank)
    Stub.Reset()
    Stub.SetRoster({ player = charName, party = { "Someone" } })

    GetRealmName = function() return "N'Zoth" end
    GetNumPartyMembers = function() return 1 end
    GetNumRaidMembers = function() return 0 end
    IsInGuild = function() return nil end
    time = os.time
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    ItemRefTooltip = Stub.CreateFrame("Frame", "ItemRefTooltip")
    GetLootSlotLink = function() return nil end
    GetInventoryItemLink = function() return nil end

    BZ = nil
    dofile(ADDON_PATH)
    local client = { BZ = BZ, sent = {}, name = charName, bags = bags, bank = bank }
    BZ.data, BZ.config = {}, {}
    activate(client)
    return client
end

-- Swap EVERY global that distinguishes one client from the other, not just BZ.
-- Creating a second client calls Stub.Reset(), which reinstalls globals - so a
-- half-hearted activate() left the first client reading the second one's bags,
-- which is exactly as confusing to debug as it sounds.
function activate(client)
    BZ = client.BZ
    UnitName = function(unit) return unit == "player" and client.name or nil end
    SendAddonMessage = function(prefix, msg, channel)
        table.insert(client.sent, { prefix = prefix, msg = msg, channel = channel })
    end
    -- bags = { [bagIndex] = { {id=, count=}, ... } }
    -- Bank containers only report slots while the bank frame is open, exactly
    -- like the real client - so a test that forgets to open it sees no bank.
    local function container(bag)
        if bag <= -1 or bag >= 5 then
            return (client.BZ and client.BZ.atBank) and client.bank and client.bank[bag] or nil
        end
        return client.bags[bag]
    end
    GetContainerNumSlots = function(bag)
        local b = container(bag)
        return b and table.getn(b) or 0
    end
    GetContainerItemLink = function(bag, slot)
        local b = container(bag)
        local item = b and b[slot]
        return item and ("|cffffffff|Hitem:" .. item.id .. ":0:0:0|h[Thing]|h|r") or nil
    end
    GetContainerItemInfo = function(bag, slot)
        local b = container(bag)
        local item = b and b[slot]
        if not item then return nil end
        return "texture", item.count, nil, 1, nil
    end
end

-- Drain everything client `from` has queued into client `to`.
local function deliver(from, to)
    activate(from)
    while table.getn(from.BZ.sendQueue) > 0 do
        from.BZ.DrainQueue()
    end
    local messages = from.sent
    from.sent = {}
    for _, m in ipairs(messages) do
        activate(to)
        to.BZ.OnAddonMessage(m.msg, from.name)
    end
    return table.getn(messages)
end

local ALICE_BAGS = {
    [0] = { { id = 2589, count = 20 }, { id = 858, count = 5 } },
    [1] = { { id = 2589, count = 12 }, { id = 4306, count = 8 } },
}

-- ---------------------------------------------------------------------------
print("obfuscation round-trips exactly")
do
    local c = newClient("Alice", ALICE_BAGS)
    activate(c)
    c.BZ.config.password = "hunter2"

    local plain = "2589:32,858:5,4306:8"
    local cipher = c.BZ.Crypt(plain, 424242, false)
    check("ciphertext differs from plaintext", cipher ~= plain, true)
    check("length is unchanged", string.len(cipher), string.len(plain))
    check("decrypts back to the original", c.BZ.Crypt(cipher, 424242, true), plain)
    check("a different nonce does NOT decrypt it", c.BZ.Crypt(cipher, 999999, true) ~= plain, true)

    c.BZ.config.password = "different"
    check("a different password does NOT decrypt it", c.BZ.Crypt(cipher, 424242, true) ~= plain, true)
end

-- ---------------------------------------------------------------------------
print("the password itself never appears on the wire")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.password = "hunter2"
    a.BZ.UpdateOwnData()
    -- A peer has to have been heard before the inventory will go out at all,
    -- so seed one; otherwise only the beacon is sent.
    a.BZ.peers["Bob"] = { time = os.time(), channel = "PARTY" }
    a.BZ.SendBeacon()
    a.BZ.SendInventory()
    while table.getn(a.BZ.sendQueue) > 0 do a.BZ.DrainQueue() end

    local leaked = false
    for _, m in ipairs(a.sent) do
        if string.find(m.msg, "hunter2", 1, true) then leaked = true end
    end
    check("no message contains the password", leaked, false)
    check("something was actually sent", table.getn(a.sent) > 1, true)
end

-- ---------------------------------------------------------------------------
print("the inventory is held back until a paired box has been heard")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.password = "shared"
    a.BZ.UpdateOwnData()
    a.BZ.SendInventory()
    while table.getn(a.BZ.sendQueue) > 0 do a.BZ.DrainQueue() end
    check("nothing sent with no peer known", table.getn(a.sent), 0)

    a.BZ.peers["Bob"] = { time = os.time(), channel = "PARTY" }
    a.BZ.SendInventory()
    while table.getn(a.BZ.sendQueue) > 0 do a.BZ.DrainQueue() end
    check("sent once a peer is known", table.getn(a.sent) > 0, true)
    check("  and only to that peer's channel", a.sent[1].channel, "PARTY")
end

-- ---------------------------------------------------------------------------
print("two paired clients exchange bag counts")
do
    local a = newClient("Alice", ALICE_BAGS)
    local b = newClient("Bob", { [0] = { { id = 1234, count = 3 } } })
    activate(a); a.BZ.config.password = "shared"; a.BZ.UpdateOwnData()
    activate(b); b.BZ.config.password = "shared"; b.BZ.UpdateOwnData()

    -- Alice's own scan should have merged the same item across two bags.
    activate(a)
    check("own scan totals an item across bags", a.BZ.data["Alice"].bags[2589], 32)

    -- Alice beacons; Bob hears it, trusts it, and replies with his inventory.
    activate(a); a.BZ.SendBeacon()
    deliver(a, b)
    activate(b)
    check("Bob registered Alice as a peer", b.BZ.peers["Alice"] ~= nil, true)

    deliver(b, a)
    activate(a)
    check("Alice learned Bob", a.BZ.data["Bob"] ~= nil, true)
    check("  with the right count", a.BZ.data["Bob"].bags[1234], 3)

    -- And the other direction.
    activate(b); b.BZ.SendBeacon()
    deliver(b, a)
    deliver(a, b)
    activate(b)
    check("Bob learned Alice", b.BZ.data["Alice"] ~= nil, true)
    check("  2589 total across both bags", b.BZ.data["Alice"].bags[2589], 32)
    check("  858", b.BZ.data["Alice"].bags[858], 5)
    check("  4306", b.BZ.data["Alice"].bags[4306], 8)
end

-- ---------------------------------------------------------------------------
print("a client with the wrong password is ignored entirely")
do
    local a = newClient("Alice", ALICE_BAGS)
    local b = newClient("Bob", { [0] = { { id = 1234, count = 3 } } })
    activate(a); a.BZ.config.password = "correct"; a.BZ.UpdateOwnData()
    activate(b); b.BZ.config.password = "WRONG";   b.BZ.UpdateOwnData()

    activate(a); a.BZ.SendBeacon(); a.BZ.SendInventory()
    deliver(a, b)
    activate(b)
    check("Bob did not register Alice as a peer", b.BZ.peers["Alice"], nil)
    check("Bob did not cache Alice's bags", b.BZ.data["Alice"], nil)
end

-- ---------------------------------------------------------------------------
print("a client with no password neither sends nor accepts")
do
    local a = newClient("Alice", ALICE_BAGS)
    local b = newClient("Bob", { [0] = { { id = 1234, count = 3 } } })
    activate(a); a.BZ.config.password = nil; a.BZ.UpdateOwnData()
    activate(b); b.BZ.config.password = "shared"; b.BZ.UpdateOwnData()

    -- pcall matters here: refusing to send by THROWING would also leave the
    -- queue empty, so "nothing was sent" alone can't tell a deliberate no-op
    -- from a script error in the player's face. It has to be both.
    activate(a)
    local ok, err = pcall(function() a.BZ.SendBeacon(); a.BZ.SendInventory() end)
    check("refusing to send raises no error", ok, true)
    if not ok then print("      error was: " .. tostring(err)) end
    while table.getn(a.BZ.sendQueue) > 0 do a.BZ.DrainQueue() end
    check("nothing was sent without a password", table.getn(a.sent), 0)

    activate(b); b.BZ.SendBeacon(); b.BZ.SendInventory()
    deliver(b, a)
    activate(a)
    check("nothing was accepted without a password", a.BZ.data["Bob"], nil)
end

-- ---------------------------------------------------------------------------
print("a big inventory is chunked and reassembled")
do
    local big = { [0] = {} }
    for i = 1, 60 do
        table.insert(big[0], { id = 10000 + i, count = i })
    end
    local a = newClient("Alice", big)
    local b = newClient("Bob", { [0] = {} })
    activate(a); a.BZ.config.password = "shared"; a.BZ.UpdateOwnData()
    activate(b); b.BZ.config.password = "shared"; b.BZ.UpdateOwnData()

    activate(a)
    a.BZ.peers["Bob"] = { time = os.time(), channel = "PARTY" }
    a.BZ.SendInventory()
    local count = deliver(a, b)
    check("it took more than one message", count > 2, true)

    activate(b)
    check("Bob reassembled it", b.BZ.data["Alice"] ~= nil, true)
    if b.BZ.data["Alice"] then
        local n = 0
        for _ in pairs(b.BZ.data["Alice"].bags) do n = n + 1 end
        check("  all 60 item types arrived", n, 60)
        check("  first item correct", b.BZ.data["Alice"].bags[10001], 1)
        check("  last item correct", b.BZ.data["Alice"].bags[10060], 60)
    end

    -- Every message must fit in vanilla's addon message limit.
    local longest = 0
    for _, m in ipairs(b.sent) do longest = math.max(longest, string.len(m.msg)) end
    activate(a)
end

-- ---------------------------------------------------------------------------
print("no message exceeds the 255-byte addon message limit")
do
    local big = { [0] = {} }
    for i = 1, 80 do table.insert(big[0], { id = 100000 + i, count = 999 }) end
    local a = newClient("Alice", big)
    activate(a); a.BZ.config.password = "shared"; a.BZ.UpdateOwnData()
    a.BZ.SendBeacon(); a.BZ.SendInventory()
    while table.getn(a.BZ.sendQueue) > 0 do a.BZ.DrainQueue() end

    local longest = 0
    for _, m in ipairs(a.sent) do
        if string.len(m.msg) > longest then longest = string.len(m.msg) end
    end
    check("longest message is under 255 (" .. longest .. ")", longest < 255, true)
end

-- ---------------------------------------------------------------------------
print("tooltip lists you first, then other characters")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.password = "shared"
    a.BZ.UpdateOwnData()
    a.BZ.data["Bob"] = { realm = "N'Zoth", time = os.time(), bags = { [2589] = 40 } }

    local lines = {}
    local tip = Stub.CreateFrame("Frame")
    tip.AddLine = function(self, text) table.insert(lines, text) end
    tip.Show = function() end

    a.BZ.AddTooltipLines(tip, 2589)
    check("a line each for you and the other character", table.getn(lines), 2)
    check("  your own count comes first", lines[1], "Alice: 32 in bags")
    check("  then the other character", lines[2], "Bob: 40 in bags")

    lines = {}
    a.BZ.AddTooltipLines(tip, 999999)
    check("nothing for an item nobody has", table.getn(lines), 0)
end

-- ---------------------------------------------------------------------------
print("tooltip shows bank alongside bags, with a total")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.data["Bob"] = {
        realm = "N'Zoth", time = os.time(),
        bags = { [2589] = 4 }, bank = { [2589] = 60 },
    }

    local lines = {}
    local tip = Stub.CreateFrame("Frame")
    tip.AddLine = function(self, text) table.insert(lines, text) end
    tip.Show = function() end

    -- This client never scanned its own bags, so Bob is the only line.
    a.BZ.AddTooltipLines(tip, 2589)
    check("both locations and a total", lines[1], "Bob: 4 in bags, 60 in bank (64)")

    -- Bank-only should not claim "0 in bags".
    lines = {}
    a.BZ.data["Bob"] = { realm = "N'Zoth", time = os.time(), bags = {}, bank = { [777] = 5 } }
    a.BZ.AddTooltipLines(tip, 777)
    check("bank only", lines[1], "Bob: 5 in bank")
end

-- ---------------------------------------------------------------------------
print("the account label prefixes the character name")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.account = "MAIN"
    a.BZ.UpdateOwnData()
    a.BZ.data["Bob"] = {
        realm = "N'Zoth", time = os.time(), account = "ALT", bags = { [2589] = 40 },
    }

    local lines = {}
    local tip = Stub.CreateFrame("Frame")
    tip.AddLine = function(self, text) table.insert(lines, text) end
    tip.Show = function() end

    a.BZ.AddTooltipLines(tip, 2589)
    check("your own account label", lines[1], "MAIN/Alice: 32 in bags")
    check("the other box's label", lines[2], "ALT/Bob: 40 in bags")

    -- An unlabelled character shouldn't show a dangling slash.
    a.BZ.data["Bob"].account = nil
    lines = {}
    a.BZ.AddTooltipLines(tip, 2589)
    check("no label means no prefix", lines[2], "Bob: 40 in bags")
end

-- ---------------------------------------------------------------------------
print("bank is scanned at the bank, kept after leaving, and synced")
do
    local BANK = { [-1] = { { id = 2589, count = 100 } }, [5] = { { id = 4306, count = 20 } } }
    local a = newClient("Alice", ALICE_BAGS, BANK)
    local b = newClient("Bob", { [0] = {} })
    activate(a); a.BZ.config.password = "shared"; a.BZ.config.account = "MAIN"
    activate(b); b.BZ.config.password = "shared"

    -- Away from a bank: nothing recorded.
    activate(a)
    a.BZ.UpdateOwnData()
    check("no bank recorded away from a bank", a.BZ.data["Alice"].bank, nil)

    -- At the bank.
    a.BZ.atBank = true
    a.BZ.UpdateOwnData()
    check("bank scanned at the bank", a.BZ.data["Alice"].bank[2589], 100)
    check("  including bank bags", a.BZ.data["Alice"].bank[4306], 20)

    -- Walking away must NOT wipe it, even though the containers go unreadable.
    a.BZ.atBank = false
    a.BZ.UpdateOwnData()
    check("bank kept after leaving", a.BZ.data["Alice"].bank[2589], 100)

    -- And it reaches the other box.
    a.BZ.peers["Bob"] = { time = os.time(), channel = "PARTY" }
    a.BZ.SendInventory()
    deliver(a, b)
    activate(b)
    check("Bob received Alice's bank", b.BZ.data["Alice"].bank[2589], 100)
    check("  and her bags", b.BZ.data["Alice"].bags[2589], 32)
    check("  and her account label", b.BZ.data["Alice"].account, "MAIN")
end

-- ---------------------------------------------------------------------------
print("a sync hands over every character on the account, not just the one online")
do
    local a = newClient("Alice", ALICE_BAGS)
    local b = newClient("Bob", { [0] = {} })
    activate(a); a.BZ.config.password = "shared"; a.BZ.config.account = "MAIN"
    activate(b); b.BZ.config.password = "shared"; b.BZ.UpdateOwnData()

    activate(a)
    a.BZ.UpdateOwnData()
    -- Two alts on this account that are NOT logged in - the whole reason the
    -- account keeps a roster.
    a.BZ.data["Mahidot"]  = { mine = true, time = 100, bags = { [555] = 7 }, bank = { [555] = 70 } }
    a.BZ.data["Mahislap"] = { mine = true, time = 200, bags = { [666] = 9 } }
    -- And one learned from elsewhere, which must NOT be relayed back.
    a.BZ.data["Stranger"] = { time = 300, bags = { [999] = 1 } }

    check("owned roster is the three on this account", table.getn(a.BZ.OwnedCharacters()), 3)

    -- Bob beacons; Alice hears a new peer and hands over the whole roster.
    activate(b); b.BZ.SendBeacon()
    deliver(b, a)
    deliver(a, b)

    activate(b)
    check("Bob learned the online character", b.BZ.data["Alice"] ~= nil, true)
    check("Bob learned an offline alt", b.BZ.data["Mahidot"] ~= nil, true)
    check("  with its bags", b.BZ.data["Mahidot"].bags[555], 7)
    check("  and its bank", b.BZ.data["Mahidot"].bank[555], 70)
    check("Bob learned the second alt", b.BZ.data["Mahislap"].bags[666], 9)
    check("all carry the sender's account label", b.BZ.data["Mahidot"].account, "MAIN")
    check("a learned character is NOT relayed on", b.BZ.data["Stranger"], nil)
    check("learned characters aren't marked as Bob's own", b.BZ.data["Mahidot"].mine, nil)
    check("Bob's own roster is still just Bob", table.getn(b.BZ.OwnedCharacters()), 1)
end

-- ---------------------------------------------------------------------------
print("a bag change re-sends only the character that changed")
do
    local a = newClient("Alice", ALICE_BAGS)
    local b = newClient("Bob", { [0] = {} })
    activate(a); a.BZ.config.password = "shared"
    activate(b); b.BZ.config.password = "shared"

    activate(a)
    a.BZ.UpdateOwnData()
    a.BZ.data["Mahidot"] = { mine = true, time = 100, bags = { [555] = 7 } }
    a.BZ.peers["Bob"] = { time = os.time(), channel = "PARTY" }

    a.BZ.SendInventory()          -- self only, as a bag change would
    deliver(a, b)
    activate(b)
    check("only the online character arrived", b.BZ.data["Mahidot"], nil)
    check("  and that one did", b.BZ.data["Alice"] ~= nil, true)

    activate(a); a.BZ.SendInventory("all")
    deliver(a, b)
    activate(b)
    check("an explicit full sync brings the alt too", b.BZ.data["Mahidot"].bags[555], 7)
end

-- ---------------------------------------------------------------------------
print("character names are obfuscated rather than sent in the clear")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.password = "shared"
    a.BZ.UpdateOwnData()
    a.BZ.data["Mahislap"] = { mine = true, time = 100, bags = { [666] = 9 } }
    a.BZ.peers["Bob"] = { time = os.time(), channel = "PARTY" }
    a.BZ.SendInventory("all")
    while table.getn(a.BZ.sendQueue) > 0 do a.BZ.DrainQueue() end

    local leaked = false
    for _, m in ipairs(a.sent) do
        if string.find(m.msg, "Mahislap", 1, true) then leaked = true end
    end
    check("an alt's name does not appear in plaintext", leaked, false)
end

-- ---------------------------------------------------------------------------
print("a transfer in an unknown wire format is refused, not half-parsed")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.password = "shared"
    local nonce = 123456
    a.BZ.OnAddonMessage("H~99~" .. nonce .. "~" .. a.BZ.Tag(nonce) .. "~MAIN~1", "Bob")
    check("no transfer was opened", a.BZ.incoming["Bob"], nil)
    check("and it was counted as rejected", a.BZ.stats.rejected > 0, true)
end

-- ---------------------------------------------------------------------------
print("guild is used as a channel when guilded")
do
    local a = newClient("Alice", ALICE_BAGS)
    activate(a)
    a.BZ.config.password = "shared"

    IsInGuild = function() return nil end
    GetNumPartyMembers = function() return 0 end
    check("solo and unguilded: no channels", table.getn(a.BZ.Channels()), 0)

    IsInGuild = function() return 1 end
    local channels = a.BZ.Channels()
    check("guilded but ungrouped: guild only", table.concat(channels, ","), "GUILD")

    GetNumPartyMembers = function() return 1 end
    check("grouped and guilded: party first", a.BZ.Channels()[1], "PARTY")

    a.BZ.config.useGuild = false
    check("guild can be turned off", table.concat(a.BZ.Channels(), ","), "PARTY")
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
