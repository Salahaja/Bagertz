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
--[[ How many times each file has been written and read. Needed because the
     thing under test is work NOT done: an addon that rewrites an identical
     file leaves a folder indistinguishable from one that skipped the write,
     and the whole point is the writing. ]]
local WRITES, READS = {}, {}
local function resetFolder()
    for k in pairs(FILES) do FILES[k] = nil end
    for k in pairs(WRITES) do WRITES[k] = nil end
    for k in pairs(READS) do READS[k] = nil end
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
    -- Per client, so two realms can share one installation's folder.
    GetRealmName = function() return client.realm or "N'Zoth" end

    WriteCustomFile = function(name, text, mode)
        WRITES[name] = (WRITES[name] or 0) + 1
        if mode == "a" then FILES[name] = (FILES[name] or "") .. text
        else FILES[name] = text end
    end
    ReadCustomFile = function(name)
        READS[name] = (READS[name] or 0) + 1
        return FILES[name]
    end

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
--[[ What PLAYER_ENTERING_WORLD does, in the same order.

     The forced write belongs to logging in, not to the write rate-limiter: a
     character whose bags are exactly as it left them still has to stamp its
     file, or it has no way to tell a client that forgot it that it is being
     played again. ]]
local function login(client)
    activate(client)
    client.BZ.JoinRoster()
    client.BZ.UpdateOwnData()
    client.BZ.WriteOwn(true)
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
local aliceFile = FILES["Bagertz_NZoth_Alice.txt"]
check("Bob writing does not touch Alice's file",
    string.find(aliceFile, "Alice", 1, true) ~= nil, true)
check("Bob's file is his own", FILES["Bagertz_NZoth_Bob.txt"] ~= nil, true)

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
    string.find(FILES["Bagertz_NZoth_Alice.txt"], "B~2589", 1, true) ~= nil, true)

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

----------------------------------------------------------------------
-- forgetting has to stick
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
login(bob)
login(alice)
activate(alice)
check("Bob is there to forget", alice.BZ.data["Bob"] ~= nil, true)

NOW = NOW + 10
SlashCmdList["BAGERTZ"]("forget bob")
check("forget drops him", alice.BZ.data["Bob"], nil)

--[[ His file is still in the folder, and Lua cannot delete it. Without the
     forget being remembered, the very next read put him straight back, which
     made the command a no-op with a success message. ]]
alice.BZ.ReadOthers()
check("the next read of the folder does not bring him back", alice.BZ.data["Bob"], nil)
SlashCmdList["BAGERTZ"]("read")
check("nor does asking for a re-read", alice.BZ.data["Bob"], nil)

-- Logging in again is what tells a live character from a deleted one.
NOW = NOW + 10
login(bob)
activate(alice)
alice.BZ.ReadOthers()
check("once he logs in again he is back",
    alice.BZ.data["Bob"] and alice.BZ.data["Bob"].bags[2589], 7)
check("and the forget is used up", alice.BZ.config.forgotten["Bob"], nil)

----------------------------------------------------------------------
-- the account label travels in the file
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
alice.BZ.config.account = "Main"
login(alice)
login(bob)

check("the label is written into the file",
    string.find(FILES["Bagertz_NZoth_Alice.txt"], "\nA~Main\n", 1, true) ~= nil, true)
check("an account without one writes none",
    string.find(FILES["Bagertz_NZoth_Bob.txt"], "\nA~", 1, true), nil)
activate(bob)
check("the other account reads it", bob.BZ.data["Alice"].account, "Main")
check("and shows it", bob.BZ.DisplayName("Alice"), "Main/Alice")

-- Taking the label off has to reach the other account too, not linger there.
activate(alice)
alice.BZ.config.account = nil
NOW = NOW + 10
alice.BZ.WriteOwn()
activate(bob)
bob.BZ.ReadOthers()
check("removing the label reaches the other account", bob.BZ.data["Alice"].account, nil)

----------------------------------------------------------------------
-- one folder, two realms
----------------------------------------------------------------------

--[[ The folder belongs to the installation, not the realm. Two characters
     called Bob on two realms used to write one file between them, and each
     login overwrote the other. ]]
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
local farBob = newClient("Bob", { [0] = { { id = 2589, count = 500 } } })
farBob.realm = "Kel'Thuzad"
local carol = newClient("Carol", { [0] = { { id = 2589, count = 40 } } })
carol.realm = "Kel'Thuzad"
login(bob)
login(farBob)
login(carol)
login(alice)

check("each Bob gets a file of his own",
    FILES["Bagertz_NZoth_Bob.txt"] ~= nil and FILES["Bagertz_KelThuzad_Bob.txt"] ~= nil, true)
