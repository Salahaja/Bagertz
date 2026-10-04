# Bagertz (v2.2.1)

Shows how many of an item your **other characters** are carrying, right in the item's tooltip — including characters on a **different WoW account**, which is the part nothing else does.

For WoW 1.12 (vanilla), on a client with Nampower.

## Why other addons can't do this

Every inventory addon that offers "counts across your characters" is limited to one account, and not by choice:

- SavedVariables are written **per account**, under `WTF/Account/<ACCOUNT>/`. The account name is *in the path*, which is exactly why one account can never see another's — and only the logged-in account's file is ever loaded.
- The WoW Lua sandbox has **no filesystem access at all** — no `io`, no `loadfile`, nothing that opens a path.
- The TOC loader **won't escape `Interface\`**. It'll happily follow `..\SomeOtherAddon\file.lua` into a sibling addon, but refuses to go up and out of the addon tree. (Tested directly, not assumed.)

## What this does instead

`CustomData/` has **no account in its path**. It is one folder per *installation*, and Nampower hands Lua `WriteCustomFile` / `ReadCustomFile` to read and write in it. Two clients launched from the same install share that folder, whatever accounts they are logged into. That is the whole mechanism.

Each character writes one file of its own, `Bagertz_<Realm>_<Character>.txt`, and reads everyone else's. Nothing is ever written by two clients at once, so there is no contention to arbitrate — which a single shared file would have had, and which is why this is not one. A roster file is appended to once per login so a client knows which files exist, since Lua cannot list a directory.

The realm is in the file name because the folder belongs to the installation, not the realm: two characters called Bob on two realms get two files. Only characters on the realm you are playing are read — nothing on another realm can be reached from here anyway.

### Setup

None. Log a character in and it appears. Log another in — on either account — and each sees the other.

## Gold across accounts

Each character's file carries its gold too, so **`/bz gold`** lists the gold of every character on this realm, from every account on this install, each with its account's label, and adds it all up.

If you use **Bagshui**, hover the gold in its bag window. Below Bagshui's own list of this account's characters you get your **other account's** characters, and an **All accounts** total. Bagshui's own files are not changed, so updating Bagshui can't undo it. Nobody it already lists is listed twice, and a linked partner's characters aren't counted — that's their gold, not yours.

A character's gold is recorded the next time it logs in with Bagertz 2.1 or later, and kept current from then on.

## Only what changed

Bagertz is woken by `BAG_UPDATE`, `PLAYER_MONEY`, `PLAYERBANKSLOTS_CHANGED` and
the bank frame opening and closing. None of those events says *what* changed,
or even whether anything did: `BAG_UPDATE` fires several times for a single
loot, `PLAYER_MONEY` fires when a vendor pays you the copper you just spent,
and opening the bank rescans the lot.

Up to 2.1 each of those was a full rewrite of your character's file, which
every other character on the machine then re-read and re-parsed in full, every
twenty seconds, forever. With a link set up it was also a rebroadcast of that
character's entire inventory, chunked into as many 255-byte messages as it
took, every few seconds for as long as you kept moving things about.

2.2 does the same work from the differences:

- **Your file is only rewritten when its contents changed.** Not its
  timestamp, not the order items came back in — the contents. Rearranging your
  bags without gaining or losing anything writes nothing.
- **Another character's file is only parsed when its bytes changed.** Reading
  it is unavoidable, since Lua here cannot ask when a file was last modified,
  but comparing one string beats rebuilding a few hundred item rows.
- **A linked partner is sent the difference**, not the inventory. One looted
  item is a header and one chunk, whatever else you are carrying. Nothing
  moved means nothing sent at all.
- **The beacon stops shouting at your guild** once your partner has answered
  somewhere narrower. It used to go to every channel you were on for as long
  as you were logged in.

Both of the file halves rest on the same property: identical contents have to
produce identical bytes, or the writer sees a change where there is none and
the reader re-parses a file that never moved. Item lines are therefore written
in a deliberate order rather than whatever order the table happened to iterate
in.

### Why a difference needs a serial number

A difference only means anything applied to the state it was measured against.
A transfer that goes missing cannot simply be shrugged off: every count after
it would be adjusted from the wrong starting point and would look perfectly
reasonable while being wrong, which is the worst way for an inventory addon to
fail.

So every transfer carries a number. A receiver that sees a gap asks for the
whole thing again rather than guessing, and one that sees an older transfer
arrive late — which two channels of different speeds will eventually produce —
ignores it rather than putting back a count that has already been superseded.
`/bz sync` forces the same full resend by hand, though it should not be needed.

**The wire format changed, so both ends have to be on 2.2.** A box still
running 2.1 is refused rather than half-understood, and Bagertz now says so in
chat instead of only in its debug log — the symptom otherwise is a partner
whose counts quietly stop moving, which looks like nothing at all. The shared
folder format did **not** change; 2.1 and 2.2 on one machine read each other's
files fine.

