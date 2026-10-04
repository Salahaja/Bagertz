--[[
    test_pairing.lua - linking two players who are NOT on the same machine.

    Usage (from the repo root):
        lua tools/test_pairing.lua [path/to/Bagertz.lua]

    The shared folder covers your own accounts and needs no secret at all. This
    covers the other case: a partner on their own PC, where the only road
    between you is the game.

    Three things here are worth more than the rest, because each one fails
    quietly rather than loudly:

      - an offer must not link anything until the far end accepts, or anyone
        who whispers you can start receiving your bags;
      - unlinking has to reach both ends, or one client goes on sending to
        someone who is no longer listening;
      - a character learned FROM a partner must never be relayed onward, or
        two people linked to the same third party bounce it between them.
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

--[[ Two PCs, so two folders. This is the whole reason the link exists: give
     them one folder and none of this would be needed. ]]
local FOLDERS = {}
local NOW = 1000
local activate

local function newClient(charName, bags, folderId)
    Stub.Reset()
    Stub.SetRoster({ player = charName, party = { "Someone" } })

    GetRealmName = function() return "N'Zoth" end
    GetNumPartyMembers = function() return 1 end
    GetNumRaidMembers = function() return 0 end
    IsInGuild = function() return nil end
    time = function() return NOW end
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    ItemRefTooltip = Stub.CreateFrame("Frame", "ItemRefTooltip")
    GetLootSlotLink = function() return nil end
    GetInventoryItemLink = function() return nil end

    FOLDERS[folderId] = FOLDERS[folderId] or {}

    BZ = nil
    dofile(ADDON_PATH)
    local client = { BZ = BZ, name = charName, bags = bags, folder = folderId,
                     addon = {}, whispers = {} }
    BZ.data, BZ.config = {}, {}
    activate(client)
    return client
end

function activate(client)
    BZ = client.BZ
    UnitName = function(unit) return unit == "player" and client.name or nil end

    local files = FOLDERS[client.folder]
    WriteCustomFile = function(name, text, mode)
        if mode == "a" then files[name] = (files[name] or "") .. text
        else files[name] = text end
    end
    ReadCustomFile = function(name) return files[name] end

    SendAddonMessage = function(prefix, msg, channel)
        table.insert(client.addon, { prefix = prefix, msg = msg, channel = channel })
    end
    SendChatMessage = function(text, kind, _, target)
        table.insert(client.whispers, { text = text, kind = kind, target = target })
    end

    local function container(bag)
        if bag <= -1 or bag >= 5 then return nil end
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

--- Hand every whisper `from` has queued to `to`, as the server would.
local function deliverWhispers(from, to)
    local out = from.whispers
    from.whispers = {}
    for _, w in ipairs(out) do
        if w.target == to.name then
            activate(to)
            to.BZ.OnWhisper(w.text, from.name)
        end
    end
    return table.getn(out)
end

--- Hand every addon message `from` has queued to `to`.
local function deliverAddon(from, to)
    activate(from)
    while table.getn(from.BZ.sendQueue) > 0 do from.BZ.DrainQueue() end
    local out = from.addon
    from.addon = {}
    for _, m in ipairs(out) do
        activate(to)
        to.BZ.OnAddonMessage(m.msg, from.name)
    end
    return table.getn(out)
end

local ALICE_BAGS = { [0] = { { id = 2589, count = 20 } } }
local PAT_BAGS   = { [0] = { { id = 4306, count = 9 } } }

print("\nBagertz: linking two PCs\n")

----------------------------------------------------------------------
-- an offer changes nothing until it is accepted
----------------------------------------------------------------------
local alice = newClient("Alice", ALICE_BAGS, "pc1")
local pat = newClient("Pat", PAT_BAGS, "pc2")

activate(alice)
alice.BZ.UpdateOwnData()
alice.BZ.Share("Pat")
check("the offer goes out as a whisper, to one person",
    alice.whispers[1] and alice.whispers[1].kind, "WHISPER")
check("addressed to them", alice.whispers[1] and alice.whispers[1].target, "Pat")
check("nothing is broadcast to the party", table.getn(alice.addon), 0)
check("and the sender is not linked yet", alice.BZ.config.password, nil)

deliverWhispers(alice, pat)
activate(pat)
--[[ The one that matters. An addon that linked on arrival would let anyone
     who whispers you start receiving your bags. ]]
check("the receiver is NOT linked by the offer alone", pat.BZ.config.password, nil)
check("it is holding the offer to ask about", pat.BZ.pendingOffer ~= nil, true)
check("and knows who it is from", pat.BZ.pendingOffer.name, "Alice")

----------------------------------------------------------------------
-- accepting
----------------------------------------------------------------------
activate(pat)
pat.BZ.AcceptPair()
check("accepting takes the password", pat.BZ.config.password ~= nil, true)
check("and records the partner", pat.BZ.config.partner.name, "Alice")
check("the offer is no longer pending", pat.BZ.pendingOffer, nil)

deliverWhispers(pat, alice)
activate(alice)
check("the asker is linked once accepted", alice.BZ.config.partner.name, "Pat")
check("both ends hold the same secret",
    alice.BZ.config.password, pat.BZ.config.password)
check("which was generated, not typed",
    string.len(alice.BZ.config.password) >= 10, true)

--[[ Two runs must not produce the same secret, or "randomly generated" is a
     description rather than a fact. ]]
local first = alice.BZ.NewPassword()
local second = alice.BZ.NewPassword()
check("a fresh password differs from the last", first ~= second, true)

----------------------------------------------------------------------
-- and now the inventories actually cross
----------------------------------------------------------------------
activate(alice) alice.BZ.UpdateOwnData()
activate(pat) pat.BZ.UpdateOwnData()

activate(alice) alice.BZ.SendBeacon()
deliverAddon(alice, pat)
activate(pat) pat.BZ.SendBeacon()
deliverAddon(pat, alice)

activate(pat) pat.BZ.SendInventory("all")
deliverAddon(pat, alice)
activate(alice)
check("Alice ends up knowing Pat's bags",
    alice.BZ.data["Pat"] and alice.BZ.data["Pat"].bags[4306], 9)
check("marked as having come from the link",
    alice.BZ.data["Pat"] and alice.BZ.data["Pat"].fromChannel ~= nil, true)
check("and not as a file she read", alice.BZ.data["Pat"].fromFile, nil)

--[[ Never relayed onward: two people linked to the same third party would
     otherwise bounce it between them, and the staleness of the copies would
     have to be arbitrated. ]]
local relayed = alice.BZ.OwnedCharacters()
local found = false
for _, n in ipairs(relayed) do if n == "Pat" then found = true end end
check("a partner's character is never relayed on", found, false)

----------------------------------------------------------------------
-- unlinking reaches both ends
----------------------------------------------------------------------
activate(alice)
alice.BZ.Unlink()
check("the asker is unlinked", alice.BZ.config.partner, nil)
check("their password is gone", alice.BZ.config.password, nil)
check("and their characters with it", alice.BZ.data["Pat"], nil)
check("but this character is untouched", alice.BZ.data["Alice"] ~= nil, true)

deliverWhispers(alice, pat)
activate(pat)
check("the other end hears about it", pat.BZ.config.partner, nil)
check("and stops sharing too", pat.BZ.config.password, nil)

----------------------------------------------------------------------
-- declining, and offers nobody made
----------------------------------------------------------------------
alice = newClient("Alice", ALICE_BAGS, "pc1")
pat = newClient("Pat", PAT_BAGS, "pc2")
activate(alice) alice.BZ.Share("Pat")
deliverWhispers(alice, pat)
activate(pat) pat.BZ.DeclinePair()
check("declining links nothing", pat.BZ.config.password, nil)
deliverWhispers(pat, alice)
activate(alice)
check("and the asker stops waiting", alice.BZ.pendingPair, nil)
check("with nothing linked", alice.BZ.config.partner, nil)

-- An acceptance for an offer we never sent is somebody else's business.
activate(alice)
-- pcall so a crash reads as a failure rather than ending the run silently.
local ok = pcall(alice.BZ.OnWhisper, "BZPAIR2~SomeAccount", "Stranger")
check("an unasked-for acceptance does not blow up", ok, true)
check("an unasked-for acceptance is ignored", alice.BZ.config.partner, nil)

----------------------------------------------------------------------
-- tags from the top half of the hash range
----------------------------------------------------------------------

--[[ The client prints %d through a 32-bit int, so every hash from 2^31 up
     came out as -2147483648 and the receiver dropped it: half of all beacons
     and transfers, silently. The nonce is random, so an ordinary run only
     sometimes lands in that half. This one always does, and the stub prints
     %d the way the client does. ]]
alice = newClient("Alice", ALICE_BAGS, "pc1")
pat = newClient("Pat", PAT_BAGS, "pc2")
activate(alice) alice.BZ.Share("Pat")
deliverWhispers(alice, pat)
activate(pat) pat.BZ.AcceptPair()
deliverWhispers(pat, alice)
activate(alice) alice.BZ.UpdateOwnData()
activate(pat) pat.BZ.UpdateOwnData()

local bigNonce
activate(alice)
for n = 100000, 999999 do
    if alice.BZ.Hash(alice.BZ.config.password .. ":" .. n) >= 2147483648 then
        bigNonce = n
        break
    end
end
check("there is a nonce whose tag needs all 32 bits", bigNonce ~= nil, true)

local realRandom = math.random
math.random = function() return bigNonce end

activate(alice) alice.BZ.SendBeacon()
while table.getn(alice.BZ.sendQueue) > 0 do alice.BZ.DrainQueue() end
local beacon = alice.addon[1] and alice.addon[1].msg or ""
local _, _, wireTag = string.find(beacon, "^B~%d+~([^~]+)~")
check("the tag goes out as a plain number",
    string.find(wireTag or "", "^%d+$") ~= nil, true)
check("with every digit of it", tonumber(wireTag or "0") >= 2147483648, true)

deliverAddon(alice, pat)       -- Pat meets Alice and answers with his roster
deliverAddon(pat, alice)
activate(pat) pat.BZ.SendBeacon()
deliverAddon(pat, alice)       -- Alice meets Pat and answers with hers
deliverAddon(alice, pat)
math.random = realRandom

activate(pat)
check("the beacon is accepted", pat.BZ.peers["Alice"] ~= nil, true)
check("Alice's bags cross", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[2589], 20)
check("with nothing refused on the way", pat.BZ.stats.rejected, 0)
activate(alice)
check("and Pat's cross the other way",
    alice.BZ.data["Pat"] and alice.BZ.data["Pat"].bags[4306], 9)
check("refused nowhere", alice.BZ.stats.rejected, 0)

--[[ A linked partner's characters have no file in this folder and never will:
     they are current, not leftovers from the old sync. ]]
SlashCmdList["BAGERTZ"]("stale")
check("/bz stale keeps a linked partner's characters", alice.BZ.data["Pat"] ~= nil, true)

----------------------------------------------------------------------
-- unlinked means silent
----------------------------------------------------------------------
alice = newClient("Alice", ALICE_BAGS, "pc1")
activate(alice)
alice.BZ.UpdateOwnData()
alice.BZ.SendBeacon()
alice.BZ.SendInventory("all")
while table.getn(alice.BZ.sendQueue) > 0 do alice.BZ.DrainQueue() end
check("an unlinked client broadcasts nothing at all", table.getn(alice.addon), 0)

-- ...and ignores anything that arrives.
alice.BZ.OnAddonMessage("B~123456~999999~Someone", "Someone")
check("and pairs with nobody who talks to it", alice.BZ.config.partner, nil)


----------------------------------------------------------------------
-- only what changed
--
-- A bag change used to go out as the character's entire inventory, chunked
-- into as many messages as that took, every few seconds for as long as you
-- kept rearranging things. Most of what follows is about messages NOT sent.
--
-- The rest is about what makes sending fewer of them safe. A difference only
-- means anything applied to the state it was measured against, so a transfer
-- that goes missing cannot just be shrugged off: every count after it would
-- be adjusted from the wrong starting point, and would look entirely
-- reasonable while being wrong. That is the failure worth testing here.
----------------------------------------------------------------------

--- Pair two clients and let the opening exchange of rosters finish.
local function link(a, b)
    activate(a) a.BZ.Share(b.name)
    deliverWhispers(a, b)
    activate(b) b.BZ.AcceptPair()
    deliverWhispers(b, a)
    activate(a) a.BZ.UpdateOwnData()
    activate(b) b.BZ.UpdateOwnData()
    activate(a) a.BZ.SendBeacon()
    activate(b) b.BZ.SendBeacon()
    -- Meeting for the first time, each answers with everything it has; and
    -- the answers are themselves first sightings. Run it until it goes quiet.
    for _ = 1, 8 do
        if (deliverAddon(a, b) + deliverAddon(b, a)) == 0 then break end
    end
end

--- Send whatever is queued, and throw it away: a transfer that went missing.
local function dropAddon(from)
    activate(from)
    while table.getn(from.BZ.sendQueue) > 0 do from.BZ.DrainQueue() end
    from.addon = {}
end

local function messages(client)
    activate(client)
    while table.getn(client.BZ.sendQueue) > 0 do client.BZ.DrainQueue() end
    return table.getn(client.addon)
end

-- Enough items that a full inventory needs several messages and a difference
-- plainly does not.
local MANY = { [0] = {} }
for i = 1, 80 do table.insert(MANY[0], { id = 1000 + i, count = i }) end

alice = newClient("Alice", MANY, "pc1")
pat = newClient("Pat", PAT_BAGS, "pc2")
link(alice, pat)

activate(pat)
check("Pat starts out holding all eighty of Alice's items",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1007], 7)

--[[ What a full send costs, for comparison. Delivered rather than thrown
     away: discarding it would be a lost transfer, and the receiver refuses to
     paper over one of those -- which is the next thing being tested. ]]
activate(alice)
alice.addon = {}
alice.BZ.SendInventory("all")
local fullCost = messages(alice)
check("a full send takes a stack of messages", fullCost >= 5, true)
deliverAddon(alice, pat)

-- And what one looted item costs.
activate(alice)
alice.bags[0][7].count = 99
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
local deltaCost = messages(alice)
check("one item changing takes two: a header and a chunk", deltaCost, 2)
check("which is less than sending everything", deltaCost < fullCost, true)

deliverAddon(alice, pat)
activate(pat)
check("the new count arrives", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1007], 99)
check("and the seventy-nine that did not move are still there",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1012], 12)