check("and neither overwrote the other",
    string.find(FILES["Bagertz_NZoth_Bob.txt"], "B~2589~7", 1, true) ~= nil, true)
activate(alice)
check("this realm's Bob is the one read",
    alice.BZ.data["Bob"] and alice.BZ.data["Bob"].bags[2589], 7)
check("another realm's character is never read", alice.BZ.data["Carol"], nil)

activate(farBob)
farBob.BZ.ReadOthers()
check("the same holds from the other realm", farBob.BZ.data["Alice"], nil)
check("where its own neighbour is read",
    farBob.BZ.data["Carol"] and farBob.BZ.data["Carol"].bags[2589], 40)

----------------------------------------------------------------------
-- moving over from 2.0.0's file names
----------------------------------------------------------------------

--[[ 2.0.0 announced a bare name and wrote its file under it. Not every client
     updates at the same moment, so for a while those have to keep working,
     and then get out of the way. ]]
resetFolder()
FILES["Bagertz_roster.txt"] = "R~Bob\nR~Carol\n"
FILES["Bagertz_Bob.txt"] = "BAGERTZ1\nM~Bob~N'Zoth~" .. (NOW - 100) .. "~0\nB~2589~3\n"
FILES["Bagertz_Carol.txt"] = "BAGERTZ1\nM~Carol~Kel'Thuzad~" .. (NOW - 100) .. "~0\nB~2589~40\n"
alice = newClient("Alice", ALICE_BAGS)
login(alice)
activate(alice)
check("a file 2.0.0 wrote is still read",
    alice.BZ.data["Bob"] and alice.BZ.data["Bob"].bags[2589], 3)
check("but only if the realm inside it is this one", alice.BZ.data["Carol"], nil)

bob = newClient("Bob", BOB_BAGS)
login(bob)
check("the updated character writes the new file",
    FILES["Bagertz_NZoth_Bob.txt"] ~= nil, true)
check("and empties the old one, so nobody goes on reading it",
    FILES["Bagertz_Bob.txt"], "")
activate(alice)
alice.BZ.ReadOthers()
check("the new file is the one read", alice.BZ.data["Bob"].bags[2589], 7)

--[[ A client that loaded 2.0.0 before the update keeps writing the old name
     until it reloads, so for a while both can be current. Newest wins,
     whichever name it is under. ]]
FILES["Bagertz_Bob.txt"] = "BAGERTZ1\nM~Bob~N'Zoth~" .. (NOW + 50) .. "~0\nB~2589~99\n"
alice.BZ.ReadOthers()
check("a newer file under the old name wins", alice.BZ.data["Bob"].bags[2589], 99)
FILES["Bagertz_Bob.txt"] = "BAGERTZ1\nM~Bob~N'Zoth~" .. (NOW - 50) .. "~0\nB~2589~99\n"
alice.BZ.ReadOthers()
check("and an older one loses", alice.BZ.data["Bob"].bags[2589], 7)

----------------------------------------------------------------------
-- the account's other realms are kept, not shown
----------------------------------------------------------------------

--[[ SavedVariables are per account, not per realm, so the cache holds this
     account's characters from every realm it plays on. None of them is read
     from the folder here, which made them look exactly like leftovers from
     the old sync -- and a bank dropped from the cache stays gone until that
     character next stands at a bank. ]]
resetFolder()
alice = newClient("Alice", ALICE_BAGS)
bob = newClient("Bob", BOB_BAGS)
login(bob)
login(alice)
activate(alice)
alice.BZ.data["Zed"] = { realm = "Kel'Thuzad", time = NOW, mine = true,
                         bags = { [2589] = 5 }, bank = { [2589] = 70 } }

SlashCmdList["BAGERTZ"]("stale")
check("/bz stale leaves another realm's characters alone", alice.BZ.data["Zed"] ~= nil, true)
SlashCmdList["BAGERTZ"]("clear")
check("and so does /bz clear, bank and all",
    alice.BZ.data["Zed"] and alice.BZ.data["Zed"].bank[2589], 70)

local said = {}
local realSay = alice.BZ.Say
alice.BZ.Say = function(msg) table.insert(said, msg) end
SlashCmdList["BAGERTZ"]("")
alice.BZ.Say = realSay
local shown = table.concat(said, "\n")
check("/bz does not list them among this realm's", string.find(shown, "Zed", 1, true), nil)
check("nor call them leftovers", string.find(shown, "left over", 1, true), nil)
check("but says they are there",
    string.find(shown, "1 character(s) on other realms", 1, true) ~= nil, true)

local zedRelayed = false
for _, n in ipairs(alice.BZ.OwnedCharacters()) do
    if n == "Zed" then zedRelayed = true end
