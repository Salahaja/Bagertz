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
BZ.config = {} -- { debug = bool, showZero = bool, account = string }

-- One file per character, plus a roster so they can be found. Lua cannot list
-- a directory, so a name that never announced itself can never be read.
BZ.ROSTER_FILE   = "Bagertz_roster.txt"
BZ.FILE_PREFIX   = "Bagertz_"
BZ.FILE_MAGIC    = "BAGERTZ1"

BZ.SCAN_DEBOUNCE = 2    -- seconds of quiet after a bag change before rescanning
BZ.READ_INTERVAL = 20   -- seconds between re-reading the other characters
BZ.WRITE_MIN_GAP = 5    -- seconds between writes of our own file

BZ.scanTimer     = nil  -- nil = no rescan pending
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

    if cmd == "read" or cmd == "sync" then
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

    elseif cmd == "clear" then
        BZ.data = {}
        Bagertz_Data = BZ.data
        BZ.UpdateOwnData()
        BZ.Say("cleared every cached character.")

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

        BZ.Say("account label: " .. ((BZ.config.account and BZ.config.account ~= "")
            and ("|cFF00FF7F" .. BZ.config.account .. "|r")
            or "|cFF888888none (optional - /bz account <name>)|r"))

        local names = {}
        for name in pairs(BZ.data) do table.insert(names, name) end
        table.sort(names)
        BZ.Say("known characters:")
        for _, name in ipairs(names) do
            local entry = BZ.data[name]
            local types = 0
            for _ in pairs(entry.bags or {}) do types = types + 1 end
            local age = entry.time and math.floor((time() - entry.time) / 60) or nil
            local label
            if name == me then
                label = BZ.DisplayName(name) .. " |cFF888888(this character)|r"
            elseif entry.mine then
                -- Written by us on an earlier login; still ours to rewrite.
                label = BZ.DisplayName(name) .. " |cFF888888(this account)|r"
            else
                label = BZ.DisplayName(name) .. " |cFF888888(from the folder)|r"
            end
            BZ.Say("  " .. label ..
                " - " .. types .. " item types" ..
                (age and (", updated " .. age .. "m ago") or ""))
        end
        if table.getn(names) <= 1 then
            BZ.Say("|cFF888888Only this character so far. Log another one in " ..
                "from this same install and it will appear.|r")
        end

    else
        BZ.Say("usage: /bz, /bz read, /bz account <name>, /bz zero on|off,")
        BZ.Say("       /bz forget <name>, /bz clear, /bz tips, /bz debug")
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
        end
    end

    -- A write held back by the rate limit still has to happen.
    if BZ.writePending and
       (not BZ.lastWrite or (time() - BZ.lastWrite) >= BZ.WRITE_MIN_GAP) then
        BZ.writePending = nil
        BZ.WriteOwn()
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
