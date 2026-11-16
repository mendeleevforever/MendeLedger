# MendeLedger

A WoW Forever addon that keeps Auctionator's scan prices long after Auctionator forgets them, and lets you search and graph that history.

Auctionator keeps prices for its last 21 days (its "price history days" option). MendeLedger copies every day into its own ledger, packed small, so the history keeps growing for as long as you like.

## Features

- **Records automatically**: a few seconds after you close the auction house, after a full scan arrives, and shortly after login (which catches scans made while MendeLedger was off; nothing inside Auctionator's 21-day window is lost).
- **Window laid out like Looking For Work** (`/mendel`):
  - **Left**: search box (item name or item ID), **Filter** menu, and every recorded item grouped under collapsible item-type bars, with its latest price, 7-day change or days recorded on the right
  - **Right**: the price graph (daily low line, low–high band, quantity bars; hover any day for its prices), range buttons (7D, 30D, 90D, 1Y, All), a summary (latest price, change, lowest, highest, average low, average quantity, days recorded) and the daily records, newest first
  - The bar at the top shows on how many days since it was first seen the item was recorded
  - Shift-click an item to link it in chat; with the search box selected, shift-click an item in your bags to search for it
- **Options tab**: Record Now, Import Realms, automatic recording on/off, compression on/off, how long to keep history, storage used, the realms in the ledger, and a client check that shows which game features this build provides
- **Minimap button and addon compartment entry**: left-click opens the window, right-click records now

## Installation

Copy the `MendeLedger` folder into your client's AddOns folder:

- Beta client: `World of Warcraft\_classic_beta_\Interface\AddOns\MendeLedger\`
- Live client: `World of Warcraft\_forever_\Interface\AddOns\MendeLedger\`

Restart the client completely if the new folder doesn't show up in the AddOns list. Auctionator must be installed and enabled for new prices to be recorded; the ledger still opens without it.

## Getting started

1. Open the auction house and let Auctionator scan (a full scan, or your usual searches).
2. Close the auction house. A few seconds later MendeLedger records the prices.
3. Type `/mendel`, search for an item and click it.
4. To pull in realms your other characters have scanned, press **Import Realms** on the Options tab (or `/mendel import`).

## How recording works

- Prices are read from Auctionator's own price database, never changed. While you play that is `Auctionator.Database.db`; other realms are read from `AUCTIONATOR_PRICE_DATABASE`, where Auctionator keeps them packed.
- For each item and day MendeLedger keeps what Auctionator keeps: the lowest and highest minimum buyout seen that day and the most units seen, plus the latest minimum buyout.
- Only "today" changes in Auctionator's data, so each realm remembers the last day that was already final when it was recorded. Later recordings only merge newer days. Merging is idempotent: recording or importing twice never counts anything twice.
- All work happens in the background, about 5 ms per frame, and pauses during combat.

## Storage and compression

- Each item's history is one string of compact numbers: about **6–7 bytes per item per day**. On a live Forever realm with 6,938 items and 12 days (49,862 daily prices) the ledger is about 354 KB, against about 2.4 MB as plain Lua tables and 1.07 MB in Auctionator's own packed form.
- Every 128 recorded days of an item become a **sealed block** that normal recording never rewrites. A sealed block is compressed only when that makes it **at least 10% smaller**. With the game's built-in Deflate this saved 14–27% in tests; on short histories compression saves almost nothing, so it isn't used there.
- Without the game's Deflate (`C_EncodingUtil`), nothing is compressed: LibCompress's pure-Lua codecs never reached the 10% bar on 128-day blocks in testing, so trying would only cost CPU.
- **Keep History** (Forever, 2 years, 1 year, 180 or 90 days) removes old prices a sealed block at a time, so up to 128 extra days can remain.
- Rough growth: a realm with about 5,000 items scanned every day adds roughly 10–12 MB a year before compression. Choose a Keep History limit if you play on many realms.

## Commands

| Command | What it does |
|---|---|
| `/mendel` | open / close the window |
| `/mendel <text>` | open the window and search for an item |
| `/mendel record` | record Auctionator's prices now |
| `/mendel import` | record every realm Auctionator has prices for |
| `/mendel realms`, `/mendel realm <name>` | list the realms in the ledger, show another one |
| `/mendel keep <days or forever>` | how long to keep history |
| `/mendel compress on` / `off` | compress sealed history (when it saves 10% or more) |
| `/mendel repack` | re-store sealed history to match the compression setting |
| `/mendel stats` | storage used |
| `/mendel minimap` | show / hide the minimap button |
| `/mendel options` | open the Options tab |
| `/mendel reset` | move the window back to the middle of the screen |
| `/mendel probe` | check which game features this client provides |
| `/mendel forget` | forget the shown realm's history (asks first) |

## WoW Forever rules it follows

- `## Interface: 16001`, Lua 5.1 only, no `require`/`io`/`os`; every Lua file starts with `local addonName, ns = ...`.
- SavedVariables (`MendeLedgerDB`) are created only in `ADDON_LOADED` for this addon and merged onto defaults.
- One event frame with a handler table; no OnUpdate polling (background work uses `C_Timer`).
- No combat log, no secure snippets, no protected calls, and no unit data at all. Values from game APIs (item names, realm names, links) pass through `issecretvalue` guards before anything compares, prints or does arithmetic with them.
- The only protected UI it touches is the Blizzard Settings panel ("Open MendeLedger" button), and closing it waits until combat ends.
- Startup steps are isolated: if the minimap button or Settings entry fails on a new build, recording still runs.

## When the interface number changes

Every line that depends on the client build is tagged `-- RETEST`. Search for it (`findstr /n RETEST *.lua` on Windows), and run `/mendel probe` in game: it reports the interface number, Deflate, graph lines, item loading, the scan events, Auctionator's version and price-database format, and the realm key.

## Libraries and licences

| Library | Used for | Licence |
|---|---|---|
| LibStub, CallbackHandler-1.0 | library loading | Ace3 licence (BSD-style, `Libs/Ace3-LICENSE.txt`) |
| LibDataBroker-1.1, LibDBIcon-1.0 | minimap button | see each library |
| LibCompress r87 | Deflate through the game's `C_EncodingUtil` | GNU GPL v2 (`Libs/LibCompress/LICENSE`) |

LibCompress is licensed under the GPL v2. If you publish MendeLedger, check that the licence you publish it under is compatible with that.

The libraries are unmodified copies of the releases they came from; the `local addonName, ns = ...` first line applies to MendeLedger's own files.
