#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).with_name('aaris_atomic_work_command_cleanup.py')
text = path.read_text(encoding='utf-8')
ambiguous = '''    ("      if (mounted) showError(context, error);", "      if (context.mounted) showError(context, error);"),\n'''
if text.count(ambiguous) != 1:
    raise RuntimeError('cleanup tuple anchor changed unexpectedly')
text = text.replace(ambiguous, '', 1)
anchor = '''# Modernize persistent CI to the runner-supported Node 24 action generation and\n'''
addition = '''# Patch only the catch belonging to _receiveExactLot; the same short catch text\n# appears elsewhere in ImportScreen and must remain untouched by this cleanup.\nimport_path = ROOT / "lib/ui/import_screen.dart"\nimport_text = import_path.read_text(encoding="utf-8")\nold_receive_tail = """      ScaffoldMessenger.of(context).showSnackBar(\n        SnackBar(\n          content: Text(\n            'Received $units units into ${live.title}. Inventory audit history was saved.',\n          ),\n        ),\n      );\n    } catch (error) {\n      if (mounted) showError(context, error);\n    }\n  }\n\n  @override\n  Widget build(BuildContext context) {\n"""\nnew_receive_tail = old_receive_tail.replace(\n    "if (mounted) showError(context, error);",\n    "if (context.mounted) showError(context, error);",\n)\nif import_text.count(old_receive_tail) != 1:\n    raise RuntimeError("import_screen.dart: exact receive-lot catch anchor changed")\nimport_path.write_text(\n    import_text.replace(old_receive_tail, new_receive_tail, 1),\n    encoding="utf-8",\n)\n\n'''
if text.count(anchor) != 1:
    raise RuntimeError('CI anchor changed unexpectedly')
text = text.replace(anchor, addition + anchor, 1)
path.write_text(text, encoding='utf-8')
print('Cleanup anchor made function-specific.')