-- Nothing moved, so there is nothing to say.
activate(alice)
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
check("a scan that found nothing new sends no message at all", messages(alice), 0)

-- An item spent, rather than gained. Absence has to be said out loud: a
-- difference that simply omitted it would leave the far end holding it
-- forever.
activate(alice)
table.remove(alice.bags[0], 7)
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
check("an item used up is still only two messages", messages(alice), 2)
deliverAddon(alice, pat)
activate(pat)
check("and the far end lets go of it", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1007], nil)
check("without losing its neighbours", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1012], 12)

----------------------------------------------------------------------
-- a transfer that never arrived
----------------------------------------------------------------------
activate(alice)
alice.bags[0][1].count = 500
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
dropAddon(alice)                      -- lost on the way

activate(alice)
alice.bags[0][2].count = 600
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
deliverAddon(alice, pat)

activate(pat)
--[[ The one that matters. Applying this would leave Pat showing 2 of item
     1001 and 600 of 1002 -- a number nobody ever held, with nothing about it
     to suggest anything had gone wrong. ]]
check("a difference following a lost one is not applied",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1002], 2)
check("and the gap is noticed", table.getn(pat.BZ.sendQueue) > 0, true)
local asked = messages(pat)
check("by asking for the lot", asked > 0, true)
check("which is one short message",
    pat.addon[1] ~= nil and string.find(pat.addon[1].msg, "^R~") ~= nil, true)

