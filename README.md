# Bagertz (v1.3.0)

Shows how many of an item your **other characters** are carrying, right in the item's tooltip — including characters on a **different WoW account**, which is the part nothing else does.

For WoW 1.12 (vanilla).

## Why other addons can't do this

Every inventory addon that offers "counts across your characters" is limited to one account, and not by choice:

- SavedVariables are written **per account** by the client, and only the logged-in account's file is ever loaded into memory.
- The WoW Lua sandbox has **no filesystem access at all** — no `io`, no `loadfile`, nothing that opens a path.
- The TOC loader **won't escape `Interface\`**. It'll happily follow `..\SomeOtherAddon\file.lua` into a sibling addon, but refuses to go up and out of the addon tree. (Tested directly, not assumed — `WTF` lives outside `Interface\`, so that's the end of that route.)

So while you're logged in on one account, the other account's data isn't merely unreadable — it was never loaded. No addon can reach it.

## What this does instead

An addon can't read the other account's *file*, but it can talk to the other *running client*. So while you're dual-boxing, the two clients hand each other their bag contents over addon messages, and each caches what it receives.

The cross-account data therefore arrives **through the game rather than off the disk**, and lands in each account's own SavedVariables naturally. Nothing has to be merged, symlinked, or hand-edited outside the game.

That also makes it safe for dual-boxing specifically. The obvious alternative — pointing both accounts at one shared file with a hardlink or directory junction — silently destroys data: each client holds its whole SavedVariables table in memory and rewrites the entire file on exit, so whichever client closes **last** overwrites the other one's entire session. Here, each client only ever writes its own account's file, so two clients running at once can't collide.

A sync hands over **every character on the account**, not just the one logged in. Each account keeps a roster of the characters that have played on it, so when the two boxes meet, each one delivers its whole roster on the other's behalf - your alts do not have to be online, or ever have been dual-boxed, to show up in tooltips. They only need to have logged in once on their own account so their bags were recorded.

Characters learned from the other box are never relayed onward. Each account is the sole authority on its own characters, which means there are no echoes to arbitrate between and no way for a stale copy to overwrite a fresh one.

## Pairing, and what the password actually protects

Addon messages are broadcast to everyone on the channel, so a shared password decides whose data you accept and who accepts yours. Set the same word on both boxes:

```
/bz password <word>
```

**The password itself is never transmitted.** Each batch carries a tag derived from the password plus a per-batch nonce, and the receiver recomputes it. A listener sees a tag that changes every batch, not your passphrase.

**Be clear about what this is:** the password gates **pairing, not confidentiality.** Anyone in the channel still receives the bytes. The payload is obfuscated with a keystream derived from the password so it isn't casually readable by someone running a message logger, but vanilla is Lua 5.0 with no crypto primitives and this is hand-rolled — it is **obfuscation, not encryption**. Don't treat the channel as private.

Two things limit the exposure anyway:

- **It fails closed.** No password set means nothing is broadcast at all, rather than falling back to sharing with everyone.
- **The bulky payload only goes out to a paired box.** Clients periodically send a tiny *beacon*; the full inventory is only sent once a correctly-tagged beacon has been heard. A beacon reveals only that you run this addon, so sitting in a 40-man doesn't spray your bags at everyone in it.

In the normal dual-boxing case your two characters are in a party by themselves, so a PARTY broadcast reaches exactly your other box and nobody else.

### Party and guild

Beacons go out on every channel you can reach - party or raid, and guild if you are in one - so the two boxes can find each other **without being grouped**. The inventory itself is different: it goes only to the channel a paired box was actually heard on. Being in a large guild therefore does not mean every sync reaches the whole guild; once your other box has answered in the party, that is where the data goes.

Turn the guild channel off with `/bz guild off` if you would rather the boxes only find each other while grouped.

## Usage

Set the same password on both boxes, put the two characters in a party, and they'll find each other within about 20 seconds. Then hover any item.

```
/bz                     status, plus every known character and when each was updated
/bz account <name>      label this account (see below) - do this on each box
/bz password <word>     set the shared secret (same word on both boxes)
/bz password off        stop sharing entirely
/bz guild on|off        whether the boxes may find each other via guild chat
/bz sync                force a sync right now instead of waiting
/bz selftest            prove whether the channel delivers messages intact
/bz forget <name>       drop one cached character
/bz clear               drop every cached character
/bz debug               verbose logging, for working out why a sync is not happening
```

`/bz password` with no argument tells you *whether* one is set — it never prints it back, since chat frames get logged and streamed.

### What a tooltip looks like

```
Salahaja: 6 in bags, 40 in bank (46)
Salabeard: 5 in bags
```

Your own character is listed first and in green, since it's usually what you're comparing against. Bags and bank are shown separately with a combined total, and a location with none of the item is simply omitted rather than padded with a zero.

### Account labels

**This is optional.** Everything works without it, and the lines above are what you get: just character names. It exists because WoW gives addons **no way to read your account name**: it is only ever a folder name on disk, so if you want an account shown, the word has to come from you.

It is set per account, not per character, so it is one command per box and every character on that account inherits it. The names are yours to pick - match your WTF folders if that is clearer:

```
/bz account SALAHAJA
/bz account SALAMAHI
```

### If nothing is syncing

`/bz` leads with a status block — whether a password is set, which channels are reachable, which paired boxes have been heard, and per-session counts of messages sent, received and rejected. Those counts localise the problem: sending with nothing received means the other box isn't hearing you, while receiving where everything is rejected means the passwords differ.

`/bz selftest` (with `/bz debug` on both boxes) sends a canary containing every character class the wire format depends on, and the other box prints what actually arrived next to what was sent. That's there because the first working version *wasn't* — the format used `|` as its field separator, which is WoW's own escape character for `|c`/`|r`/`|H`, and the chat pipeline mangled it. Every message was dropped in silence. The separator is now `~`.

## Known limitations

- **Bank counts are a snapshot from the last bank visit.** Bank contents are readable only while the bank frame is open - away from a bank those containers report nothing at all. So the bank is scanned while you stand there and then kept. A character who has not visited a bank since installing this shows no bank count until they do.
- **A character must have logged in once with this addon installed** before it has anything to share. It does not need to be online, or dual-boxed with you - the account sends it on its behalf - but a character that has never played with Bagertz has no recorded bags.
- **Both boxes need this addon.** It syncs with itself, not with Bagnon or Bagshui.
- **Mail attachments, the auction "sell" slot and outgoing mail show no counts.** Vanilla gives no item link for those three - only a name and a texture - so identifying the item would need a name-to-item catalogue this addon does not keep. They show nothing rather than something wrong.
- **The counts are a snapshot** taken when the other box last sent, not a live feed. It re-sends when its bags change and it can see a paired box.

## Development

`tools/` runs the addon's logic on a desktop Lua, outside the game. It isn't shipped in the release zip and the client never loads it.

```
lua tools/vanilla_lint.lua Bagertz.lua
lua tools/test_sync.lua
lua tools/test_tooltips.lua
```

`vanilla_lint.lua` checks the source against what 1.12 actually runs — any Lua you can install today is 5.4 while vanilla is 5.0, so `#`, `%`, `goto`, `//` and bitwise operators all parse cleanly and then throw a script error in-game.

`test_sync.lua` loads the addon **twice into two separate environments**, so "client A" and "client B" are genuinely two independent copies, and hands messages between them the way the server would. It covers the parts that are expensive to debug while playing and that fail silently or corruptingly: the obfuscation round-trip, chunk reassembly, message size staying under vanilla's 255-byte limit, that the password never appears on the wire, and — most importantly — that a client with the **wrong** password is ignored completely.

The suite is mutation-checked: removing the password gate, reversing the decrypt direction, or oversizing the chunks each make it fail. That's also how a real flaw was caught before release — the no-password case *looked* fail-closed, but was actually refusing to send by throwing a Lua error rather than returning cleanly.

## Author

Built for [Salahaja](https://github.com/Salahaja).