## The folder outranks the channel

Your own accounts share the folder and need no link at all. But the link can be
switched on as well, and when it is, each client relays what it read from the
folder to the other — right for a partner on another PC who has no folder
access, an echo between two accounts on one machine.

Applying that echo would be expensive. **The wire format carries bags and bank
but no gold**, so a character learned from the channel has no trustworthy
figure and is left out of `/bz gold` by design. Letting the echo mark your own
characters as channel-sourced would make your other account's gold vanish from
the report in the same breath as the "updated N character(s)" message.

So a character you can read out of your own folder is never replaced by what
the channel says about it. The folder is local truth, written by the character
itself, and strictly more complete than anything the wire can carry.

The read cache has to agree. It skips re-parsing a file whose bytes have not
changed, so its test for that is not merely whether the character is still in
memory but whether what is in memory still came from the file — otherwise
anything that overwrote an entry would leave the one file that would put it
right skipped forever. A demoted entry is restored on the next read.

### `/bz unlink` with a leftover password

The pre-2.0 sync was switched on by typing a password, so an upgraded client
can hold one with no partner record beside it. The password is what actually
enables the channel — every send path checks it, nothing checks the partner
record — so such a client goes on broadcasting, while `/bz unlink` returned
early and said "not linked to anyone". There was no way to stop it from the UI.
It now clears the password whether or not a partner was ever recorded.

## What the folder replaced, and why

Bagertz used to hand its bags to the other client over **addon messages**. Those are broadcast to a whole PARTY or GUILD, so it needed:

- a shared password to decide whose data to accept,
- a keystream to obfuscate the payload from everyone else in the channel,
- chunking to fit inside 255 bytes,
- beacons to discover a paired box,
- a roster negotiation to deliver alts who weren't online.

None of that was the feature. All of it existed to survive a hostile channel, and it cost ~400 lines and a setup step that had to be performed identically on both boxes before anything worked at all.

A file on your own disk is read by nothing but the clients already running on it. So: **no password, no pairing, no obfuscation, no grouping requirement.** And because the data is on disk rather than in flight, a character doesn't have to be online to be counted — the file it wrote last Tuesday is still there, which addon messages could never do.

That machinery survives in one place only: the opt-in link below, for the one case a folder cannot reach.

## Sharing with someone on another PC

The folder only reaches clients on your own machine. For a partner, there is an
optional link — **off until you set one up**, and nothing is broadcast until
then:

    /bz share <character>

That generates a random password, whispers them an offer, and applies the same
password to both sides once they accept. They get a popup asking first, because
an addon that linked on arrival would let anyone who whispers you start
receiving your bag contents.

The secret travels by **whisper**, not by addon message — addon messages are
broadcast to a whole party or guild, so handing a password over one would give
it to everyone present. That is not secrecy from the server, which sees
everything either way; it is secrecy from the twenty people standing next to
you. The payload itself is obfuscated, not encrypted: vanilla is Lua 5.0 with
no crypto primitives. Don't treat the channel as private.

`/bz sharing` opens a window showing who you are linked to and on what account,
with an Unlink button. `/bz unlink` does the same from chat, and tells the
other end so they stop sending.

You are only linked while you are both in the same party or guild — that is
where addon messages travel.

## Commands

| Command | What it does |
| --- | --- |
| `/bz` | Status: the folder, your file, and every character known |
| `/bz read` | Re-read the folder now; with a link, also resend everything (also `/bz sync`) |
| `/bz gold` | Every character's gold on this realm, from every account, and the total |
| `/bz account <name>` | Label this account, shown beside its characters — on your other account too |
| `/bz zero on\|off` | Whether a tooltip says so when nobody holds the item |
| `/bz forget <name>` | Drop one character, e.g. one you deleted; it stays gone unless it logs in again |
| `/bz stale` | Drop only characters with neither a file nor a link behind them (post-upgrade leftovers) |
| `/bz clear` | Drop this realm's cached characters; anything with a file returns at once |
| `/bz share <character>` | Offer to link with someone on another PC |
| `/bz sharing` | Who you are linked to, with an Unlink button, and your version |
| `/bz unlink` | Stop sharing, and tell them |
| `/bz tips` | Trace which tooltip hooks fire |
| `/bz debug` | Verbose logging |

## Development

    lua tools/vanilla_lint.lua Bagertz.lua   # 1.12 / Lua 5.0 compatibility
    lua tools/test_files.lua                 # two clients, one shared folder
    lua tools/test_pairing.lua               # linking two PCs, and unlinking
    lua tools/test_tooltips.lua              # what the tooltip actually says
    lua tools/test_gold.lua                  # gold across accounts, and Bagshui's gold tooltip
