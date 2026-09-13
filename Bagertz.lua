--[[
    Addon:       Bagertz
    Description: Shows how many of an item your OTHER characters are carrying,
                 in the item's tooltip - including characters on a different
                 WoW ACCOUNT, which is the part nothing else can do.

    Why this exists in this shape:

    Every inventory addon that offers "counts across your characters" is limited
    to one account, and not by choice. SavedVariables are written per account by
    the client, only the logged-in account's file is ever loaded, and the WoW Lua
    sandbox has no filesystem access at all - no io, no loadfile. The TOC loader
    won't escape Interface\ either (tested: it will follow ..\SomeOtherAddon\
    happily, and refuses ..\..\ out of the addon tree), so an addon cannot read
    another account's saved file by any route.

    What an addon CAN do is talk to another running client. So that's what this
    does: while you're dual-boxing, the two clients hand each other their bag
    contents over addon messages, and each one caches what it receives. The
    cross-account data therefore arrives through the game rather than the disk,
    and lands in each account's own SavedVariables naturally. Nothing has to be
    merged, linked, or hand-edited outside the game, and because each client only
    ever writes its own account's file, two clients running at once can't
    clobber each other - which a shared file on disk absolutely would.

    The trade is that a character has to be dual-boxed with you once to be
    learned. After that it stays cached and shows up offline.

    Pairing (see BZ.Tag): addon messages are broadcast to the whole PARTY/RAID,
    so a shared password decides whose data you accept and who accepts yours.
    The password itself is never transmitted - each batch carries a tag derived
    from the password plus a per-batch nonce, and the receiver recomputes it.

    IMPORTANT, and deliberately not oversold: the password gates PAIRING, not
    confidentiality. Anyone in the channel still receives the bytes. The payload
    is obfuscated with a keystream derived from the password (BZ.Crypt) so it
    isn't casually readable by someone running a message logger, but vanilla is
    Lua 5.0 with no crypto primitives and this is hand-rolled - it is
    obfuscation, not encryption. Don't treat the channel as private.

    To limit even that exposure, the bulky inventory payload is only sent after
    a correctly-tagged BEACON is heard from someone in the group (see
    BZ.SendBeacon). A beacon is a few bytes and reveals only that you run this
    addon, so sitting in a 40-man doesn't spray your bags at everyone.

    Slash commands: /bagertz (or /bz)
--]]

BZ = {}
BZ.ADDON_NAME = "Bagertz"
BZ.PREFIX     = "BAGERTZ"
BZ.VERSION    = "1.0.1"

BZ.data   = {} -- [charName] = { realm, time, bags = { [itemID] = count } }
BZ.config = {} -- { password = string, debug = bool }

-- Transport tuning. Vanilla drops you from the server for flooding addon
-- messages, so everything outbound goes through a queue drained on a timer
-- rather than being sent in a burst.
BZ.MAX_PAYLOAD       = 200  -- chars of obfuscated payload per message, well under the 255 limit
BZ.SEND_INTERVAL     = 0.4  -- seconds between outbound messages
BZ.BEACON_INTERVAL   = 20   -- seconds between beacons while grouped
BZ.SCAN_DEBOUNCE     = 2    -- seconds of quiet after a bag change before rescanning
BZ.PEER_STALE_AFTER  = 60   -- seconds before a peer is considered gone

BZ.sendQueue    = {}
BZ.sendTimer    = 0
BZ.beaconTimer  = 0
BZ.scanTimer    = nil  -- nil = no rescan pending
BZ.peers        = {}   -- [charName] = last time a valid beacon was heard
BZ.incoming     = {}   -- [charName] = { nonce, chunks, expected, name }
BZ.inventoryDirty = true

-- Session counters, so "it isn't working" can be narrowed down without guessing:
-- nothing sent means we're solo or have no password; sent but nothing received
-- means the other box isn't hearing us at all; received-but-rejected means the
-- passwords differ.
BZ.stats = { sent = 0, received = 0, rejected = 0 }

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

