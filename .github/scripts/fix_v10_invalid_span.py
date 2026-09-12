from pathlib import Path

path = Path('lib/domain/medicine_date_intelligence.dart')
text = path.read_text()
old = """      final date = parse(match);
      if (date == null) continue;
      result.add(_DateMatch(match.start, match.end, date));
      occupied.add((match.start, match.end));"""
new = """      final date = parse(match);
      if (date == null) {
        // A specific full-date pattern matched but validation failed (for
        // example 31 02 2028). Reserve the whole span so a later, looser
        // month-year pattern cannot reinterpret its tail as 02 2028.
        occupied.add((match.start, match.end));
        continue;
      }
      result.add(_DateMatch(match.start, match.end, date));
      occupied.add((match.start, match.end));"""
if text.count(old) != 1:
    raise SystemExit(f'expected one date-match anchor, found {text.count(old)}')
path.write_text(text.replace(old, new, 1))
print('invalid-date span reservation applied')
