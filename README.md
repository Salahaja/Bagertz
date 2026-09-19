# Bagertz (v2.0.0)

Shows how many of an item your **other characters** are carrying, right in the item's tooltip — including characters on a **different WoW account**, which is the part nothing else does.

For WoW 1.12 (vanilla), on a client with Nampower.

## Why other addons can't do this

Every inventory addon that offers "counts across your characters" is limited to one account, and not by choice:

- SavedVariables are written **per account**, under `WTF/Account/<ACCOUNT>/`. The account name is *in the path*, which is exactly why one account can never see another's — and only the logged-in account's file is ever loaded.
- The WoW Lua sandbox has **no filesystem access at all** — no `io`, no `loadfile`, nothing that opens a path.
- The TOC loader **won't escape `Interface\`**. It'll happily follow `..\SomeOtherAddon\file.lua` into a sibling addon, but refuses to go up and out of the addon tree. (Tested directly, not assumed.)

## What this does instead

`CustomData/` has **no account in its path**. It is one folder per *installation*, and Nampower hands Lua `WriteCustomFile` / `ReadCustomFile` to read and write in it. Two clients launched from the same install share that folder, whatever accounts they are logged into. That is the whole mechanism.

Each character writes one file of its own, `Bagertz_<Character>.txt`, and reads everyone else's. Nothing is ever written by two clients at once, so there is no contention to arbitrate — which a single shared file would have had, and which is why this is not one. A roster file is appended to once per login so a client knows which files exist, since Lua cannot list a directory.

### Setup

None. Log a character in and it appears. Log another in — on either account — and each sees the other.

## What v2.0.0 removed, and why

Bagertz used to hand its bags to the other client over **addon messages**. Those are broadcast to a whole PARTY or GUILD, so it needed:

- a shared password to decide whose data to accept,
- a keystream to obfuscate the payload from everyone else in the channel,
- chunking to fit inside 255 bytes,
- beacons to discover a paired box,
- a roster negotiation to deliver alts who weren't online.

None of that was the feature. All of it existed to survive a hostile channel, and it cost ~400 lines and a setup step that had to be performed identically on both boxes before anything worked at all.

A file on your own disk is read by nothing but the clients already running on it. So: **no password, no pairing, no obfuscation, no grouping requirement.** And because the data is on disk rather than in flight, a character doesn't have to be online to be counted — the file it wrote last Tuesday is still there, which addon messages could never do.

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
| `/bz read` | Re-read the folder now (also `/bz sync`) |
| `/bz account <name>` | Label this account, shown beside its characters |
| `/bz zero on\|off` | Whether a tooltip says so when nobody holds the item |
| `/bz forget <name>` | Drop one cached character |
| `/bz stale` | Drop only characters with no file behind them (post-upgrade leftovers) |
| `/bz clear` | Drop everything cached; anything with a file returns at once |
| `/bz share <character>` | Offer to link with someone on another PC |
| `/bz sharing` | Who you are linked to, with an Unlink button |
| `/bz unlink` | Stop sharing, and tell them |
| `/bz tips` | Trace which tooltip hooks fire |
| `/bz debug` | Verbose logging |

## Development

    lua tools/vanilla_lint.lua Bagertz.lua   # 1.12 / Lua 5.0 compatibility
    lua tools/test_files.lua                 # two clients, one shared folder
    lua tools/test_pairing.lua               # linking two PCs, and unlinking
    lua tools/test_tooltips.lua              # what the tooltip actually says
