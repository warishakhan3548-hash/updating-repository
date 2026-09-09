#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / 'lib/domain/medicine_entry_prefill.dart'
text = path.read_text(encoding='utf-8')

replacements = [
    (
        r"r'(?:exp|expiry|एक्सपायरी)\s*[:=]?\s*([0-9०-९]{4}[-/][0-9०-९]{2}(?:[-/][0-9०-९]{2})?)'",
        r"r'(?:^|[^A-Za-z0-9\u0900-\u097f])(?:exp|expiry|एक्सपायरी)(?=\s|[:=])\s*[:=]?\s*([0-9०-९]{4}[-/][0-9०-९]{2}(?:[-/][0-9०-९]{2})?)'",
    ),
    (
        r"r'(?:mfg|manufacturing|manufactured|एमएफजी)\s*[:=]?\s*([0-9०-९]{4}[-/][0-9०-९]{2}(?:[-/][0-9०-९]{2})?)'",
        r"r'(?:^|[^A-Za-z0-9\u0900-\u097f])(?:mfg|manufacturing|manufactured|एमएफजी)(?=\s|[:=])\s*[:=]?\s*([0-9०-९]{4}[-/][0-9०-९]{2}(?:[-/][0-9०-९]{2})?)'",
    ),
    (
        r"r'(?:(?:qty|quantity|मात्रा)\s*[:=]?\s*([0-9०-९]{1,9})(?:\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))?|([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))'",
        r"r'(?:^|[^A-Za-z0-9\u0900-\u097f])(?:qty|quantity|मात्रा)(?=\s|[:=])\s*[:=]?\s*([0-9०-९]{1,9})(?:\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))?'",
    ),
    (
        "value: (match) => match.group(1) ?? match.group(2) ?? '',\n  );\n  if (quantityLabelPresent",
        "value: (match) => match.group(1) ?? '',\n  );\n  if (quantityLabelPresent",
    ),
    (
        r"r'(?:unit\s+price|price|rate|कीमत|रेट)\s*[:=]?\s*₹?\s*(\d{1,9}(?:\.\d{1,2})?)(?![0-9.])'",
        r"r'(?:^|[^A-Za-z0-9\u0900-\u097f])(?:unit\s+price|price|rate|कीमत|रेट)(?=\s|[:=])\s*[:=]?\s*₹?\s*([0-9०-९]{1,9}(?:\.[0-9०-९]{1,2})?)(?![0-9०-९.])'",
    ),
    (
        "final priceText = priceRaw == null ? '' : priceRaw;\n  if (priceText.isNotEmpty) parseMoney(priceText);",
        "final priceText = priceRaw == null ? '' : _asciiDigits(priceRaw);\n  if (priceText.isNotEmpty) parseMoney(priceText);",
    ),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'Expected one safety patch anchor, found {count}: {old[:80]}')
    text = text.replace(old, new, 1)

path.write_text(text, encoding='utf-8')
print('Hardened explicit quick-intake fact boundaries.')