deliverAddon(pat, alice)               -- Alice hears the request
activate(alice)
check("the asker is answered", table.getn(alice.BZ.sendQueue) > 0, true)
deliverAddon(alice, pat)
activate(pat)
check("and the answer puts both counts right", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1001], 500)
check("all of them", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1002], 600)
check("including the one that was used up earlier",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1007], nil)

-- Differences flow again afterwards, rather than the link being stuck asking.
activate(alice)
alice.bags[0][3].count = 7
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
check("and ordinary differences work again after a resync", messages(alice), 2)
deliverAddon(alice, pat)
activate(pat)
check("arriving as they should", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1003], 7)

----------------------------------------------------------------------
-- the same transfer twice
----------------------------------------------------------------------
--[[ Which happens whenever the other box can be reached on two channels at
     once. Sending the same difference to both is the sender being thorough;
     asking for a resync over it would be the receiver being silly. ]]
activate(alice)
alice.bags[0][4].count = 44
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
activate(alice)
while table.getn(alice.BZ.sendQueue) > 0 do alice.BZ.DrainQueue() end
local twice = {}
for _, m in ipairs(alice.addon) do
    table.insert(twice, m)
    table.insert(twice, m)
end
alice.addon = {}
activate(pat)
pat.addon = {}
for _, m in ipairs(twice) do pat.BZ.OnAddonMessage(m.msg, "Alice") end
check("a difference that arrives twice still gives the right count",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1004], 44)
check("and asks for nothing", messages(pat), 0)

