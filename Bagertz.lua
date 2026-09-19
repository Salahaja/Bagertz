--[[
    Addon:       Bagertz
    Description: Shows how many of an item your OTHER characters are carrying,
                 in the item's tooltip - including characters on a different
                 WoW ACCOUNT, which is the part nothing else can do.

    How it crosses the account boundary:

    SavedVariables cannot. The client writes them per account, under
    WTF/Account/<ACCOUNT>/, and only the logged-in account's file is ever
    loaded. The account name is in the path, which is exactly why one account
    can never see another's. The Lua sandbox has no filesystem access either -
    no io, no loadfile - and the TOC loader refuses to escape Interface\
    (tested: it follows ..\SomeOtherAddon\ happily and refuses ..\..\).

    CustomData/ has no account in its path. It is one folder per INSTALLATION,
    and Nampower hands Lua WriteCustomFile/ReadCustomFile to read and write in
    it. Two clients launched from the same install therefore share it, whatever
    accounts they are logged into. That is the whole mechanism.

    Each character writes ONE file of its own, Bagertz_<Character>.txt, and
    reads everyone else's. Nothing is ever written by two clients at once, so
    there is no contention to arbitrate - which a single shared file would have
    had, and which is why this is not one. A roster file is appended to once per
    login so a client knows which files exist; Lua cannot list a directory.

    What this replaces, and why it is gone rather than kept alongside:

    This addon used to hand its bags to the other client over addon messages.
    Those are broadcast to a whole PARTY or GUILD, so it needed a shared
    password to decide whose data to accept, a keystream to obfuscate the
    payload from everyone else in the channel, chunking to fit 255 bytes,
    beacons to find a paired box, and a roster negotiation to deliver alts who
    were not online. None of that was the feature. All of it existed to survive
    a hostile channel, and cost four hundred lines and a setup step that had to
    be performed identically on both boxes before anything worked at all.

    A file on your own disk is read by nothing but the clients already running
    on it. So: no password, no pairing, no obfuscation, no grouping requirement.
    And because the data is on disk rather than in flight, a character does not
    have to be online to be counted - the file it wrote last Tuesday is still
    there, which addon messages could never do.

    The trade, stated plainly: this works between clients on ONE machine. It
    cannot share with a friend on another PC, which the old channel could.

    Slash commands: /bagertz (or /bz)
--]]

BZ = {}
BZ.ADDON_NAME = "Bagertz"
BZ.VERSION    = "2.0.0"

BZ.data   = {} -- [charName] = { realm, time, mine, bags = { [itemID] = count } }
BZ.config = {} -- { debug, showZero, account, password, partner = { name, account } }

-- One file per character, plus a roster so they can be found. Lua cannot list
-- a directory, so a name that never announced itself can never be read.
BZ.ROSTER_FILE   = "Bagertz_roster.txt"
BZ.FILE_PREFIX   = "Bagertz_"
BZ.FILE_MAGIC    = "BAGERTZ1"

BZ.SCAN_DEBOUNCE = 2    -- seconds of quiet after a bag change before rescanning
BZ.READ_INTERVAL = 20   -- seconds between re-reading the other characters
BZ.WRITE_MIN_GAP = 5    -- seconds between writes of our own file

BZ.scanTimer     = nil  -- nil = no rescan pending

--[[ The optional link to another PC. All of it is inert until someone runs
     /bz share and the far end accepts: there is no password until then, and
     every send path refuses without one. ]]
BZ.PREFIX              = "BAGERTZ"
BZ.MAX_PAYLOAD         = 200  -- chars of payload per message, under the 255 limit
BZ.SEND_INTERVAL       = 0.4  -- seconds between outbound messages
BZ.BEACON_INTERVAL     = 20   -- seconds between beacons while linked
BZ.PEER_STALE_AFTER    = 60   -- seconds before a peer is considered gone
BZ.MIN_RESEND_INTERVAL = 5    -- seconds between resends after a bag change

BZ.sendQueue     = {}
BZ.sendTimer     = 0
BZ.beaconTimer   = 0
BZ.peers         = {}   -- [charName] = when a valid beacon was last heard
BZ.incoming      = {}   -- [charName] = { nonce, chunks, expected, name }
BZ.inventoryDirty = true
BZ.stats = { sent = 0, received = 0, rejected = 0 }
BZ.readTimer     = 0
BZ.lastWrite     = nil
BZ.fileState     = "not checked yet"
-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
function BZ.Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFCC66Bagertz|r: " .. msg)
end

function BZ.Debug(msg)
    if BZ.config.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF888888Bagertz debug|r: " .. msg)
    end
end

function BZ.Me()
    return UnitName("player")
end

-- ---------------------------------------------------------------------------------------------
-- Password: tagging and payload obfuscation
-- ---------------------------------------------------------------------------------------------

-- A small string hash (FNV-1a shaped, kept inside Lua 5.0's exact-integer range
-- by folding after every step). Not a cryptographic hash and not claimed to be -
-- it exists so the password itself never goes out on the wire.
function BZ.Hash(str)
    local h = 2166136261
    for i = 1, string.len(str) do
        h = h + string.byte(str, i)
        h = math.mod(h * 16777619, 4294967296)
    end
    return h
end

-- The per-batch pairing tag. Both sides compute hash(password .. ":" .. nonce);
-- a listener sees only the result, which changes every batch.
function BZ.Tag(nonce)
    if not BZ.config.password or BZ.config.password == "" then return nil end
    return string.format("%d", BZ.Hash(BZ.config.password .. ":" .. nonce))
end

-- Rotation happens within this alphabet, which keeps the message printable and
-- exactly the same length - no base64/hex expansion eating into the 255-byte
-- budget. The keystream is a small LCG seeded from password+nonce; multiplier
-- and modulus are kept tiny so the arithmetic stays exact in Lua 5.0's doubles.
--
-- Letters are in here because the payload now carries CHARACTER NAMES (a sync
-- sends every character on the account, not just the one logged in). Without
-- them, Crypt would pass names through untouched and your alts' names would sit
-- in plaintext in the middle of an otherwise obfuscated message. '~' is
-- deliberately absent: it separates fields outside the payload and must survive
-- unchanged.
--
-- Anything not in this alphabet passes through as-is, so an unexpected
-- character still round-trips correctly rather than corrupting.
--
-- Again: this is obfuscation. It stops casual reading, nothing more.
BZ.ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:,;=!"
BZ.ALPHABET_LEN = string.len(BZ.ALPHABET)

-- Deliberately contains every character class the wire format relies on, so
-- /bz selftest proves whether the channel delivers them unaltered. The pipe is
-- in here on purpose: it is WoW's escape character for |c / |r / |H, which is
-- exactly why the delimiter is a tilde and not a pipe.
BZ.CANARY = "1234567890:,~and|pipe"

