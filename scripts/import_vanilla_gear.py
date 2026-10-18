"""Refresh the offline, fixed-stat Vanilla pre-raid catalog from Wowhead Classic.

Run from the repository root. Only factual item data is stored; tooltip prose
and guide text are not copied. No third-party Python dependencies are required.
"""

import concurrent.futures
import html
import json
from pathlib import Path
import re
import urllib.request

SLOTS = {
    "head": [13866, 18727],
    "neck": [12103, 18691],
    "shoulder": [11782, 18681],
    "back": [11623, 13386],
    "chest": [14152, 14153, 14136, 14340],
    "wrist": [18497, 16683, 16697],
    "hands": [13253, 13870],
    "waist": [11662, 13956, 18740],
    "legs": [13170, 9484],
    "feet": [11822, 18735, 18102],
    "ring": [942, 13001, 12543, 12545],
    "trinket": [12930, 13968],
    "main_hand": [13964, 17719, 944],
    "off_hand": [11904],
    "wand": [13938, 13396],
}
ENDPOINT = "https://nether.wowhead.com/classic/tooltip/item/{id}"
PATTERNS = {
    "armor": r"(\d+) Armor",
    "spell_power": r"Increases damage and healing done by magical spells and effects by up to (\d+)",
    "spell_hit": r"Improves your chance to hit with spells by (\d+)%",
    "spell_crit": r"Improves your chance to get a critical strike with spells by (\d+)%",
}
for school in ("Shadow", "Fire", "Frost"):
    PATTERNS[school.lower() + "_power"] = (
        rf"Increases damage done by {school} spells and effects by up to (\d+)"
    )
for school in ("Shadow", "Fire", "Frost", "Arcane", "Nature"):
    PATTERNS[school.lower() + "_resistance"] = rf"\+(\d+) {school} Resistance"
for attribute in ("Stamina", "Intellect", "Spirit", "Strength", "Agility"):
    PATTERNS[attribute.lower()] = rf"\+(\d+) {attribute}"


def parse_item(slot, item_id, data):
    # Set tooltips contain bonuses for pieces that are not equipped. Discard
    # the entire set block before searching for passive item stats.
    passive = re.split(r'<span class="q"><a href="/classic/item-set=', data["tooltip"])[0]
    text = " ".join(html.unescape(re.sub(r"<[^>]+>", " ", passive)).split())
    stats = {}
    for key, pattern in PATTERNS.items():
        match = re.search(pattern, text)
        if match:
            stats[key] = int(match[1])
    item = {
        "id": item_id,
        "name": data["name"],
        "slot": slot,
        "stats": stats,
        "quality": data["quality"],
        "icon": data["icon"],
        "unique": bool(re.search(r"\bUnique\b", text)),
        "url": f"https://www.wowhead.com/classic/item={item_id}",
    }
    if item_id in (14152, 14153):
        item["class"] = "frost_mage" if item_id == 14152 else "warlock"
    if item_id == 944:
        item["two_hand"] = True
    if any(marker in text.lower() for marker in ("use:", "chance on hit:", "when struck")):
        item["effect_note"] = "Use/proc effect is not simulated."
    if item_id == 13386:
        item["name"] += " (base stats only)"
        item["effect_note"] = "Random enchantment not included."
    return item


def fetch_item(pair):
    slot, item_id = pair
    with urllib.request.urlopen(ENDPOINT.format(id=item_id), timeout=30) as response:
        return parse_item(slot, item_id, json.load(response))


def main():
    pairs = [(slot, item_id) for slot, item_ids in SLOTS.items() for item_id in item_ids]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        items = list(executor.map(fetch_item, pairs))
    catalog = {
        "version": "Vanilla level 60 / fixed-stat pre-raid candidates (includes Dire Maul)",
        "sources": [
            "https://www.icy-veins.com/wow-classic/mage-dps-pre-raid-gear",
            "https://www.icy-veins.com/wow-classic/warlock-dps-pre-raid-gear",
        ],
        "item_source": ENDPOINT,
        "items": items,
    }
    # Finish all requests before replacing the checked-in catalog.
    destination = Path(__file__).resolve().parents[1] / "data" / "vanilla_gear.json"
    destination.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"Imported {len(items)} Vanilla items into {destination}")


if __name__ == "__main__":
    main()