--[[ That pair of checks passes either way, because a difference of absolute
     counts applied twice lands in the same place. The case that does not is
     an OLDER difference turning up late, which is what two channels of
     different speeds will eventually produce: applying it puts back a count
     that has already been superseded, and the far end goes on showing it
     until something else about that item happens to change. ]]
activate(alice)
alice.bags[0][6].count = 11
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
activate(alice)
while table.getn(alice.BZ.sendQueue) > 0 do alice.BZ.DrainQueue() end
local earlier = alice.addon
alice.addon = {}
activate(pat)
for _, m in ipairs(earlier) do pat.BZ.OnAddonMessage(m.msg, "Alice") end
check("the earlier difference lands", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1006], 11)

activate(alice)
alice.bags[0][6].count = 22
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
deliverAddon(alice, pat)
activate(pat)
check("and the one after it", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1006], 22)

-- The slow copy of the earlier one, arriving after the later one.
for _, m in ipairs(earlier) do pat.BZ.OnAddonMessage(m.msg, "Alice") end
check("an older difference arriving late does not put the old count back",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1006], 22)

----------------------------------------------------------------------
-- differences about a stranger
----------------------------------------------------------------------
--[[ There is nothing to apply them to, and a character conjured out of
     whichever few items happened to move would be wrong in exactly the way
     that looks right. ]]
