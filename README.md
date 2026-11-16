# MendeLedger

A GUI for seeing Auctionator price history.

Auctionator only remembers the last 21 days of prices (by default). MendeLedger keeps every day Auctionator scans, so you can look up an item's price history over months instead of weeks, and graph how it moves, even hour by hour.

## Features

- Keeps the daily lowest price, highest price and quantity of every item Auctionator scans, for as long as you like
- Optional scan detail: keeps every Auctionator scan with its time, so you can see how prices change during the day
- Search every recorded item by name or item ID, grouped by item type
- Price graph with ranges from 24 hours to all time; hover any point to see its prices
- A summary for the chosen range: latest price, change, lowest, highest and averages
- Shift-click an item to link it in chat
- Import the prices your other characters have scanned on other realms
- Minimap button and an entry in the addon compartment

## Requirements

- World of Warcraft: Forever
- [Auctionator](https://www.curseforge.com/wow/addons/auctionator): MendeLedger records the prices Auctionator scans

## Installation

**With the CurseForge app:** install MendeLedger from its CurseForge page.

**By hand:** copy the `MendeLedger` folder into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

If MendeLedger doesn't show up in the AddOns list, restart the game completely.

## Getting started

1. Open the auction house and let Auctionator scan.
2. Close the auction house. A few seconds later MendeLedger records the prices and says so in chat.
3. Type `/mendel`, search for an item and click it.

The first time, you immediately get every day Auctionator still remembers (up to 21 days). From then on, the history keeps growing.

## Seeing prices during the day

MendeLedger can keep every scan Auctionator makes, with its time. To get a new point about every 30 minutes:

1. In Auctionator's options, turn on **autoscan** and set the interval to **30** minutes.
2. Auctionator scans when you **open the auction house** and the interval has passed. It doesn't scan again while the window stays open, so you get a point each time you visit the auction house (or press Auctionator's scan button). Full scans can be made once every 15 minutes.
3. In MendeLedger, pick an item and choose **24H**, **3D** or **7D**.

Good to know:

- Only scans made while MendeLedger is enabled are kept.
- A gap in the line means the item wasn't on sale when a full scan ran. The records list shows it as "not on sale".
- Searching for a few items adds points for those items only.
- Price checks on Auctionator's Selling tab count toward the daily prices, not the scan detail.
- Scan detail is kept for 14 days (you can choose 7, 14 or 30). Daily prices are kept for as long as you choose.
- Use the **View** button under the graph to switch between each scan and one point per day.

## The window

**Left side**
- Search box: type part of an item's name, or an item ID. With the search box selected, shift-click an item in your bags to search for it.
- **Filter**: sort by name, latest price, 7-day change or days recorded; show only items seen in the last 7 days or with 2 or more days of prices; group by item type; expand or collapse all item types.
- The item list, grouped under item-type bars. Click a bar to open or close it.

**Right side**
- The graph:
  - Gold line: lowest buyout
  - Shaded column: lowest to highest price in that day (or group of scans)
  - Brown bars: how many were on sale
- Range buttons: 24H, 3D, 7D, 30D, 90D, 1Y and All.
- **Summary**: latest price, change over the range, lowest, highest, average price, average quantity, and how many days or scans were recorded.
- **Daily Records** (or **Scans** in scan view): every day or scan in the range, newest first.

The bar above the graph shows on how many days the item has been recorded since it was first seen.

## Options tab

Click the gear tab on the right edge of the window.

- **Recording**: record automatically after auction house scans; **Record Now**; **Import Realms** records the prices Auctionator has saved for all your realms.
- **Scan Detail**: keep every Auctionator scan, and for how long (7, 14 or 30 days).
- **Compression**: saves disk space. It's best to leave it on.
- **Keep Daily History**: Forever, 2 years, 1 year, 180 days or 90 days.
- **Display**: show the minimap button; print a line in chat after each recording.
- **Storage**: how much space your history uses.
- **Realms**: click a realm to view its prices, or **Forget** a realm's history (Auctionator's own data is not touched).
- **Client**: shows which game features MendeLedger found. Useful when reporting a problem.

## Commands

| Command | What it does |
|---|---|
| `/mendel` | open or close the window |
| `/mendel <text>` | open the window and search for an item |
| `/mendel record` | record Auctionator's prices now |
| `/mendel import` | record every realm Auctionator has prices for |
| `/mendel realms` | list the realms in your history |
| `/mendel realm <name>` | show another realm's prices |
| `/mendel keep <days or forever>` | how long to keep daily prices |
| `/mendel scans on` / `off` | keep every Auctionator scan, or only daily prices |
| `/mendel keepscans <7, 14 or 30>` | how many days of scan detail to keep |
| `/mendel compress on` / `off` | turn compression on or off |
| `/mendel repack` | apply the compression setting to history you already have |
| `/mendel stats` | how much space your history uses |
| `/mendel minimap` | show or hide the minimap button |
| `/mendel options` | open the Options tab |
| `/mendel reset` | move the window back to the middle of the screen |
| `/mendel probe` | check which game features MendeLedger found |
| `/mendel forget` | forget the history of the realm being shown (asks first) |
| `/mendel help` | list these commands in game |

## Disk space

MendeLedger stores prices compactly. On a realm with about 7,000 items, the first 12 days of daily prices take roughly 0.35 MB.

Scan detail takes more. Scanning every 30 minutes all day can add about half a megabyte a day on a busy realm, which is why it's only kept for 14 days by default. If your saved data grows too large, choose a shorter **Keep Daily History** or **Scan Detail** setting.

## Troubleshooting

**Nothing is recorded.** Make sure Auctionator is enabled and has scanned the auction house, then close the auction house or type `/mendel record`.

**Items show as "Item #12345".** Item names are loaded from the server and appear after a short while.

**"No scans of this item in this range."** Scan detail only exists for scans made while MendeLedger was enabled. The daily view is shown instead.

**The minimap button is gone.** Type `/mendel minimap`.

**The window is off the screen.** Type `/mendel reset`.

**Something stopped working after a game or Auctionator update.** Type `/mendel probe` and include what it shows when you report the problem on the CurseForge page, along with your MendeLedger and Auctionator versions.

## Credits

Made by MendeleevForever. MendeLedger is not made by or affiliated with the Auctionator team or Blizzard Entertainment.

MendeLedger includes these libraries, with their licences in the `Libs` folder:

- LibStub and CallbackHandler-1.0 (Ace3 licence)
- LibDataBroker-1.1 and LibDBIcon-1.0
- LibCompress (GNU GPL v2)
