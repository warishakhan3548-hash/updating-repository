from pathlib import Path

source = Path('tool/one_shot_scan_ai_router_upgrade.py')
text = source.read_text(encoding='utf-8')
old = r'''    """    expect(
      scanAutoSaveDecision(
        draft,
        resolution,
        verifier: ScanAutoSaveVerifier.localAi,
      ).allowed,
      isTrue,
    );
  });
""",
'''
new = r'''    """    expect(
      scanAutoSaveDecision(draft, resolution, verifier: ScanAutoSaveVerifier.localAi).allowed,
      isTrue,
    );
  });
""",
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f'upgrade matcher hotfix expected one anchor, found {count}')
text = text.replace(old, new, 1)
exec(compile(text, str(source), 'exec'), {'__name__': '__main__'})