activate(pat)
pat.addon = {}
pat.BZ.data["Alice"] = nil
activate(alice)
alice.bags[0][5].count = 55
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
deliverAddon(alice, pat)
activate(pat)
check("a stranger is not invented out of a difference", pat.BZ.data["Alice"], nil)
check("the lot is asked for instead", messages(pat) > 0, true)

----------------------------------------------------------------------
-- your alts, after the first meeting
----------------------------------------------------------------------
--[[ An alt on your other account is read out of the shared folder by this
     client and passed on from here, because it is not online to speak for
     itself. Up to 2.1 that happened only when the two boxes first met: an alt
     that played afterwards was picked up out of the folder and never
     mentioned onward, so a partner's view of it stayed frozen for as long as
     the session lasted.

     Costs nothing to fix now. A character nothing has happened to produces no
     block at all. ]]
activate(alice)
alice.BZ.data["Sibling"] = {
    realm = "N'Zoth", time = NOW, fromFile = NOW,
    bags = { [7777] = 3 },
}
NOW = NOW + 10
alice.BZ.SendInventory()
check("an alt they have not been told about sends everything, not a difference",
    messages(alice) > 0, true)
deliverAddon(alice, pat)
activate(pat)
check("so the alt arrives whole", pat.BZ.data["Sibling"] and
    pat.BZ.data["Sibling"] and pat.BZ.data["Sibling"].bags[7777], 3)

--[[ The promotion has to be once, not every time: an alt that stays on the
     books would otherwise make every send a full one again. ]]
activate(alice)
alice.BZ.data["Sibling"].bags[7777] = 9
NOW = NOW + 10
alice.BZ.SendInventory()
check("and a later change to it is only a difference", messages(alice), 2)
deliverAddon(alice, pat)
activate(pat)
check("which still arrives", pat.BZ.data["Sibling"] and pat.BZ.data["Sibling"].bags[7777], 9)

-- Nothing happened to it, so nothing is said about it.
activate(alice)
NOW = NOW + 10
alice.BZ.SendInventory()
check("an alt that did not move is not mentioned", messages(alice), 0)
alice.BZ.data["Sibling"] = nil
alice.BZ.lastSent["Sibling"] = nil

----------------------------------------------------------------------
-- one of you relogs
----------------------------------------------------------------------
--[[ The transfer numbers live in memory, so logging out restarts yours at
     zero while your partner goes on remembering where you had got to. Sent a
     difference numbered 1 against a partner expecting 48, they would take it
     for one they already had and quietly ignore it -- and every one after it.

     What saves it is that a full transfer carries no such argument: it
     replaces rather than adjusts, so it is accepted whatever its number and
     resets the count. And the first thing either box sends after a relog is a
     full one, because neither has heard of the other yet. That is a chain of
     three facts, which is two more than ought to be left to reasoning. ]]
