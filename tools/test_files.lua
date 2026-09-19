--[[
    test_files.lua - two simulated clients sharing one CustomData folder.

    Usage (from the repo root):
        lua tools/test_files.lua [path/to/Bagertz.lua]

    This replaces test_sync.lua, which tested a wire protocol that no longer
    exists: the password tag, the payload obfuscation, chunk reassembly and
    rejecting a client with the wrong password. None of that was the feature.
    All of it existed to survive a broadcast channel, and a folder on your own
    disk is not one.

    What is worth testing now is smaller and more consequential. A file is the
    only thing standing between two accounts that cannot otherwise see each
    other, so: that what one client writes is exactly what another reads, that
    a client never overwrites somebody else's file, that a character nobody
    announced is never read at all, and that the last change before you log out
    is not the one that gets lost.

    As before, the addon is loaded twice into separate globals, so "client A"
    and "client B" are genuinely two independent copies - which is the only way
    to test something whose whole job is to cross between two of them.
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

--[[ ONE folder for every client in the run, because that is precisely what
     makes two accounts able to see each other: they are one installation with
     one CustomData. ]]
local FILES = {}
local function resetFolder()
    for k in pairs(FILES) do FILES[k] = nil end
end

local NOW = 1000
local activate

local function newClient(charName, bags, bank)
    Stub.Reset()
    Stub.SetRoster({ player = charName, party = {} })

    GetRealmName = function() return "N'Zoth" end
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
    local client = { BZ = BZ, name = charName, bags = bags, bank = bank }
    BZ.data, BZ.config = {}, {}
    activate(client)
    return client
end

--[[ Swap EVERY global that distinguishes one client from another, the file
     API included. Stub.Reset() reinstalls globals when a second client is
     created, so anything not reinstalled here leaves the first client reading
     the second one's bags. ]]
function activate(client)
    BZ = client.BZ
    UnitName = function(unit) return unit == "player" and client.name or nil end

    WriteCustomFile = function(name, text, mode)
        if mode == "a" then FILES[name] = (FILES[name] or "") .. text
        else FILES[name] = text end
    end
    ReadCustomFile = function(name) return FILES[name] end

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

--- Log a character in: announce itself, scan, and read everyone else.
local function login(client)
    activate(client)
    client.BZ.JoinRoster()
    client.BZ.UpdateOwnData()
    client.BZ.ReadOthers()
end

local ALICE_BAGS = {
    [0] = { { id = 2589, count = 20 }, { id = 858, count = 5 } },
    [1] = { { id = 2589, count = 12 }, { id = 4306, count = 8 } },
}
local ALICE_BANK = {
    [-1] = { { id = 2589, count = 100 }, { id = 1234, count = 3 } },
}
local BOB_BAGS = {
    [0] = { { id = 2589, count = 7 }, { id = 5555, count = 1 } },
}

print("\nBagertz: two accounts, one folder\n")

----------------------------------------------------------------------
-- the format itself
----------------------------------------------------------------------
resetFolder()
local alice = newClient("Alice", ALICE_BAGS, ALICE_BANK)
activate(alice)
alice.BZ.atBank = true
alice.BZ.UpdateOwnData()

local text = alice.BZ.Serialize("Alice", alice.BZ.data["Alice"])
local name, parsed = alice.BZ.Deserialize(text)
check("a file names the character it describes", name, "Alice")
check("bag counts survive the round trip", parsed.bags[2589], 32)
check("a second item too", parsed.bags[4306], 8)
check("bank counts are kept apart from bags", parsed.bank[2589], 100)
check("the realm survives", parsed.realm, "N'Zoth")

--[[ A newer version writing a line this one has never seen must not take the
     whole file down with it. ]]
local junk = "BAGERTZ1\nM~Alice~N'Zoth~1000~0\nB~2589~5\nX~something new~1\ngarbage\n"
local jname, jparsed = alice.BZ.Deserialize(junk)
check("an unknown line is skipped, not fatal", jname, "Alice")
check("and the lines around it still parse", jparsed.bags[2589], 5)
check("an empty file is no character at all", alice.BZ.Deserialize(""), nil)

----------------------------------------------------------------------
-- crossing between two clients
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS, ALICE_BANK)
local bob = newClient("Bob", BOB_BAGS)

login(alice)
login(bob)

activate(bob)
check("Bob reads Alice out of the folder", bob.BZ.data["Alice"] ~= nil, true)
check("with her bag counts intact", bob.BZ.data["Alice"].bags[2589], 32)
check("and knows she is not his to rewrite", bob.BZ.data["Alice"].mine, false)
check("while his own character is his", bob.BZ.data["Bob"].mine, true)

--[[ The direction that matters as much: Alice was first, so she had nothing
     to read at login. She has to pick Bob up on the next pass. ]]
activate(alice)
check("Alice has not heard of Bob yet", alice.BZ.data["Bob"], nil)
alice.BZ.ReadOthers()
check("until she re-reads the folder", alice.BZ.data["Bob"].bags[2589], 7)

----------------------------------------------------------------------
-- staying out of each other's files
----------------------------------------------------------------------
activate(bob)
bob.BZ.WriteOwn()
local aliceFile = FILES["Bagertz_Alice.txt"]
check("Bob writing does not touch Alice's file",
    string.find(aliceFile, "Alice", 1, true) ~= nil, true)
check("Bob's file is his own", FILES["Bagertz_Bob.txt"] ~= nil, true)

--[[ Reading must not clobber what is live in memory. Our own file is at best
     as new as the last write, and the scan in memory is newer by definition. ]]
activate(alice)
alice.BZ.data["Alice"].bags[9999] = 42
alice.BZ.ReadOthers()
check("re-reading leaves our own live scan alone",
    alice.BZ.data["Alice"].bags[9999], 42)

----------------------------------------------------------------------
-- the roster is how a file is found at all
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
login(alice)

-- A file with nobody announcing it is a file nobody reads: Lua cannot list a
-- directory, so the roster is the only index there is.
FILES["Bagertz_Ghost.txt"] = "BAGERTZ1\nM~Ghost~N'Zoth~1000~0\nB~2589~999\n"
activate(bob)
bob.BZ.ReadOthers()
check("an unannounced file is never read", bob.BZ.data["Ghost"], nil)

--[[ Announcing yourself and having written a file are two different things,
     and the gap between them is a real moment: the roster line lands at
     login, the file a beat later. ]]
bob.BZ.JoinRoster()
activate(alice)
alice.BZ.ReadOthers()
check("a name with no file yet is skipped quietly", alice.BZ.data["Bob"], nil)

activate(bob)
bob.BZ.UpdateOwnData()
activate(alice)
alice.BZ.ReadOthers()
check("and read once the file is there", alice.BZ.data["Bob"] ~= nil, true)

activate(bob)
local before = FILES["Bagertz_roster.txt"]
bob.BZ.JoinRoster()
check("announcing twice does not grow the roster",
    FILES["Bagertz_roster.txt"], before)

local names = bob.BZ.RosterNames()
local seen = 0
for _, n in ipairs(names) do if n == "Bob" then seen = seen + 1 end end
check("and a name appears in it exactly once", seen, 1)

----------------------------------------------------------------------
-- not losing the last change
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
login(alice)
activate(alice)

-- A write held back by the rate limit must still happen, or the change you
-- made just before logging out is the one that never lands.
alice.BZ.lastWrite = NOW
alice.BZ.data["Alice"].bags[7777] = 3
alice.BZ.UpdateOwnData()
check("a rapid change is held rather than written", alice.BZ.writePending, true)

NOW = NOW + 60
alice.BZ.WriteOwn()
check("and is on disk once the wait is over",
    string.find(FILES["Bagertz_Alice.txt"], "B~2589", 1, true) ~= nil, true)

----------------------------------------------------------------------
-- without Nampower
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
activate(alice)
WriteCustomFile, ReadCustomFile = nil, nil
check("it knows the file API is missing", alice.BZ.FileAPI(), false)
check("reading returns nothing rather than erroring", alice.BZ.ReadOthers(), 0)
check("and says why", string.find(alice.BZ.fileState, "Nampower", 1, true) ~= nil, true)
alice.BZ.UpdateOwnData()   -- must not throw

----------------------------------------------------------------------
-- the bank is only readable at the bank
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS, ALICE_BANK)
activate(alice)
alice.BZ.atBank = true
alice.BZ.UpdateOwnData()
alice.BZ.atBank = false
alice.BZ.UpdateOwnData()
alice.BZ.WriteOwn()

bob = newClient("Bob", BOB_BAGS)
activate(alice) alice.BZ.JoinRoster()
activate(bob)
bob.BZ.ReadOthers()
check("a bank scanned at the bank survives walking away",
    bob.BZ.data["Alice"].bank[2589], 100)

----------------------------------------------------------------------
-- telling fresh data from what the old version left behind
----------------------------------------------------------------------

--[[ After the upgrade, SavedVariables still hold every character the addon
     -message version ever cached. A count from that cache looks exactly like
     one read a second ago, which makes "is this actually working?"
     unanswerable -- so the data says where it came from. ]]
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
login(alice)
login(bob)
activate(alice)
alice.BZ.ReadOthers()

check("a character read from the folder says so",
    alice.BZ.data["Bob"].fromFile ~= nil, true)

-- What an upgrade leaves behind: a name in the cache with no file at all.
alice.BZ.data["Ghost"] = { realm = "N'Zoth", time = NOW, bags = { [2589] = 50 } }
alice.BZ.ReadOthers()
check("a leftover cached character does not claim to be",
    alice.BZ.data["Ghost"].fromFile, nil)
check("and re-reading does not invent a source for it",
    alice.BZ.data["Ghost"].bags[2589], 50)

--[[ Clearing is the way out, and it has to actually remove the leftovers
     rather than merely hide them. ]]
SlashCmdList["BAGERTZ"]("clear")
check("clearing drops the leftover", alice.BZ.data["Ghost"], nil)
alice.BZ.ReadOthers()
check("and the real character comes straight back from the folder",
    alice.BZ.data["Bob"] and alice.BZ.data["Bob"].bags[2589], 7)
check("still marked as having come from it",
    alice.BZ.data["Bob"].fromFile ~= nil, true)

----------------------------------------------------------------------
-- dropping the leftovers without dropping the good data
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
login(alice)
login(bob)
activate(alice)
alice.BZ.ReadOthers()

-- What an upgrade leaves behind: a name the old sync cached, with no file.
alice.BZ.data["Salabeard"] = { realm = "N'Zoth", time = NOW, bags = { [2589] = 50 } }

SlashCmdList["BAGERTZ"]("stale")
check("the leftover is dropped", alice.BZ.data["Salabeard"], nil)
check("a character with a file is kept", alice.BZ.data["Bob"] ~= nil, true)
check("with its counts untouched",
    alice.BZ.data["Bob"] and alice.BZ.data["Bob"].bags[2589], 7)
check("and so is this character", alice.BZ.data["Alice"] ~= nil, true)

--[[ Clearing everything must not look like breaking it: what is on disk has
     to come straight back, and only the leftovers stay gone. ]]
alice.BZ.data["Salabeard"] = { realm = "N'Zoth", time = NOW, bags = { [2589] = 50 } }
SlashCmdList["BAGERTZ"]("clear")
check("clear brings the folder characters straight back",
    alice.BZ.data["Bob"] and alice.BZ.data["Bob"].bags[2589], 7)
check("and leaves the leftover gone", alice.BZ.data["Salabeard"], nil)
check("this character is rescanned, not lost", alice.BZ.data["Alice"] ~= nil, true)

SlashCmdList["BAGERTZ"]("stale")
check("running it again with nothing stale is harmless",
    alice.BZ.data["Bob"] ~= nil, true)

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