function BZ.Crypt(text, nonce, decrypt)
    if not BZ.config.password or BZ.config.password == "" then return text end

    local k = math.mod(BZ.Hash(BZ.config.password .. "|" .. nonce), 65537)
    local out = ""
    for i = 1, string.len(text) do
        local c = string.sub(text, i, i)
        local idx = string.find(BZ.ALPHABET, c, 1, true)
        k = math.mod(k * 75 + 74, 65537)
        if idx then
            local shift = math.mod(k, BZ.ALPHABET_LEN)
            local newIdx
            if decrypt then
                newIdx = math.mod(idx - 1 - shift + BZ.ALPHABET_LEN * 2, BZ.ALPHABET_LEN) + 1
            else
                newIdx = math.mod(idx - 1 + shift, BZ.ALPHABET_LEN) + 1
            end
            out = out .. string.sub(BZ.ALPHABET, newIdx, newIdx)
        else
            -- Not a payload character; pass it through rather than corrupting it.
            out = out .. c
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------
-- Scanning our own bags
-- ---------------------------------------------------------------------------------------------
function BZ.ItemIDFromLink(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

local function ScanContainers(containers)
    local counts = {}
    for _, bag in ipairs(containers) do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local id = BZ.ItemIDFromLink(GetContainerItemLink(bag, slot))
                if id then
                    local _, count = GetContainerItemInfo(bag, slot)
                    counts[id] = (counts[id] or 0) + (count or 1)
                end
            end
        end
    end
    return counts
end

BZ.BAG_CONTAINERS  = { 0, 1, 2, 3, 4 }         -- backpack + equipped bags
BZ.BANK_CONTAINERS = { -1, 5, 6, 7, 8, 9, 10 } -- bank window + purchased bank bags

function BZ.ScanBags()
    return ScanContainers(BZ.BAG_CONTAINERS)
end

function BZ.ScanBank()
    return ScanContainers(BZ.BANK_CONTAINERS)
end

-- Bank contents are readable ONLY while the bank frame is open - away from a
-- bank those containers report zero slots. So the bank is scanned while you are
-- standing there and then KEPT, rather than rescanned on every bag update.
-- Without that distinction, walking away from the bank would "helpfully" record
-- an empty bank and wipe everything we knew about it.
function BZ.UpdateOwnData()
    local me = BZ.Me()
    if not me then return end

    local entry = BZ.data[me] or {}
    entry.realm = GetRealmName()
    entry.time  = time()
    -- This character is ours to write. Everyone read out of the shared folder
    -- is somebody else's file and is never rewritten by us.
    entry.mine  = true
    entry.bags  = BZ.ScanBags()
    if BZ.atBank then
        entry.bank = BZ.ScanBank()
        entry.bankTime = time()
    end

    BZ.data[me] = entry
    Bagertz_Data = BZ.data
    -- Only read by the optional link: it is what tells a linked partner there
    -- is something new to hear about. Cleared when the send goes out.
    BZ.inventoryDirty = true
    BZ.Debug("rescanned own bags")

    --[[ Straight to disk. Rate-limited because rearranging your bags fires
         BAG_UPDATE repeatedly, and rewriting the file per move is work nobody
         asked for -- but never skipped entirely, or the last change before you
         log out is the one that never lands. ]]
    if not BZ.lastWrite or (time() - BZ.lastWrite) >= BZ.WRITE_MIN_GAP then
        BZ.WriteOwn()
    else
        BZ.writePending = true
    end
end

-- ---------------------------------------------------------------------------------------------
-- The shared folder
-- ---------------------------------------------------------------------------------------------

function BZ.FileAPI()
    return (WriteCustomFile ~= nil) and (ReadCustomFile ~= nil)
end

function BZ.FileFor(name)
    return BZ.FILE_PREFIX .. name .. ".txt"
end

local function readFile(name)
    if not BZ.FileAPI() then return nil end
    local ok, text = pcall(ReadCustomFile, name)
    if not ok then return nil end
    return text
end

local function writeFile(name, text, mode)
    if not BZ.FileAPI() then return false end
    local ok = pcall(WriteCustomFile, name, text, mode or "w")
    return ok and true or false
end

--[[ Line-oriented and one field per line, so a file written by a newer version
     degrades to "some lines I did not recognise" rather than failing to parse.

       BAGERTZ1
       M~name~realm~time~bankTime
       B~itemId~count      (bags)
       K~itemId~count      (bank)
]]
function BZ.Serialize(name, entry)
    local out = { BZ.FILE_MAGIC }
    table.insert(out, "M~" .. name .. "~" .. (entry.realm or "") .. "~" ..
        (entry.time or 0) .. "~" .. (entry.bankTime or 0))
    for id, count in pairs(entry.bags or {}) do
        table.insert(out, "B~" .. id .. "~" .. count)
    end
    for id, count in pairs(entry.bank or {}) do
        table.insert(out, "K~" .. id .. "~" .. count)
    end
    return table.concat(out, "\n") .. "\n"
end

function BZ.Deserialize(text)
    if not text or text == "" then return nil end
    local entry, name = { bags = {}, bank = {} }, nil

    for line in string.gfind(text, "[^\n]+") do
        local _, _, kind, a, b, c, d = string.find(line, "^(%a)~([^~]*)~?([^~]*)~?([^~]*)~?([^~]*)$")
        if kind == "M" then
            name = a
            entry.realm = b
            entry.time = tonumber(c) or 0
            entry.bankTime = tonumber(d) or 0
        elseif kind == "B" then
            local id, n = tonumber(a), tonumber(b)
            if id and n then entry.bags[id] = n end
        elseif kind == "K" then
            local id, n = tonumber(a), tonumber(b)
            if id and n then entry.bank[id] = n end
        end
    end

    if not name or name == "" then return nil end
    return name, entry
end

--[[ Announce this character once per session so other clients know the file
     exists. Appended rather than rewritten: several clients may be starting at
     the same moment, and an append of one short line is the only write here
     that more than one process can be doing at once. ]]
function BZ.JoinRoster()
    local me = BZ.Me()
    if not me or not BZ.FileAPI() then return end
    for _, name in ipairs(BZ.RosterNames()) do
        if name == me then return end
    end
    writeFile(BZ.ROSTER_FILE, "R~" .. me .. "\n", "a")
end

function BZ.RosterNames()
    local names, seen = {}, {}
    for line in string.gfind(readFile(BZ.ROSTER_FILE) or "", "[^\n]+") do
        local _, _, name = string.find(line, "^R~(.+)$")
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    return names
end

--- Write this character's own file. Nothing else ever writes it.
function BZ.WriteOwn()
    local me = BZ.Me()
    local entry = me and BZ.data[me]
    if not entry then return false end
    if not BZ.FileAPI() then
        BZ.fileState = "no file API"
        return false
    end
    if writeFile(BZ.FileFor(me), BZ.Serialize(me, entry)) then
        BZ.lastWrite = time()
        return true
    end
    BZ.fileState = "write failed"
    return false
end

--[[ Read every other character's file.

     `mine` is never set on what comes back, because a file is only ever
     authored by the character it describes -- so the account that wrote it is
     the authority on it, and this client has no business claiming otherwise.

     Our own file is skipped: the copy in memory is newer than anything on
     disk by definition, and re-reading it would replace a live scan with a
     snapshot from up to five seconds ago. ]]
function BZ.ReadOthers()
    if not BZ.FileAPI() then
        BZ.fileState = "no file API - this needs Nampower"
        return 0
    end

    local me, found = BZ.Me(), 0
    for _, name in ipairs(BZ.RosterNames()) do
        if name ~= me then
            local parsed, entry = BZ.Deserialize(readFile(BZ.FileFor(name)))
            if parsed then
                entry.mine = false
                --[[ Stamped with WHEN it was read, so "is this actually coming
                     from the folder, or is it left over from the version that
                     synced over addon messages?" has an answer. Old cached
                     characters are indistinguishable from new ones otherwise,
                     and a wrong count that looks right is the worst kind. ]]
                entry.fromFile = time()
                BZ.data[parsed] = entry
                found = found + 1
            end
        end
    end

    Bagertz_Data = BZ.data
    BZ.fileState = found .. " character file(s) read"
    return found
end
-- ---------------------------------------------------------------------------------------------
-- Wire format
-- ---------------------------------------------------------------------------------------------

--[[ "id:count,id:count,..." for the wire, restricted to BZ.ALPHABET so
     BZ.Crypt can rotate within it without changing the length.

     Named apart from the file format on purpose: that one describes a whole
     character and this one a bare map of counts, and when both were called
     Serialize the second definition silently replaced the first. ]]
function BZ.PackCounts(counts)
    local parts = {}
    for id, count in pairs(counts or {}) do
        table.insert(parts, id .. ":" .. count)
    end
    return table.concat(parts, ",")
end

function BZ.UnpackCounts(str)
    local counts = {}
    for pair in string.gfind(str or "", "[^,]+") do
        local _, _, id, count = string.find(pair, "(%d+):(%d+)")
        if id then counts[tonumber(id)] = tonumber(count) end
    end
    return counts
end

-- One character: "Name=<bags>;<bank>", where each half is "id:count,id:count".
-- Several characters: blocks joined with "!". Every separator is part of
-- BZ.ALPHABET so it's rotated along with the data rather than standing out as
-- plaintext structure in an otherwise obfuscated payload.
function BZ.SerializeEntry(name, entry)
    return name .. "=" .. BZ.PackCounts(entry.bags) .. ";" .. BZ.PackCounts(entry.bank)
end

function BZ.SerializePayload(names)
    local blocks = {}
    for _, name in ipairs(names) do
        local entry = BZ.data[name]
        if entry then table.insert(blocks, BZ.SerializeEntry(name, entry)) end
    end
    return table.concat(blocks, "!")
end

-- Returns a list of { name, bags, bank }.
function BZ.DeserializePayload(str)
    local characters = {}
    for block in string.gfind(str or "", "[^!]+") do
        local _, _, name, bags, bank = string.find(block, "^([^=]+)=([^;]*);(.*)$")
        if name then
            table.insert(characters, {
                name = name,
                bags = BZ.UnpackCounts(bags),
                bank = BZ.UnpackCounts(bank),
            })
        end
    end
    return characters
end

-- Every channel we could currently reach a paired box on, narrowest first.
-- GUILD is included so the two boxes can find each other without being grouped,
-- but it is deliberately LAST: a party is two people, a guild can be hundreds,
-- and the inventory should go out over the smallest audience that reaches the
-- other box (see BZ.ChannelsForPeers).
function BZ.Channels()
    local channels = {}
    if GetNumRaidMembers() > 0 then
        table.insert(channels, "RAID")
    elseif GetNumPartyMembers() > 0 then
        table.insert(channels, "PARTY")
    end
    if BZ.config.useGuild ~= false and IsInGuild and IsInGuild() then
        table.insert(channels, "GUILD")
    end
    return channels
end

function BZ.Channel()
    local channels = BZ.Channels()
    return channels[1]
end

-- The channels a currently-known paired box was actually heard on. The bulky
-- inventory goes only to these, so being in a big guild doesn't mean every
-- sync sprays the whole guild - once your other box has been heard in the
-- party, that's where the data goes.
function BZ.ChannelsForPeers()
    local seen, channels = {}, {}
    for _, peer in pairs(BZ.peers) do
        local c = peer.channel
        if c and not seen[c] then
            seen[c] = true
            table.insert(channels, c)
        end
    end
    return channels
end

function BZ.Queue(msg, channel)
    table.insert(BZ.sendQueue, { msg = msg, channel = channel })
end

function BZ.DrainQueue()
    local item = table.remove(BZ.sendQueue, 1)
    if not item then return end
    pcall(SendAddonMessage, BZ.PREFIX, item.msg, item.channel)
    BZ.stats.sent = BZ.stats.sent + 1
    BZ.Debug("sent [" .. item.channel .. "]: " .. string.sub(item.msg, 1, 60))
end

-- A beacon says "I'm here and I know the password" in a few bytes. The full
-- inventory only follows once we've heard one, so the bulky payload never goes
-- out to a group that has no paired box in it.
function BZ.SendBeacon()
    local nonce = math.random(100000, 999999)
    local tag = BZ.Tag(nonce)
    if not tag then return end
    -- Beacons go out on every reachable channel, since that's how the two boxes
    -- find each other in the first place. They're a few bytes and say only
    -- "someone here runs this addon".
    local channels = BZ.Channels()
    for _, channel in ipairs(channels) do
        BZ.Queue("B~" .. nonce .. "~" .. tag .. "~" .. BZ.Me(), channel)
    end
end

--[[ Every character THIS MACHINE is the authority on, most recently seen
     first so a partial transfer still delivers the ones you are likeliest to
     care about.

     That now means this character plus everyone read out of the shared folder
     -- your other accounts on this PC -- because from the far end of a channel
     they are all equally "yours" and equally unable to speak for themselves.
     Characters learned FROM the channel are never relayed onward, which is
     what stops two partners bouncing a third party between them. ]]
function BZ.OwnedCharacters()
    local names = {}
    for name, entry in pairs(BZ.data) do
        if entry.mine or entry.fromFile then table.insert(names, name) end
    end
    table.sort(names, function(a, b)
        return (BZ.data[a].time or 0) > (BZ.data[b].time or 0)
    end)
    return names
end

-- scope "all" sends every character on this account; anything else sends only
-- the one logged in.
--
-- The two exist because they answer different needs. Meeting the other box, or
-- asking for a sync, should hand over the whole roster - that's the entire
-- point, since the other characters aren't online to speak for themselves. But
-- a bag change only ever concerns the character who made it, and re-sending
-- five characters' inventories every time you loot something would be pure
-- waste.
function BZ.SendInventory(scope)
    local password = BZ.config.password
    if not password or password == "" then
        BZ.Debug("no password set - refusing to send")
        return
    end

    -- Only to channels where a paired box has actually been heard. No peers
    -- means nothing to say, which is what keeps a big guild from receiving
    -- every sync.
    local channels = BZ.ChannelsForPeers()
    if table.getn(channels) == 0 then
        BZ.Debug("no paired box heard yet - holding the inventory back")
        return
    end

    local me = BZ.Me()
    local names
    if scope == "all" then
        names = BZ.OwnedCharacters()
    elseif BZ.data[me] then
        names = { me }
    else
        names = {}
    end
    if table.getn(names) == 0 then return end

    local nonce = math.random(100000, 999999)
    -- Resolve the tag before building anything. Without this the no-password
    -- case still refused to send, but only because concatenating a nil tag into
    -- the header threw - fail-closed by accident, and a script error in the
    -- player's face rather than a silent, intended no-op.
    local tag = BZ.Tag(nonce)
    if not tag then return end

    local payload = BZ.Crypt(BZ.SerializePayload(names), nonce, false)

    local total = math.ceil(string.len(payload) / BZ.MAX_PAYLOAD)
    if total < 1 then total = 1 end

    for _, channel in ipairs(channels) do
        -- The "2" is the wire format version. A client that doesn't recognise it
        -- ignores the whole transfer rather than half-parsing a format it
        -- doesn't understand and storing nonsense.
        BZ.Queue("H~2~" .. nonce .. "~" .. tag .. "~" ..
            (BZ.config.account or "") .. "~" .. total, channel)
        for i = 1, total do
            local from = (i - 1) * BZ.MAX_PAYLOAD + 1
            BZ.Queue("D~" .. nonce .. "~" .. i .. "~" ..
                string.sub(payload, from, from + BZ.MAX_PAYLOAD - 1), channel)
        end
    end
    BZ.inventoryDirty = false
    BZ.lastInventorySend = time()
    BZ.Debug("queued " .. table.getn(names) .. " character(s) in " .. total .. " chunk(s), " ..
        string.len(payload) .. " chars, to " .. table.concat(channels, "+"))
end

-- ---------------------------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------------------------
function BZ.OnAddonMessage(msg, sender)
    if sender == BZ.Me() then return end
    BZ.stats.received = BZ.stats.received + 1
    BZ.Debug("recv from " .. tostring(sender) .. ": " .. string.sub(msg, 1, 60))

    local _, _, kind, rest = string.find(msg, "^(%a)~(.+)$")
    if not kind then
        -- Arrived but unparseable. Worth surfacing rather than dropping: it's
        -- what a transport that mangles the delimiter looks like from here.
        BZ.stats.rejected = BZ.stats.rejected + 1
        BZ.Debug("  could not parse that message - delimiter may have been altered in transit")
        return
    end

    -- Canary: echoes exactly what arrived so a mangled transport is visible.
    -- Debug-gated so a stranger can't print into your chat frame at will.
    if kind == "T" then
        if BZ.config.debug then
            BZ.Say("selftest from " .. tostring(sender) .. " arrived as: |cFFFFFFFF" .. rest .. "|r")
            BZ.Say("  it was sent as: |cFFFFFFFF" .. BZ.CANARY .. "|r")
            if rest == BZ.CANARY then
                BZ.Say("  |cFF00FF7Fidentical - the channel passes our characters through intact.|r")
            else
                BZ.Say("  |cFFFF5179ALTERED IN TRANSIT|r - that's the bug.")
            end
        end
        return
    end

    if not BZ.config.password or BZ.config.password == "" then return end

    if kind == "B" then
        local _, _, nonce, tag, name = string.find(rest, "^(%d+)~(%d+)~(.+)$")
        if not nonce then return end
        if tag ~= BZ.Tag(nonce) then
            BZ.stats.rejected = BZ.stats.rejected + 1
            BZ.Debug("beacon from " .. tostring(name) .. " failed the password check - ignored")
            return
        end
        local firstSeen = not BZ.peers[name]
        -- Remember WHERE we heard them, so the inventory goes back over the same
        -- channel rather than every channel we happen to be on.
        BZ.peers[name] = { time = time(), channel = channel or BZ.Channel() }
        BZ.Debug("paired beacon from " .. name)
        -- Someone we trust is here: send ours, but only if it's changed since
        -- last time or we've never met them.
        -- Meeting a box for the first time hands over the WHOLE roster: the
        -- other characters aren't online to speak for themselves, and that is
        -- the entire reason the account keeps a list of them.
        if firstSeen then
            BZ.SendInventory("all")
        elseif BZ.inventoryDirty then
            BZ.SendInventory()
        end

    elseif kind == "H" then
        local _, _, version, nonce, tag, account, total =
            string.find(rest, "^(%d+)~(%d+)~(%d+)~([^~]*)~(%d+)$")
        if not nonce then return end
        if version ~= "2" then
            BZ.stats.rejected = BZ.stats.rejected + 1
            BZ.Debug("wire format v" .. tostring(version) .. " from " .. tostring(sender) ..
                " - update both boxes to the same version")
            return
        end
        if tag ~= BZ.Tag(nonce) then
            BZ.stats.rejected = BZ.stats.rejected + 1
            BZ.Debug("header from " .. tostring(sender) .. " failed the password check - ignored")
            return
        end
        BZ.incoming[sender] = {
            nonce = nonce, account = account,
            expected = tonumber(total), chunks = {},
        }
        BZ.Debug("incoming transfer from " .. tostring(sender) .. " (" .. total .. " chunks)")

    elseif kind == "D" then
        local _, _, nonce, index, data = string.find(rest, "^(%d+)~(%d+)~(.*)$")
        if not nonce then return end
        local pending = BZ.incoming[sender]
        -- The nonce ties chunks to the header that was already password-checked,
        -- so unpaired senders can't inject data into a transfer.
        if not pending or pending.nonce ~= nonce then return end

        pending.chunks[tonumber(index)] = data or ""

        local have = 0
        for _ in pairs(pending.chunks) do have = have + 1 end
        if have < pending.expected then return end

        local joined = ""
        for i = 1, pending.expected do
            joined = joined .. (pending.chunks[i] or "")
        end
        local characters = BZ.DeserializePayload(BZ.Crypt(joined, pending.nonce, true))
        local updated = {}

        for _, incoming in ipairs(characters) do
            local nBank = 0
            for _ in pairs(incoming.bank or {}) do nBank = nBank + 1 end

            local entry = BZ.data[incoming.name] or {}
            entry.realm   = GetRealmName()
            entry.time    = time()
            entry.account = (pending.account ~= "" and pending.account) or entry.account
            entry.bags    = incoming.bags
            -- Never flagged mine: a character learned from the other box belongs
            -- to that account, and relaying it back would create an echo whose
            -- staleness we'd then have to arbitrate against the original.
            --[[ Never flagged as ours: a character learned from the other box
                 belongs to that account, and relaying it back would create an
                 echo whose staleness we would then have to arbitrate against
                 the original. The stamp is what keeps /bz honest about which
                 of three places a count came from. ]]
            entry.mine     = nil
            entry.fromFile = nil
            entry.fromChannel = time()
            -- Only replace a known bank with a non-empty one: the sender may not
            -- have visited a bank yet, and an empty section shouldn't erase what
            -- we already had.
            if nBank > 0 then
                entry.bank = incoming.bank
                entry.bankTime = time()
            end

            BZ.data[incoming.name] = entry
            table.insert(updated, BZ.DisplayName(incoming.name))
        end

        Bagertz_Data = BZ.data
        BZ.incoming[sender] = nil
        if table.getn(updated) > 0 then
            BZ.Say("updated " .. table.getn(updated) .. " character(s): " ..
                table.concat(updated, ", "))
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------
-- Linking with someone on another PC
-- ---------------------------------------------------------------------------------------------

--[[ On this machine nothing here is needed: the shared folder already links
     your own accounts, with no secret at all. This exists for the other case
     -- a partner on their own PC, where there is no shared folder and the only
     road between you is the game itself.

     The secret travels by WHISPER, not by addon message. Addon messages are
     broadcast to a whole party or guild, so handing over a password on one
     would give it to everybody present; a whisper reaches one player. That is
     not secrecy from the server, which sees everything either way -- it is
     secrecy from the twenty other people standing next to you.

     And it is never accepted silently. An addon that took any pairing offer
     that arrived would let anyone who whispers you start receiving your bags,
     so the far end is asked. One click, once. ]]

BZ.PAIR_OFFER  = "BZPAIR1"
BZ.PAIR_ACCEPT = "BZPAIR2"
BZ.PAIR_END    = "BZPAIR3"

-- Alphanumerics only: a whisper is rendered text, and | is WoW's escape
-- character. Nothing here can be mistaken for markup or eaten by it.
local PW_ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

function BZ.NewPassword()
    if not BZ.seeded then
        math.randomseed(time())
        BZ.seeded = true
    end
    local out, n = "", string.len(PW_ALPHABET)
    for _ = 1, 14 do
        local i = math.random(1, n)
        out = out .. string.sub(PW_ALPHABET, i, i)
    end
    return out
end

function BZ.AccountLabel()
    local label = BZ.config.account
    if label and label ~= "" then return label end
    return BZ.Me() or "?"
end

local function whisperTo(name, text)
    if not name or name == "" then return end
    SendChatMessage(text, "WHISPER", nil, name)
end

--- Offer to link with a character. Nothing changes here until they accept.
function BZ.Share(name)
    if not name or name == "" then
        BZ.Say("usage: |cFFFFFFFF/bz share <character>|r - someone on another PC.")
        return
    end
    if name == BZ.Me() then
        BZ.Say("that is this character.")
        return
    end

    --[[ The password is held aside rather than applied now. Applying it here
         would start refusing the partner you are already linked to, on the
         strength of an offer that may never be accepted. ]]
    BZ.pendingPair = { name = name, password = BZ.NewPassword(), at = time() }
    whisperTo(name, BZ.PAIR_OFFER .. "~" .. BZ.pendingPair.password ..
        "~" .. BZ.AccountLabel())
    BZ.Say("asked |cFFFFFFFF" .. name .. "|r to link. Nothing is shared until " ..
        "they accept, and they have to be online with this addon running.")
end

--- Accept an offer that arrived. Called by the popup, not by an event.
function BZ.AcceptPair()
    local offer = BZ.pendingOffer
    if not offer then return end
    BZ.pendingOffer = nil

    BZ.config.password = offer.password
    BZ.config.partner = { name = offer.name, account = offer.account }
    Bagertz_Config = BZ.config

    whisperTo(offer.name, BZ.PAIR_ACCEPT .. "~" .. BZ.AccountLabel())
    BZ.Say("linked with |cFF00FF7F" .. offer.name .. "|r" ..
        ((offer.account and offer.account ~= "") and
            (" |cFF888888(" .. offer.account .. ")|r") or "") ..
        ". Inventories will sync while you are both in the same party or guild.")
    BZ.HidePairPopup()
end

function BZ.DeclinePair()
    local offer = BZ.pendingOffer
    BZ.pendingOffer = nil
    if offer then
        whisperTo(offer.name, BZ.PAIR_END)
        BZ.Say("declined " .. offer.name .. ".")
    end
    BZ.HidePairPopup()
end

--[[ Unlink from both ends where possible.

     Telling them is the point: a one-sided unlink leaves the other client
     still sending, still believing it is linked, and wondering why nothing
     comes back. Their characters go too, because what is left behind would be
     a frozen snapshot that looks exactly like live data. ]]
function BZ.Unlink()
    local partner = BZ.config.partner
    if not partner then
        BZ.Say("not linked to anyone.")
        return
    end

    whisperTo(partner.name, BZ.PAIR_END)
    BZ.ForgetChannelData()
    BZ.config.password = nil
    BZ.config.partner = nil
    Bagertz_Config = BZ.config
    BZ.Say("unlinked from |cFFFFFFFF" .. partner.name .. "|r. Nothing is sent " ..
        "or accepted over the channel any more.")
    BZ.RefreshPairPanel()
end

--- Drop everything that arrived over the channel, keeping the folder's data.
function BZ.ForgetChannelData()
    local dropped = {}
    for name, entry in pairs(BZ.data) do
        if entry.fromChannel then table.insert(dropped, name) end
    end
    for _, name in ipairs(dropped) do BZ.data[name] = nil end
    Bagertz_Data = BZ.data
    return table.getn(dropped)
end

--[[ The pairing handshake, carried on ordinary whispers.

     Returns true when the whisper was ours, so the caller knows it was
     handled. It still appears in the chat window -- suppressing it would mean
     standing in front of ChatFrame_OnEvent, which other chat addons replace,
     and this happens once per partner rather than once per message. ]]
function BZ.OnWhisper(message, sender)
    if not message or not sender then return false end

    local _, _, password, account =
        string.find(message, "^" .. BZ.PAIR_OFFER .. "~([^~]+)~?(.*)$")
    if password then
        BZ.pendingOffer = { name = sender, password = password, account = account }
        BZ.ShowPairPopup(sender, account)
        return true
    end

    local _, _, theirAccount = string.find(message, "^" .. BZ.PAIR_ACCEPT .. "~?(.*)$")
    if theirAccount then
        local pending = BZ.pendingPair
        if not pending or pending.name ~= sender then
            BZ.Debug("an acceptance from " .. sender .. " we never asked")
            return true
        end
        BZ.pendingPair = nil
        BZ.config.password = pending.password
        BZ.config.partner = { name = sender, account = theirAccount }
        Bagertz_Config = BZ.config
        BZ.Say("|cFF00FF7F" .. sender .. "|r accepted. Linked - inventories will " ..
            "sync while you are both in the same party or guild.")
        BZ.RefreshPairPanel()
        return true
    end

    if string.find(message, "^" .. BZ.PAIR_END) then
        local partner = BZ.config.partner
        if partner and partner.name == sender then
            BZ.ForgetChannelData()
            BZ.config.password = nil
            BZ.config.partner = nil
            Bagertz_Config = BZ.config
            BZ.Say("|cFFFF5179" .. sender .. " unlinked.|r Nothing more is shared.")
            BZ.RefreshPairPanel()
        elseif BZ.pendingPair and BZ.pendingPair.name == sender then
            BZ.pendingPair = nil
            BZ.Say(sender .. " declined.")
        end
        return true
    end

    return false
end
-- ---------------------------------------------------------------------------------------------
-- The link window, and the question asked at the other end
-- ---------------------------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local FONT  = "Fonts\\FRIZQT__.TTF"

local function panel(name, w, h)
    local f = CreateFrame("Button", name, UIParent)
    f:SetWidth(w)
    f:SetHeight(h)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.04, 0.04, 0.05, 0.94)
    bg:SetAllPoints(f)

    -- Four edges rather than a backdrop: no edge file to tile badly at any size.
    local edges = {}
    for i = 1, 4 do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetTexture(WHITE)
        t:SetVertexColor(1, 0.8, 0.4, 0.85)
        edges[i] = t
    end
    edges[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    edges[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    edges[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    edges[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    edges[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    edges[4]:SetWidth(1)
    return f
end

local function label(parent, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size)
    fs:SetTextColor(r or 0.9, g or 0.9, b or 0.9)
    return fs
end

local function button(parent, text, width)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(width or 90)
    b:SetHeight(20)
    b:EnableMouse(true)
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetTexture(WHITE)
    b.fill:SetVertexColor(0.18, 0.18, 0.2, 1)
    b.fill:SetAllPoints(b)
    b.label = label(b, 11)
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetText(text)
    return b
end

----------------------------------------------------------------------

--[[ The question at the receiving end.

     Deliberately a question rather than a notification. An addon that linked
     on arrival would let anyone who whispers you start receiving your bag
     contents, and the person doing it would not even have to be in your
     guild. ]]
function BZ.ShowPairPopup(from, account)
    if not BZ.pairPopup then
        local f = panel("BagertzPairPopup", 330, 110)
        f:SetPoint("TOP", UIParent, "TOP", 0, -200)

        f.title = label(f, 13, 1, 0.8, 0.4)
        f.title:SetPoint("TOP", f, "TOP", 0, -12)
        f.title:SetText("Share inventories?")

        f.who = label(f, 11)
        f.who:SetWidth(300)
        f.who:SetPoint("TOP", f.title, "BOTTOM", 0, -8)

        f.note = label(f, 10, 0.62, 0.65, 0.72)
        f.note:SetWidth(300)
        f.note:SetPoint("TOP", f.who, "BOTTOM", 0, -6)
        f.note:SetText("They will see what your characters are carrying.")

        f.yes = button(f, "Accept", 90)
        f.yes:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 10)
        f.yes:SetScript("OnClick", function() BZ.AcceptPair() end)

        f.no = button(f, "No thanks", 90)
        f.no:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 10)
        f.no:SetScript("OnClick", function() BZ.DeclinePair() end)

        BZ.pairPopup = f
    end

    BZ.pairPopup.who:SetText("|cFFFFFFFF" .. tostring(from) .. "|r" ..
        ((account and account ~= "") and (" |cFF888888(" .. account .. ")|r") or "") ..
        " wants to link inventories with you.")
    BZ.pairPopup:Show()
end

function BZ.HidePairPopup()
    if BZ.pairPopup then BZ.pairPopup:Hide() end
end

----------------------------------------------------------------------

--[[ What you are linked to, and the way out of it.

     One window because there is one thing to say: who, on what account, and a
     button to stop. A status line in chat scrolls away; this does not. ]]
function BZ.BuildPairPanel()
    if BZ.pairPanel then return BZ.pairPanel end

    local f = panel("BagertzLinkPanel", 320, 150)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    f.title = label(f, 13, 1, 0.8, 0.4)
    f.title:SetPoint("TOP", f, "TOP", 0, -12)
    f.title:SetText("Bagertz - sharing with another PC")

    f.state = label(f, 11)
    f.state:SetWidth(292)
    f.state:SetPoint("TOP", f.title, "BOTTOM", 0, -12)

    f.note = label(f, 10, 0.62, 0.65, 0.72)
    f.note:SetWidth(292)
    f.note:SetPoint("TOP", f.state, "BOTTOM", 0, -8)

    f.unlink = button(f, "Unlink", 100)
    f.unlink:SetPoint("BOTTOM", f, "BOTTOM", 0, 36)
    f.unlink:SetScript("OnClick", function() BZ.Unlink() end)

    f.close = button(f, "Close", 100)
    f.close:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    f.close:SetScript("OnClick", function() f:Hide() end)

    BZ.pairPanel = f
    return f
end

function BZ.RefreshPairPanel()
    local f = BZ.pairPanel
    if not f then return end

    local partner = BZ.config.partner
    if partner then
        local counted = 0
        for _, entry in pairs(BZ.data) do
            if entry.fromChannel then counted = counted + 1 end
        end
        f.state:SetTextColor(0.4, 0.85, 0.47)
        f.state:SetText("Linked with " .. partner.name ..
            ((partner.account and partner.account ~= "")
                and ("  (" .. partner.account .. ")") or ""))
        f.note:SetText(counted .. " of their character(s) known. Sharing happens " ..
            "while you are both in the same party or guild.")
        f.unlink:Show()
    else
        f.state:SetTextColor(0.62, 0.65, 0.72)
        f.state:SetText("Not linked to anyone.")
        f.note:SetText("Your own accounts on this PC are already shared through " ..
            "the folder and need no link. Use /bz share <character> for someone " ..
            "on a different PC.")
        f.unlink:Hide()
    end
end

function BZ.TogglePairPanel()
    local f = BZ.BuildPairPanel()
    if f:IsShown() then
        f:Hide()
    else
        BZ.RefreshPairPanel()
        f:Show()
    end
end
-- ---------------------------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------------------------
function BZ.CountFor(name, itemID)
    local entry = BZ.data[name]
    if not entry then return 0, 0 end
    local bags = (entry.bags and entry.bags[itemID]) or 0
    local bank = (entry.bank and entry.bank[itemID]) or 0
    return bags, bank
end

-- "Account/Character" where the account is known. WoW's API exposes no account
-- name at all - it exists only as a folder name on disk - so it's a label the
-- player sets once per account (/bz account) which then travels with that
-- account's data. Without one, the character name stands alone rather than
-- showing a confusing empty prefix.
function BZ.DisplayName(name)
    local entry = BZ.data[name]
    local account = entry and entry.account
    if name == BZ.Me() then account = BZ.config.account or account end
    if account and account ~= "" then return account .. "/" .. name end
    return name
end

function BZ.AddTooltipLines(tooltip, itemID)
    if not itemID then
        if BZ.config.debugTips then BZ.Say("  no item id could be parsed from that link") end
        return
    end

    local me = BZ.Me()
    local names = {}
    for name in pairs(BZ.data) do
        if name ~= me then table.insert(names, name) end
    end
    table.sort(names)
    -- Your own character first: it's the count you're most often checking
    -- against, and it reads oddly below a list of alts.
    if BZ.data[me] then table.insert(names, 1, me) end

    local any = false
    for _, name in ipairs(names) do
        local bags, bank = BZ.CountFor(name, itemID)
        if bags > 0 or bank > 0 then
            local parts = {}
            if bags > 0 then table.insert(parts, bags .. " in bags") end
            if bank > 0 then table.insert(parts, bank .. " in bank") end

            local text = BZ.DisplayName(name) .. ": " .. table.concat(parts, ", ")
            if bags > 0 and bank > 0 then
                text = text .. " (" .. (bags + bank) .. ")"
            end

            if name == me then
                tooltip:AddLine(text, 0.4, 1, 0.4)
            else
                tooltip:AddLine(text, 1, 0.82, 0)
            end
            any = true
        end
    end
    if BZ.config.debugTips and not any then
        BZ.Say("  item " .. itemID .. ": nobody holds any")
    end

    -- Say zero out loud rather than adding nothing. A bare tooltip reads exactly
    -- the same as a broken addon - which is precisely how this was reported, and
    -- it took a tracing build to tell "nobody has any" apart from "the hook
    -- never fired". An explicit zero also answers the question actually being
    -- asked at a crafting window: not "who has these mats" but "do I need to go
    -- buy them".
    --
    -- Only when at least one character is known. With an empty cache every item
    -- in the game would claim a confident zero, which would be a lie of a
    -- different kind.
    if not any and BZ.config.showZero ~= false and table.getn(names) > 0 then
        tooltip:AddLine("Owned: 0", 0.6, 0.6, 0.6)
        any = true
    end

    if any then tooltip:Show() end
end

-- Every way the client puts an item into a tooltip. Each entry names the
-- tooltip method and a function that returns that item's link from the SAME
-- arguments the method was called with.
--
-- The first version hooked four of these, which is why counts only appeared in
-- your bags. Crafting frames call SetCraftItem / SetCraftSpell /
-- SetTradeSkillItem, a merchant calls SetMerchantItem, the auction house calls
-- SetAuctionItem - none were covered, so the tooltip appeared without our lines.
-- This list is modelled on Bagshui's, which is the working reference for it on
-- this client.
--
-- Explicit parameters per entry rather than varargs: Lua 5.0 exposes varargs as
-- a local table named `arg`, which is also the name of WoW's event-argument
-- globals, and these run inside the tooltip code path where shadowing that is
-- an unhelpful surprise.
--
-- SetAuctionSellItem, SetInboxItem and SetSendMailItem are deliberately absent.
-- Vanilla gives no link for those - only a name and a texture - so identifying
-- the item would need a name-to-item catalogue this addon does not keep. They
-- show no counts rather than wrong ones.
BZ.TOOLTIP_HOOKS = {
    { method = "SetBagItem",
      link = function(self, bag, slot) return GetContainerItemLink(bag, slot) end },

    { method = "SetInventoryItem",
      link = function(self, unit, slotID) return GetInventoryItemLink(unit, slotID) end },

    { method = "SetHyperlink",
      link = function(self, link) return link end },

    { method = "SetLootItem",
      link = function(self, slot) return GetLootSlotLink(slot) end },

    { method = "SetLootRollItem",
      link = function(self, id) return GetLootRollItemLink(id) end },

    { method = "SetMerchantItem",
      link = function(self, index) return GetMerchantItemLink(index) end },

    { method = "SetBuybackItem",
      link = function(self, index) return GetBuybackItemLink(index) end },

    -- Professions come in two flavours in vanilla: enchanting and a few others
    -- use the Craft API, everything else uses TradeSkill. Both distinguish the
    -- item being made (no slot) from one of its reagents (slot given), and the
    -- reagents are the whole point here - "do I already have these mats?"
    { method = "SetCraftItem",
      link = function(self, skill, slot)
          if slot then return GetCraftReagentItemLink and GetCraftReagentItemLink(skill, slot) end
          return GetCraftItemLink and GetCraftItemLink(skill)
      end },

    { method = "SetCraftSpell",
      link = function(self, slot) return GetCraftItemLink and GetCraftItemLink(slot) end },

    { method = "SetTradeSkillItem",
      link = function(self, skill, slot)
          if slot then
              return GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(skill, slot)
          end
          return GetTradeSkillItemLink and GetTradeSkillItemLink(skill)
      end },

    { method = "SetQuestItem",
      link = function(self, qtype, slot) return GetQuestItemLink(qtype, slot) end },

    { method = "SetQuestLogItem",
      link = function(self, qtype, slot) return GetQuestLogItemLink(qtype, slot) end },

    { method = "SetTradePlayerItem",
      link = function(self, index) return GetTradePlayerItemLink(index) end },

    { method = "SetTradeTargetItem",
      link = function(self, index) return GetTradeTargetItemLink(index) end },

    { method = "SetAuctionItem",
      link = function(self, atype, index) return GetAuctionItemLink(atype, index) end },
}

-- Installs every hook a given tooltip actually has. A method the frame doesn't
-- have is skipped rather than erroring - ItemRefTooltip has far fewer than
-- GameTooltip.
--
-- The original is called exactly once and its return passed straight back; our
-- line-adding runs afterwards inside a pcall, so a link getter that misbehaves
-- on some server-custom item degrades to "no counts on this tooltip" instead of
-- breaking the tooltip itself.
function BZ.HookTooltipFrame(tooltip)
    if not tooltip then return 0 end
    local installed = 0

    for _, entry in ipairs(BZ.TOOLTIP_HOOKS) do
        local orig = tooltip[entry.method]
        local flag = "bzHooked" .. entry.method
        if orig and not tooltip[flag] then
            tooltip[flag] = true
            local getLink = entry.link
            local methodName = entry.method
            tooltip[entry.method] = function(a, b, c, d, e)
                local ret = orig(a, b, c, d, e)
                local ok, link = pcall(getLink, a, b, c, d, e)
                -- /bz tips. There are three quite different reasons a tooltip can
                -- come up bare, and they are indistinguishable from the outside:
                -- the method never fires (that frame uses a different tooltip or
                -- different method), it fires but the link getter returns nil
                -- (wrong getter or wrong arguments), or both work and we simply
                -- hold none of that item. This says which.
                if BZ.config.debugTips then
                    BZ.Say("tip |cFFFFFFFF" .. methodName .. "|r(" ..
                        tostring(b) .. ", " .. tostring(c) .. ") -> " ..
                        (ok and tostring(link) or "|cFFFF5179getter errored|r"))
                end
                if ok and link then
                    BZ.AddTooltipLines(a, BZ.ItemIDFromLink(link))
                end
                return ret
            end
            installed = installed + 1
        end
    end

    return installed
end

function BZ.HookTooltips()
    BZ.hookCount = BZ.HookTooltipFrame(GameTooltip) + BZ.HookTooltipFrame(ItemRefTooltip)
end


-- ---------------------------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------------------------
SLASH_BAGERTZ1 = "/bagertz"
SLASH_BAGERTZ2 = "/bz"
SlashCmdList["BAGERTZ"] = function(msg)
    local words = {}
    for word in string.gfind(msg or "", "[^%s]+") do table.insert(words, word) end
    local cmd = string.lower(words[1] or "")

    if cmd == "share" or cmd == "link" then
        BZ.Share(words[2])

    elseif cmd == "unlink" then
        BZ.Unlink()

    elseif cmd == "link?" or cmd == "sharing" then
        BZ.TogglePairPanel()

    elseif cmd == "read" or cmd == "sync" then
        -- "sync" kept as a word people will reach for out of habit; there is
        -- nothing to synchronise any more, only a folder to re-read.
        BZ.JoinRoster()
        BZ.UpdateOwnData()
        local n = BZ.ReadOthers()
        BZ.Say("re-read the shared folder: " .. n .. " other character(s).")

    elseif cmd == "forget" and words[2] then
        local target
        for name in pairs(BZ.data) do
            if string.lower(name) == string.lower(words[2]) then target = name end
        end
        if target then
            BZ.data[target] = nil
            Bagertz_Data = BZ.data
            BZ.Say("forgot " .. target .. ".")
        else
            BZ.Say("no cached character called \"" .. words[2] .. "\".")
        end

    elseif cmd == "stale" then
        --[[ Drop only what has no file behind it.

             After the upgrade the cache still holds every character the
             addon-message version ever heard of, and those counts are frozen
             at whenever that sync last ran. "Clear everything" would work, but
             it also throws away the characters that ARE current, and then the
             tooltips look broken for a moment for no reason. ]]
        BZ.ReadOthers()
        local me, dropped = BZ.Me(), {}
        for name, entry in pairs(BZ.data) do
            if name ~= me and not entry.fromFile then table.insert(dropped, name) end
        end
        for _, name in ipairs(dropped) do BZ.data[name] = nil end
        Bagertz_Data = BZ.data

        if table.getn(dropped) == 0 then
            BZ.Say("nothing stale - every character came from the folder.")
        else
            table.sort(dropped)
            BZ.Say("dropped " .. table.concat(dropped, ", ") ..
                " - left over from the old sync, with no file in the folder. " ..
                "Each comes back once you log it in.")
        end

    elseif cmd == "clear" then
        BZ.data = {}
        Bagertz_Data = BZ.data
        BZ.UpdateOwnData()
        -- Straight back out of the folder, so "cleared" does not look like
        -- "broke it" for the twenty seconds until the next read.
        local n = BZ.ReadOthers()
        BZ.Say("cleared the cache. " .. n .. " character(s) came straight back " ..
            "from the folder; anything that did not had no file.")

    elseif cmd == "zero" then
        if string.lower(words[2] or "") == "off" then
            BZ.config.showZero = false
            BZ.Say("zero lines off - tooltips stay bare when nobody holds the item.")
        else
            BZ.config.showZero = true
            BZ.Say("zero lines on - a tooltip says so when nobody holds the item.")
        end
        Bagertz_Config = BZ.config

    elseif cmd == "tips" then
        BZ.config.debugTips = not BZ.config.debugTips
        Bagertz_Config = BZ.config
        BZ.Say("tooltip tracing: " .. (BZ.config.debugTips and
            "|cFF00FF7Fon|r - hover something in the frame that is not working" or
            "|cFFFF5179off|r"))
        if BZ.config.debugTips then
            BZ.Say("hooks installed on this session: " .. tostring(BZ.hookCount))
        end

    elseif cmd == "debug" then
        BZ.config.debug = not BZ.config.debug
        Bagertz_Config = BZ.config
        BZ.Say("debug: " .. (BZ.config.debug and "|cFF00FF7Fon|r" or "|cFFFF5179off|r"))

    elseif cmd == "account" then
        if not words[2] then
            BZ.Say("this account is labelled: " ..
                ((BZ.config.account and BZ.config.account ~= "")
                    and ("|cFF00FF7F" .. BZ.config.account .. "|r")
                    or "|cFF888888unlabelled|r"))
            BZ.Say("Optional. Everything works unlabelled - you just see \"Salabeard\" rather " ..
                "than \"Whatever/Salabeard\", where Whatever is a word you pick. " ..
                "WoW gives addons no way to read your account name, " ..
                "so if you want one shown it has to come from you: " ..
                "|cFFFFFFFF/bz account <name>|r, once per account.")
        else
            -- Tildes would break the wire format, which uses them as the field
            -- separator.
            local label = string.gsub(words[2], "~", "-")
            BZ.config.account = label
            Bagertz_Config = BZ.config
            BZ.WriteOwn()
            BZ.Say("this account is now labelled |cFF00FF7F" .. label .. "|r.")
        end

    elseif cmd == "" then
        local me = BZ.Me()

        --[[ Status first, and it is a much shorter story than it used to be.
             There is no pairing to be half-done any more: either the folder
             can be read or it cannot, and either other characters have written
             to it or they have not. ]]
        if not BZ.FileAPI() then
            BZ.Say("|cFFFF5179Nampower's file API is missing|r - nothing can be " ..
                "shared. In OctoLauncher: Mods -> Nampower.")
        else
            BZ.Say("shared folder: |cFF00FF7FCustomData|r, " .. BZ.fileState)
            BZ.Say("my file: " .. BZ.FileFor(me or "?") ..
                (BZ.lastWrite and (" |cFF888888(written " ..
                    math.floor((time() - BZ.lastWrite)) .. "s ago)|r") or
                 " |cFFFF5179(not written yet)|r"))
        end

        --[[ The channel is off unless someone linked, so it is only worth a
             line when it is on. A permanent "not linked" is noise for the
             people this never applies to. ]]
        if BZ.config.partner then
            BZ.Say("linked with |cFF00FF7F" .. BZ.config.partner.name .. "|r" ..
                ((BZ.config.partner.account and BZ.config.partner.account ~= "")
                    and (" |cFF888888(" .. BZ.config.partner.account .. ")|r") or "") ..
                " - |cFFFFFFFF/bz unlink|r to stop")
        end

        BZ.Say("account label: " .. ((BZ.config.account and BZ.config.account ~= "")
            and ("|cFF00FF7F" .. BZ.config.account .. "|r")
            or "|cFF888888none (optional - /bz account <name>)|r"))

        local names, stale = {}, 0
        for name in pairs(BZ.data) do table.insert(names, name) end
        table.sort(names)
        BZ.Say("known characters:")
        for _, name in ipairs(names) do
            local entry = BZ.data[name]
            local types = 0
            for _ in pairs(entry.bags or {}) do types = types + 1 end
            local age = entry.time and math.floor((time() - entry.time) / 60) or nil
            --[[ Where it came from, not merely who it is. This is the
                 question worth answering after an upgrade. ]]
            local label
            if name == me then
                label = BZ.DisplayName(name) .. " |cFF888888(this character, live)|r"
            elseif entry.fromFile then
                label = BZ.DisplayName(name) .. " |cFF00FF7F(from the folder)|r"
            elseif entry.fromChannel then
                label = BZ.DisplayName(name) .. " |cFF66CCFF(from your link)|r"
            else
                stale = stale + 1
                label = BZ.DisplayName(name) ..
                    " |cFFFF5179(cached, NOT from the folder)|r"
            end
            BZ.Say("  " .. label ..
                " - " .. types .. " item types" ..
                (age and (", updated " .. age .. "m ago") or ""))
        end
        if stale > 0 then
            --[[ The honest answer to "is it working, or am I looking at what
                 the old version left behind?" Nothing else can tell them
                 apart: a cached count looks exactly like a fresh one. ]]
            BZ.Say("|cFFFF5179" .. stale .. " character(s) above are left over " ..
                "from the version that synced over addon messages|r - they have " ..
                "no file in the folder. |cFFFFFFFF/bz clear|r drops them; each " ..
                "one reappears once you log it in.")
        end
        if table.getn(names) <= 1 then
            BZ.Say("|cFF888888Only this character so far. Log another one in " ..
                "from this same install and it will appear.|r")
        end

    else
        BZ.Say("usage: /bz, /bz read, /bz stale, /bz account <name>, /bz zero on|off,")
        BZ.Say("       /bz forget <name>, /bz clear, /bz tips, /bz debug")
        BZ.Say("another PC: /bz share <character>, /bz sharing, /bz unlink")
    end
end
-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("BANKFRAME_OPENED")
ev:RegisterEvent("BANKFRAME_CLOSED")
ev:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
--[[ Only for the optional link to another PC. With nobody linked there is no
     password, and every send path refuses without one, so these cost nothing
     to the people who never use them. ]]
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 ~= BZ.ADDON_NAME then return end
        BZ.data = Bagertz_Data or {}
        BZ.config = Bagertz_Config or {}
        BZ.HookTooltips()

        if not BZ.FileAPI() then
            BZ.Say("|cFFFF5179Nampower's file API is missing|r, so other " ..
                "characters cannot be read. In OctoLauncher: Mods -> Nampower.")
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        BZ.JoinRoster()
        BZ.UpdateOwnData()
        BZ.ReadOthers()

    elseif event == "PLAYER_LOGOUT" then
        --[[ The last word. Everything since the previous write is only in
             memory, and memory is exactly what logging out discards -- while
             the other client is still running and about to read this file. ]]
        BZ.WriteOwn()

    elseif event == "CHAT_MSG_ADDON" then
        -- arg1=prefix, arg2=message, arg3=channel, arg4=sender
        if arg1 == BZ.PREFIX then BZ.OnAddonMessage(arg2, arg4) end

    elseif event == "CHAT_MSG_WHISPER" then
        -- arg1=message, arg2=sender. Only the pairing handshake is ours.
        BZ.OnWhisper(arg1, arg2)

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        BZ.beaconTimer = BZ.BEACON_INTERVAL -- beacon on the next tick

    elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" then
        -- Debounced: looting a stack fires this several times in a row, and
        -- rescanning every bag on each one is wasted work.
        BZ.scanTimer = BZ.SCAN_DEBOUNCE

    elseif event == "BANKFRAME_OPENED" then
        BZ.atBank = true
        BZ.UpdateOwnData()

    elseif event == "BANKFRAME_CLOSED" then
        -- One last scan WHILE the frame is still readable, then stop. After this
        -- the bank containers report no slots, so anything scanned later would
        -- read as an empty bank.
        BZ.UpdateOwnData()
        BZ.atBank = false
    end
end)

ev:SetScript("OnUpdate", function()
    local elapsed = arg1

    if BZ.scanTimer then
        BZ.scanTimer = BZ.scanTimer - elapsed
        if BZ.scanTimer <= 0 then
            BZ.scanTimer = nil
            BZ.UpdateOwnData()
            -- A linked partner hears about the change without waiting for
            -- the next beacon, rate-limited so rearranging bags is not a
            -- broadcast per move.
            if BZ.inventoryDirty and BZ.ChannelsForPeers and
               table.getn(BZ.ChannelsForPeers()) > 0 then
                if not BZ.lastInventorySend or
                   (time() - BZ.lastInventorySend) >= BZ.MIN_RESEND_INTERVAL then
                    BZ.SendInventory()
                end
            end
        end
    end

    -- A write held back by the rate limit still has to happen.
    if BZ.writePending and
       (not BZ.lastWrite or (time() - BZ.lastWrite) >= BZ.WRITE_MIN_GAP) then
        BZ.writePending = nil
        BZ.WriteOwn()
    end

    --[[ Everything below is the optional link, and every path through it
         refuses without a password, so an unlinked client does nothing here
         but count seconds. ]]
    BZ.sendTimer = BZ.sendTimer + elapsed
    if BZ.sendTimer >= BZ.SEND_INTERVAL then
        BZ.sendTimer = 0
        BZ.DrainQueue()
    end

    if BZ.config.password and BZ.config.password ~= "" then
        BZ.beaconTimer = BZ.beaconTimer + elapsed
        if BZ.beaconTimer >= BZ.BEACON_INTERVAL then
            BZ.beaconTimer = 0
            BZ.SendBeacon()
            for name, seen in pairs(BZ.peers) do
                if (time() - (seen.time or 0)) > BZ.PEER_STALE_AFTER then
                    BZ.peers[name] = nil
                end
            end
        end
    end

    --[[ The other characters are re-read on a timer rather than watched,
         because there is nothing to watch: a file changes without telling
         anyone. Twenty seconds is far below how often a tooltip matters. ]]
    BZ.readTimer = BZ.readTimer + elapsed
    if BZ.readTimer >= BZ.READ_INTERVAL then
        BZ.readTimer = 0
        BZ.ReadOthers()
    end
end)
