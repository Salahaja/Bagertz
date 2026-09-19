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

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