end
check("and a link partner never hears of them", zedRelayed, false)

----------------------------------------------------------------------
-- clearing is not a trip to the bank
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS, ALICE_BANK)
activate(alice)
alice.BZ.atBank = true
login(alice)
alice.BZ.atBank = false
NOW = NOW + 10
SlashCmdList["BAGERTZ"]("clear")
local aliceBank = alice.BZ.data["Alice"] and alice.BZ.data["Alice"].bank
check("/bz clear keeps this character's bank", aliceBank and aliceBank[2589], 100)
check("and does not write it out of the file",
    string.find(FILES["Bagertz_NZoth_Alice.txt"], "K~2589~100", 1, true) ~= nil, true)

--[[ Keyed by name, the cache can hold a same-named character from another
     realm. Its bank is not this one's. ]]
resetFolder()
bob = newClient("Bob", BOB_BAGS)
activate(bob)
bob.BZ.data["Bob"] = { realm = "Kel'Thuzad", time = NOW, mine = true,
                       bags = { [2589] = 500 }, bank = { [2589] = 900 } }
login(bob)
check("a same-named character on another realm does not lend its bank",
    bob.BZ.data["Bob"].bank and bob.BZ.data["Bob"].bank[2589], nil)
check("nor does it reach this Bob's file",
    string.find(FILES["Bagertz_NZoth_Bob.txt"], "\nK~", 1, true), nil)

-- Nor is the file 2.0.0 wrote forgotten as a place a bank can come back from.
resetFolder()
FILES["Bagertz_Zed.txt"] = "BAGERTZ1\nM~Zed~N'Zoth~900~900\nK~2589~60\n"
local zed = newClient("Zed", BOB_BAGS)
login(zed)
check("a bank comes back from the file 2.0.0 wrote",
    zed.BZ.data["Zed"].bank and zed.BZ.data["Zed"].bank[2589], 60)
check("and moves into the new file with it",
    string.find(FILES["Bagertz_NZoth_Zed.txt"], "K~2589~60", 1, true) ~= nil, true)

-- Under the old naming, the file could as easily be another realm's Bob.
resetFolder()
FILES["Bagertz_Bob.txt"] = "BAGERTZ1\nM~Bob~Kel'Thuzad~900~0\nB~2589~500\n"
bob = newClient("Bob", BOB_BAGS)
login(bob)
check("an old file that is another realm's Bob is left alone",
    string.find(FILES["Bagertz_Bob.txt"], "Kel'Thuzad", 1, true) ~= nil, true)


----------------------------------------------------------------------
-- only changes
--
-- The events that bring Bagertz back to the bags have no idea whether
-- anything moved. BAG_UPDATE fires several times for one loot; PLAYER_MONEY
-- fires when a vendor pays you the copper you just spent; opening the bank
-- rescans everything. Each of those used to be a full write that every other
-- character on the machine then read and parsed in full.
--
-- What is checked below is therefore work that does NOT happen, which is why
-- the harness counts writes and parses rather than looking at the contents.
----------------------------------------------------------------------
resetFolder()
alice = newClient("Alice", ALICE_BAGS, ALICE_BANK)
login(alice)
activate(alice)

local ALICE_FILE = "Bagertz_NZoth_Alice.txt"
local writesAfterLogin = WRITES[ALICE_FILE]
check("logging in writes the file", writesAfterLogin ~= nil and writesAfterLogin > 0, true)

-- A rescan of bags nobody touched.
NOW = NOW + 10
alice.BZ.UpdateOwnData()
check("a rescan that found nothing new does not rewrite the file",
    WRITES[ALICE_FILE], writesAfterLogin)

-- Five of them, as a burst of BAG_UPDATEs looks from here.
for _ = 1, 5 do
    NOW = NOW + 10
    alice.BZ.UpdateOwnData()
end
check("nor do five of them", WRITES[ALICE_FILE], writesAfterLogin)

--[[ The same contents reached a different way. ScanBags rebuilds the table
     every time, so an item that moved bags can come back in a different
     iteration order -- which a naive comparison reads as a change. ]]
NOW = NOW + 10
alice.bags = {
    [0] = { { id = 4306, count = 8 }, { id = 2589, count = 12 } },
    [1] = { { id = 858, count = 5 }, { id = 2589, count = 20 } },
}
alice.BZ.UpdateOwnData()
check("rearranging bags without changing what is in them does not write",
    WRITES[ALICE_FILE], writesAfterLogin)

--[[ Both halves of this rest on one property: identical contents must produce
     identical bytes, or the writer sees a change where there is none and the
     reader re-parses a file that did not move.

     Asserted directly, not through the check above. That one passes either
     way under Lua 5.4, whose table order happened not to shift for these
     keys; Lua 5.0 on the client promises nothing of the sort, so the order
     being deliberate is the thing worth pinning. ]]
check("packed counts come out in id order",
    alice.BZ.PackCounts({ [4306] = 1, [858] = 2, [2589] = 3 }),
    "858:2,2589:3,4306:1")
local serialized = alice.BZ.Serialize("Alice", {
    realm = "N'Zoth", time = 1, bags = { [4306] = 1, [858] = 2 }, bank = {},
})
check("and so do the item lines in the file",
    string.find(serialized, "B~858~2\nB~4306~1", 1, true) ~= nil, true)

-- And a real change still gets through, which is the half that matters.
NOW = NOW + 10
alice.bags[0][1].count = 9
alice.BZ.UpdateOwnData()
check("but looting one more of something does write",
    WRITES[ALICE_FILE] > writesAfterLogin, true)
check("and the new count is in the file",
    string.find(FILES[ALICE_FILE], "B~4306~9", 1, true) ~= nil, true)

-- Gold travels in the same file and arrives by the same blunt event.
local writesBeforeGold = WRITES[ALICE_FILE]
NOW = NOW + 10
alice.BZ.UpdateOwnData()
check("being paid nothing does not write", WRITES[ALICE_FILE], writesBeforeGold)
GetMoney = function() return 12345 end
NOW = NOW + 10
alice.BZ.UpdateOwnData()
check("being paid something does", WRITES[ALICE_FILE] > writesBeforeGold, true)

-- Changing the account label is a change like any other.
local writesBeforeLabel = WRITES[ALICE_FILE]
alice.BZ.config.account = "Main"
alice.BZ.WriteOwn()
check("labelling the account writes", WRITES[ALICE_FILE] > writesBeforeLabel, true)

----------------------------------------------------------------------
-- and the same from the reading end
----------------------------------------------------------------------
bob = newClient("Bob", BOB_BAGS)
login(bob)
activate(bob)
-- 32, not 20: Alice carries 2589 in two bags, and a count is per character.
check("Bob read Alice out of the folder",
    bob.BZ.data["Alice"] and bob.BZ.data["Alice"].bags[2589], 32)

--[[ Parsing is what costs here, not reading: this runs every twenty seconds
     for every character you have ever logged in, and almost every time the
     answer is that nobody has touched a bag. Counted by swapping in a
     Deserialize that tallies the calls, because the result of skipping it is
     by design identical to the result of doing it. ]]
local realDeserialize = bob.BZ.Deserialize
local parses = 0
bob.BZ.Deserialize = function(text)
    parses = parses + 1
    return realDeserialize(text)
end

NOW = NOW + 10
local found = bob.BZ.ReadOthers()
check("an unchanged file is not parsed again", parses, 0)
check("and the character is still reported as present", found, 1)
check("and is still there to be asked about",
    bob.BZ.data["Alice"] and bob.BZ.data["Alice"].bags[2589], 32)

--[[ The failure that would matter: a change arriving after a skip. Get this
     wrong and tooltips silently freeze at whatever they said first, which
     looks exactly like the addon working. ]]
activate(alice)
NOW = NOW + 10
alice.bags[1][2].count = 31
alice.BZ.UpdateOwnData()
activate(bob)
NOW = NOW + 10
bob.BZ.ReadOthers()
check("a file that did change is parsed", parses > 0, true)
check("and the new count arrives", bob.BZ.data["Alice"].bags[2589], 43)

-- Emptying the cache of characters has to beat the cache of file contents,
-- or /bz clear reports cheerfully that it found nobody.
parses = 0
SlashCmdList["BAGERTZ"]("clear")
check("clearing the cache really re-reads the folder", parses > 0, true)
check("and Alice comes straight back",
    bob.BZ.data["Alice"] and bob.BZ.data["Alice"].bags[2589], 43)
bob.BZ.Deserialize = realDeserialize
GetMoney = function() return 0 end

----------------------------------------------------------------------
-- the version the addon reports is the version it ships as
----------------------------------------------------------------------
--[[ Not a detail. A hardcoded copy of the version only has to be forgotten
     once, and from then on the addon reports a release the player is not
     running -- which is how a sibling addon came to be debugged for a whole
     session against entirely the wrong code. ]]
local toc = io.open("Bagertz.toc", "r"):read("*a")
local _, _, tocVersion = string.find(toc, "##%s*Version:%s*([^\r\n]+)")
check("the .toc has a version", tocVersion ~= nil, true)
check("and the addon reports that one", alice.BZ.VERSION, tocVersion)

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