-- Payload characters are only ever digits, ':' and ',' (see BZ.Serialize), so a
-- rotation within that same 12-symbol alphabet keeps the message printable and
-- exactly the same length - no base64/hex expansion eating into the 255-byte
-- budget. The keystream is a small LCG seeded from password+nonce; multiplier
-- and modulus are kept tiny so the arithmetic stays exact in Lua 5.0's doubles.
--
-- Again: this is obfuscation. It stops casual reading, nothing more.
BZ.ALPHABET = "0123456789:,"
BZ.ALPHABET_LEN = 12

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
-- Scanning our own bags
-- ---------------------------------------------------------------------------------------------
function BZ.ItemIDFromLink(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

-- Bags 0-4 only for now: the bank (-1 and 5-10) is readable ONLY while the bank
-- frame is open, which needs its own "last seen at the bank" handling rather
-- than being folded in here.
function BZ.ScanBags()
    local counts = {}
    for bag = 0, 4 do
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

function BZ.UpdateOwnData()
    local me = BZ.Me()
    if not me then return end
    BZ.data[me] = {
        realm = GetRealmName(),
        time  = time(),
        bags  = BZ.ScanBags(),
    }
    Bagertz_Data = BZ.data
    BZ.inventoryDirty = true
    BZ.Debug("rescanned own bags")
end

-- ---------------------------------------------------------------------------------------------
-- Wire format
-- ---------------------------------------------------------------------------------------------

-- "id:count,id:count,..." - deliberately restricted to BZ.ALPHABET so BZ.Crypt
-- can rotate within it without changing the length.
function BZ.Serialize(counts)
    local parts = {}
    for id, count in pairs(counts) do
        table.insert(parts, id .. ":" .. count)
    end
    return table.concat(parts, ",")
end

function BZ.Deserialize(str)
    local counts = {}
    for pair in string.gfind(str, "[^,]+") do
        local _, _, id, count = string.find(pair, "(%d+):(%d+)")
        if id then counts[tonumber(id)] = tonumber(count) end
    end
    return counts
end

function BZ.Channel()
    if GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

function BZ.Queue(msg)
    table.insert(BZ.sendQueue, msg)
end

function BZ.DrainQueue()
    local msg = table.remove(BZ.sendQueue, 1)
    if not msg then return end
    local channel = BZ.Channel()
    if not channel then
        BZ.sendQueue = {}
        return
    end
    pcall(SendAddonMessage, BZ.PREFIX, msg, channel)
    BZ.stats.sent = BZ.stats.sent + 1
    BZ.Debug("sent [" .. channel .. "]: " .. string.sub(msg, 1, 60))
end

-- A beacon says "I'm here and I know the password" in a few bytes. The full
-- inventory only follows once we've heard one, so the bulky payload never goes
-- out to a group that has no paired box in it.
function BZ.SendBeacon()
    local nonce = math.random(100000, 999999)
    local tag = BZ.Tag(nonce)
    if not tag then return end
    if not BZ.Channel() then return end
    BZ.Queue("B~" .. nonce .. "~" .. tag .. "~" .. BZ.Me())
end

function BZ.SendInventory()
    local tag0 = BZ.config.password
    if not tag0 or tag0 == "" then
        BZ.Debug("no password set - refusing to send")
        return
    end
    if not BZ.Channel() then return end

    local me = BZ.Me()
    local own = BZ.data[me]
    if not own then return end

    local nonce = math.random(100000, 999999)
    -- Resolve the tag before building anything. Without this the no-password
    -- case still refused to send, but only because concatenating a nil tag into
    -- the header threw - fail-closed by accident, and a script error in the
    -- player's face rather than a silent, intended no-op.
    local tag = BZ.Tag(nonce)
    if not tag then return end

    local payload = BZ.Crypt(BZ.Serialize(own.bags), nonce, false)

    local total = math.ceil(string.len(payload) / BZ.MAX_PAYLOAD)
    if total < 1 then total = 1 end

    BZ.Queue("H~" .. nonce .. "~" .. tag .. "~" .. me .. "~" .. total)
    for i = 1, total do
        local from = (i - 1) * BZ.MAX_PAYLOAD + 1
        BZ.Queue("D~" .. nonce .. "~" .. i .. "~" .. string.sub(payload, from, from + BZ.MAX_PAYLOAD - 1))
    end
    BZ.inventoryDirty = false
    BZ.Debug("queued inventory: " .. total .. " chunk(s), " .. string.len(payload) .. " chars")
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
        BZ.peers[name] = time()
        BZ.Debug("paired beacon from " .. name)
        -- Someone we trust is here: send ours, but only if it's changed since
        -- last time or we've never met them.
        if firstSeen or BZ.inventoryDirty then
            BZ.SendInventory()
        end

    elseif kind == "H" then
        local _, _, nonce, tag, name, total = string.find(rest, "^(%d+)~(%d+)~(.+)~(%d+)$")
        if not nonce then return end
        if tag ~= BZ.Tag(nonce) then
            BZ.stats.rejected = BZ.stats.rejected + 1
            BZ.Debug("header from " .. tostring(name) .. " failed the password check - ignored")
            return
        end
        BZ.incoming[sender] = { nonce = nonce, name = name, expected = tonumber(total), chunks = {} }
        BZ.Debug("incoming inventory from " .. name .. " (" .. total .. " chunks)")

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
        local counts = BZ.Deserialize(BZ.Crypt(joined, pending.nonce, true))

        local n = 0
        for _ in pairs(counts) do n = n + 1 end

        BZ.data[pending.name] = {
            realm = GetRealmName(),
            time  = time(),
            bags  = counts,
        }
        Bagertz_Data = BZ.data
        BZ.incoming[sender] = nil
        BZ.Say("updated " .. pending.name .. "'s bags (" .. n .. " item types).")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------------------------
function BZ.CountFor(name, itemID)
    local entry = BZ.data[name]
    if not entry or not entry.bags then return 0 end
    return entry.bags[itemID] or 0
end

function BZ.AddTooltipLines(tooltip, itemID)
    if not itemID then return end

    local me = BZ.Me()
    local names = {}
    for name in pairs(BZ.data) do
        if name ~= me then table.insert(names, name) end
    end
    table.sort(names)

    local any = false
    for _, name in ipairs(names) do
        local count = BZ.CountFor(name, itemID)
        if count > 0 then
            tooltip:AddLine(name .. ": " .. count .. " in bags", 1, 0.82, 0)
            any = true
        end
    end
    if any then tooltip:Show() end
end

function BZ.HookTooltips()
    local origSetBagItem = GameTooltip.SetBagItem
    GameTooltip.SetBagItem = function(self, bag, slot)
        local ret = origSetBagItem(self, bag, slot)
        BZ.AddTooltipLines(self, BZ.ItemIDFromLink(GetContainerItemLink(bag, slot)))
        return ret
    end

    -- Explicit parameters rather than varargs throughout: Lua 5.0 exposes
    -- varargs as a local table named `arg`, which is also the name of WoW's
    -- event-argument globals, and these hooks run from inside the tooltip code
    -- path where that is an unhelpful thing to shadow.
    local origSetHyperlink = GameTooltip.SetHyperlink
    GameTooltip.SetHyperlink = function(self, link, count)
        local ret = origSetHyperlink(self, link, count)
        BZ.AddTooltipLines(self, BZ.ItemIDFromLink(link))
        return ret
    end

    local origSetLootItem = GameTooltip.SetLootItem
    if origSetLootItem then
        GameTooltip.SetLootItem = function(self, slot)
            local ret = origSetLootItem(self, slot)
            BZ.AddTooltipLines(self, BZ.ItemIDFromLink(GetLootSlotLink(slot)))
            return ret
        end
    end

    local origSetInventoryItem = GameTooltip.SetInventoryItem
    GameTooltip.SetInventoryItem = function(self, unit, slotID)
        local ret = origSetInventoryItem(self, unit, slotID)
        BZ.AddTooltipLines(self, BZ.ItemIDFromLink(GetInventoryItemLink(unit, slotID)))
        return ret
    end

    local origRefSetHyperlink = ItemRefTooltip.SetHyperlink
    ItemRefTooltip.SetHyperlink = function(self, link, count)
        local ret = origRefSetHyperlink(self, link, count)
        BZ.AddTooltipLines(self, BZ.ItemIDFromLink(link))
        return ret
    end
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

    if cmd == "password" then
        if not words[2] then
            if BZ.config.password and BZ.config.password ~= "" then
                -- Never print the password back: this prints in a chat frame that
                -- may be logged or streamed.
                BZ.Say("a password is set. Use |cFFFFFFFF/bz password <word>|r to change it, " ..
                    "|cFFFFFFFF/bz password off|r to stop sharing.")
            else
                BZ.Say("|cFFFF5179no password set|r - nothing is shared until there is one. " ..
                    "Use |cFFFFFFFF/bz password <word>|r, and set the SAME word on your other box.")
            end
        elseif string.lower(words[2]) == "off" then
            BZ.config.password = nil
            Bagertz_Config = BZ.config
            BZ.peers = {}
            BZ.Say("password cleared - sharing is off.")
        else
            BZ.config.password = words[2]
            Bagertz_Config = BZ.config
            BZ.peers = {}
            BZ.inventoryDirty = true
            BZ.Say("password set. Set the same word on your other box, group the two " ..
                "characters together, and they'll find each other.")
        end

    elseif cmd == "sync" then
        if not BZ.Channel() then
            BZ.Say("you're not in a party or raid - there's nobody to sync with.")
        else
            BZ.UpdateOwnData()
            BZ.SendBeacon()
            BZ.SendInventory()
            BZ.Say("syncing...")
        end

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

    elseif cmd == "clear" then
        BZ.data = {}
        Bagertz_Data = BZ.data
        BZ.UpdateOwnData()
        BZ.Say("cleared every cached character.")

    elseif cmd == "debug" then
        BZ.config.debug = not BZ.config.debug
        Bagertz_Config = BZ.config
        BZ.Say("debug: " .. (BZ.config.debug and "|cFF00FF7Fon|r" or "|cFFFF5179off|r"))

    elseif cmd == "selftest" then
        if not BZ.Channel() then
            BZ.Say("you're not in a party or raid - nothing to send a test through.")
        elseif not BZ.config.debug then
            BZ.Say("turn on |cFFFFFFFF/bz debug|r on BOTH boxes first, then run this again " ..
                "(the echo only prints in debug, so strangers can't spam your chat).")
        else
            BZ.Queue("T~" .. BZ.CANARY)
            BZ.Say("canary sent. The other box will print what actually arrived.")
        end

    elseif cmd == "" then
        local me = BZ.Me()

        -- Status first: this is the part that turns "it isn't working" into a
        -- specific answer.
        local channel = BZ.Channel()
        BZ.Say("password: " .. ((BZ.config.password and BZ.config.password ~= "")
            and "|cFF00FF7Fset|r" or "|cFFFF5179NOT SET|r - nothing will be shared"))
        BZ.Say("group: " .. (channel and ("|cFF00FF7F" .. channel .. "|r") or
            "|cFFFF5179solo|r - nothing will be sent until you're grouped"))

        local peerNames = {}
        for name in pairs(BZ.peers) do table.insert(peerNames, name) end
        if table.getn(peerNames) > 0 then
            BZ.Say("paired boxes heard: |cFF00FF7F" .. table.concat(peerNames, ", ") .. "|r")
        else
            BZ.Say("paired boxes heard: |cFFFF5179none|r")
        end

        BZ.Say("this session - sent " .. BZ.stats.sent .. ", received " .. BZ.stats.received ..
            ", rejected " .. BZ.stats.rejected)
        if BZ.stats.sent > 0 and BZ.stats.received == 0 then
            BZ.Say("  |cFFFF5179sending but hearing nothing|r - the other box isn't receiving, " ..
                "or isn't running this addon.")
        elseif BZ.stats.rejected > 0 and BZ.stats.rejected == BZ.stats.received then
            BZ.Say("  |cFFFF5179everything received was rejected|r - the passwords differ, " ..
                "or the message was altered in transit (try |cFFFFFFFF/bz selftest|r).")
        end

        local names = {}
        for name in pairs(BZ.data) do table.insert(names, name) end
        table.sort(names)
        BZ.Say("known characters:")
        for _, name in ipairs(names) do
            local entry = BZ.data[name]
            local types = 0
            for _ in pairs(entry.bags or {}) do types = types + 1 end
            local age = entry.time and math.floor((time() - entry.time) / 60) or nil
            BZ.Say("  " .. (name == me and "|cFF00FF7F" .. name .. " (you)|r" or name) ..
                " - " .. types .. " item types" ..
                (age and (", updated " .. age .. "m ago") or ""))
        end
        if not BZ.config.password or BZ.config.password == "" then
            BZ.Say("|cFFFF5179no password set|r - use |cFFFFFFFF/bz password <word>|r on both boxes.")
        end

    else
        BZ.Say("usage: /bz, /bz password <word>, /bz password off, /bz sync, /bz selftest, " ..
            "/bz forget <name>, /bz clear, /bz debug")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("CHAT_MSG_ADDON")

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 ~= BZ.ADDON_NAME then return end
        BZ.data = Bagertz_Data or {}
        BZ.config = Bagertz_Config or {}
        BZ.HookTooltips()
        if not BZ.config.password or BZ.config.password == "" then
            BZ.Say("loaded. |cFFFF5179No password set|r - nothing is shared yet. " ..
                "Run |cFFFFFFFF/bz password <word>|r here and on your other box.")
        end

    elseif event == "CHAT_MSG_ADDON" then
        -- arg1=prefix, arg2=message, arg3=channel, arg4=sender
        if arg1 == BZ.PREFIX then
            BZ.OnAddonMessage(arg2, arg4)
        end

    elseif event == "BAG_UPDATE" then
        -- Debounced: looting a stack fires this several times in a row, and
        -- rescanning every bag on each one is wasted work.
        BZ.scanTimer = BZ.SCAN_DEBOUNCE

    elseif event == "PLAYER_ENTERING_WORLD" then
        BZ.UpdateOwnData()

    else -- group changed
        BZ.beaconTimer = BZ.BEACON_INTERVAL -- beacon on the next tick
    end
end)

ev:SetScript("OnUpdate", function()
    local elapsed = arg1

    if BZ.scanTimer then
        BZ.scanTimer = BZ.scanTimer - elapsed
        if BZ.scanTimer <= 0 then
            BZ.scanTimer = nil
            BZ.UpdateOwnData()
        end
    end

    BZ.sendTimer = BZ.sendTimer + elapsed
    if BZ.sendTimer >= BZ.SEND_INTERVAL then
        BZ.sendTimer = 0
        BZ.DrainQueue()
    end

    BZ.beaconTimer = BZ.beaconTimer + elapsed
    if BZ.beaconTimer >= BZ.BEACON_INTERVAL then
        BZ.beaconTimer = 0
        BZ.SendBeacon()
        -- Drop peers we haven't heard from in a while so a departed box stops
        -- counting as present.
        for name, seen in pairs(BZ.peers) do
            if (time() - seen) > BZ.PEER_STALE_AFTER then BZ.peers[name] = nil end
        end
    end
end)
