# MendeLedger

A WoW Forever addon that keeps Auctionator's scan prices long after Auctionator forgets them, and lets you search and graph that history.

Auctionator keeps prices for its last 21 days (its "price history days" option), one low, high and quantity per day. MendeLedger copies every day into its own ledger, packed small, so the history keeps growing for as long as you like. It can also keep **every scan** with its time, so you can see how prices move during the day.

## Features

- **Records automatically**: a few seconds after you close the auction house, after each scan, and shortly after login (which catches scans made while MendeLedger was off; nothing inside Auctionator's 21-day window is lost).
- **Scan detail** (new in 0.2.0): every full or summary scan Auctionator makes is kept with its time: the lowest buyout and how many are on sale. The 24H, 3D and 7D ranges then show each scan instead of one point per day, and a full scan that didn't list an item (sold out) breaks the line and shows up in the records as "not on sale".
- **Window laid out like Looking For Work** (`/mendel`):
  - **Left**: search box (item name or item ID), **Filter** menu, and every recorded item grouped under collapsible item-type bars, with its latest price, 7-day change or days recorded on the right
  - **Right**: the price graph (lowest-buyout line, low–high band, quantity bars; hover any point for its prices), range buttons (24H, 3D, 7D, 30D, 90D, 1Y, All), a summary (latest price, change, lowest, highest, average, average quantity, days or scans recorded) and the records, newest first
  - Up to 7 days, a **View** switch under the graph chooses between each scan and one point per day
  - The bar at the top shows on how many days since it was first seen the item was recorded
  - Shift-click an item to link it in chat; with the search box selected, shift-click an item in your bags to search for it
- **Options tab**: Record Now, Import Realms, automatic recording on/off, scan detail on/off and how long to keep it (7, 14 or 30 days), compression on/off, how long to keep daily history, storage used, the realms in the ledger, and a client check that shows which game features this build provides
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

## Prices by time of day (scan detail)

Auctionator's saved data has one entry per item per day, so on its own it can't show how a price moved during the day. MendeLedger therefore watches Auctionator's scans as they happen: both full scans and summary scans hand their results to `Auctionator.Database:ProcessScan`, and MendeLedger hooks that call (after Auctionator has done its own work, changing nothing). For each item in each scan it keeps the time, the lowest buyout and the total on sale.

To get a point every 30 minutes:

1. In Auctionator's options, turn on its **autoscan** and set the interval to **30** minutes.
2. Auctionator starts an autoscan **when you open the auction house** and the interval has passed; it does not repeat while the window stays open. So scans happen as often as you open the auction house (or press Auctionator's scan button). Full scans have a 15-minute cooldown.
3. Open MendeLedger, pick an item and choose **24H**, **3D** or **7D**.

Notes:
- Only scans made while MendeLedger is running are kept; Auctionator doesn't save them.
- A search for a few items is a partial scan: it adds points for those items but says nothing about the others. Only full scans can show an item was sold out.
- The single-item price checks on Auctionator's Selling tab don't go through `ProcessScan`, so they reach the daily ledger but not the scan detail.
- Ranges of 30 days and more always use the daily ledger.

## How recording works

- Prices are read from Auctionator's own price database, never changed. While you play that is `Auctionator.Database.db`; other realms are read from `AUCTIONATOR_PRICE_DATABASE`, where Auctionator keeps them packed.
- For each item and day MendeLedger keeps what Auctionator keeps: the lowest and highest minimum buyout seen that day and the most units seen, plus the latest minimum buyout.
- Only "today" changes in Auctionator's data, so each realm remembers the last day that was already final when it was recorded. Later recordings only merge newer days. Merging is idempotent: recording or importing twice never counts anything twice.
- All work happens in the background, about 5 ms per frame, and pauses during combat.

## Storage and compression

- Each item's history is one string of compact numbers: about **6–7 bytes per item per day**. On a live Forever realm with 6,938 items and 12 days (49,862 daily prices) the ledger is about 354 KB, against about 2.4 MB as plain Lua tables and 1.07 MB in Auctionator's own packed form.
- Every 128 recorded days of an item become a **sealed block** that normal recording never rewrites. A sealed block is compressed only when that makes it **at least 10% smaller**. With the game's built-in Deflate this saved 14–27% in tests; on short histories compression saves almost nothing, so it isn't used there.
- Without the game's Deflate (`C_EncodingUtil`), nothing is compressed: LibCompress's pure-Lua codecs never reached the 10% bar on 128-day blocks in testing, so trying would only cost CPU.
- **Keep Daily History** (Forever, 2 years, 1 year, 180 or 90 days) removes old prices a sealed block at a time, so up to 128 extra days can remain.
- **Scan detail** uses the same format (scan number in place of the day), about 5–6 bytes per item per scan before compression and roughly half that once sealed with Deflate. Scanning 5,000 items every 30 minutes around the clock would add about 0.5–0.7 MB a day, so 14 days (the default) is around 7–10 MB; scanning only while you play costs far less. Scan detail older than 7, 14 or 30 days is removed, a sealed block (128 scans of an item) at a time.
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
| `/mendel scans on` / `off` | keep every Auctionator scan, for prices by time of day |
| `/mendel keepscans <7, 14 or 30>` | how many days of scan detail to keep |
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
- No combat log, no secure snippets, no protected calls, and no unit data at all. The scan hook is a `hooksecurefunc` post-hook on Auctionator's own (insecure) table; it never runs before or instead of Auctionator's code. Values from game APIs (item names, realm names, links) pass through `issecretvalue` guards before anything compares, prints or does arithmetic with them.
- The only protected UI it touches is the Blizzard Settings panel ("Open MendeLedger" button), and closing it waits until combat ends.
- Startup steps are isolated: if the minimap button or Settings entry fails on a new build, recording still runs.

## When the interface number changes

Every line that depends on the client build, or on Auctionator internals, is tagged `-- RETEST`. Search for it (`findstr /n RETEST *.lua` on Windows), and run `/mendel probe` in game: it reports the interface number, Deflate, graph lines, item loading, the scan events, Auctionator's version and price-database format, and the realm key.

## Libraries and licences

| Library | Used for | Licence |
|---|---|---|
| LibStub, CallbackHandler-1.0 | library loading | Ace3 licence (BSD-style, `Libs/Ace3-LICENSE.txt`) |
| LibDataBroker-1.1, LibDBIcon-1.0 | minimap button | see each library |
| LibCompress r87 | Deflate through the game's `C_EncodingUtil` | GNU GPL v2 (`Libs/LibCompress/LICENSE`) |

LibCompress is licensed under the GPL v2. If you publish MendeLedger, check that the licence you publish it under is compatible with that.

The libraries are unmodified copies of the releases they came from; the `local addonName, ns = ...` first line applies to MendeLedger's own files.
