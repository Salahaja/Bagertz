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
local function newClient(charName, bags)
    Stub.Reset()
    Stub.SetRoster({ player = charName, party = { "Someone" } })

    GetRealmName = function() return "N'Zoth" end
    GetNumPartyMembers = function() return 1 end
    GetNumRaidMembers = function() return 0 end
    time = os.time
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    ItemRefTooltip = Stub.CreateFrame("Frame", "ItemRefTooltip")
    GetLootSlotLink = function() return nil end
    GetInventoryItemLink = function() return nil end

    BZ = nil
    dofile(ADDON_PATH)
    local client = { BZ = BZ, sent = {}, name = charName, bags = bags }
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
    GetContainerNumSlots = function(bag)
        local b = client.bags[bag]
        return b and table.getn(b) or 0
    end
    GetContainerItemLink = function(bag, slot)
        local b = client.bags[bag]
        local item = b and b[slot]
        return item and ("|cffffffff|Hitem:" .. item.id .. ":0:0:0|h[Thing]|h|r") or nil
    end
    GetContainerItemInfo = function(bag, slot)
        local b = client.bags[bag]
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

    activate(a); a.BZ.SendInventory()
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
print("tooltip lines report other characters only")
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
    check("one line for the other character", table.getn(lines), 1)
    check("  naming Bob and his count", lines[1], "Bob: 40 in bags")

    lines = {}
    a.BZ.AddTooltipLines(tip, 999999)
    check("nothing for an item nobody has", table.getn(lines), 0)
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