local beforeRelog = pat.BZ.peerSerial["Alice"]
check("Pat has been counting Alice's transfers", (beforeRelog or 0) > 1, true)

activate(alice)
-- What logging out actually clears: session memory, not saved settings.
alice.BZ.sendSerial = 0
alice.BZ.lastSent = {}
alice.BZ.peers = {}
alice.addon = {}
-- Slot 20, not 8: an item was removed from this bag earlier and everything
-- after it shifted down one, so slot 8 is no longer item 1008.
alice.bags[0][20].count = 88
NOW = NOW + 10
alice.BZ.UpdateOwnData()

-- Nothing goes out before the other box has been heard from.
alice.BZ.SendInventory()
check("a freshly logged-in client says nothing unprompted", messages(alice), 0)

activate(pat) pat.BZ.SendBeacon()
for _ = 1, 8 do
    if (deliverAddon(pat, alice) + deliverAddon(alice, pat)) == 0 then break end
end

activate(pat)
check("Alice is heard again after relogging", pat.BZ.peers["Alice"] ~= nil, true)
check("and the change she made while away arrives",
    pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1021], 88)
check("with the transfer count started over rather than stuck",
    pat.BZ.peerSerial["Alice"] < beforeRelog, true)

-- And differences flow again from there.
activate(alice)
alice.bags[0][21].count = 99
NOW = NOW + 10
alice.BZ.UpdateOwnData()
alice.BZ.SendInventory()
check("differences resume after a relog", messages(alice), 2)
deliverAddon(alice, pat)
activate(pat)
check("and land", pat.BZ.data["Alice"] and pat.BZ.data["Alice"].bags[1022], 99)

----------------------------------------------------------------------
-- the beacon stops shouting at a whole guild
----------------------------------------------------------------------
activate(alice)
IsInGuild = function() return 1 end
alice.BZ.peers = {}
check("with nobody found yet, the beacon tries everywhere",
    table.concat(alice.BZ.BeaconChannels(), "+"), "PARTY+GUILD")
alice.BZ.peers["Pat"] = { time = NOW, channel = "PARTY" }
check("once the other box answers in the party, that is where it goes",
    table.concat(alice.BZ.BeaconChannels(), "+"), "PARTY")

--[[ A party is remembered for a minute after it breaks up. Beaconing into one
     that has gone would reach nobody, so a channel we are no longer on does
     not count as having found anybody. ]]
GetNumPartyMembers = function() return 0 end
check("a party that has since broken up does not pin it there",
    table.concat(alice.BZ.BeaconChannels(), "+"), "GUILD")
GetNumPartyMembers = function() return 1 end
IsInGuild = function() return nil end

----------------------------------------------------------------------
-- a password with nobody on the other end
----------------------------------------------------------------------
--[[ The pre-2.0 sync was switched on by typing a password, so an upgraded
     client can be holding one with no partner record beside it.

     The password is what actually enables the channel: every send path checks
     it and nothing checks the partner record. So a client in that state goes
     on broadcasting, while the earlier Unlink returned before clearing it and
     said "not linked to anyone" -- leaving no way to stop it from the UI at
     all. ]]
alice = newClient("Alice", ALICE_BAGS, "pc1")
activate(alice)
alice.BZ.config.password = "leftover"
alice.BZ.config.partner = nil
alice.BZ.data["Ghost"] = { realm = "N'Zoth", time = NOW, fromChannel = NOW,
                           bags = { [1] = 1 } }

alice.whispers = {}
alice.BZ.Unlink()
check("a leftover password is cleared", alice.BZ.config.password, nil)
check("and what the channel brought in goes with it", alice.BZ.data["Ghost"], nil)
--[[ Nobody to tell. Whispering a name we never recorded would be a message to
     whoever happens to be holding it. ]]
check("nobody is whispered about it", table.getn(alice.whispers), 0)

-- With neither, it says so rather than pretending to have acted.
alice.BZ.Unlink()
check("unlinking again is harmless", alice.BZ.config.password, nil)

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
