from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: {label} expected once, found {count}')
    path.write_text(text.replace(old, new, 1))


ai = Path('lib/services/ai_service.dart')
replace_once(
    ai,
    "import 'dart:typed_data';\n",
    '',
    'redundant typed_data import',
)

screen = Path('lib/ui/import_screen.dart')
replace_once(
    screen,
    '    if (units == null || !mounted) return;\n',
    '    if (units == null || !context.mounted) return;\n',
    'post-quantity-dialog context guard',
)
replace_once(
    screen,
    '      if (confirmed != true || !mounted) return;\n',
    '      if (confirmed != true || !context.mounted) return;\n',
    'post-confirmation-dialog context guard',
)
replace_once(
    screen,
    '      await widget.controller.applyStockAdjustment(receiptReview);\n      if (!mounted) return;\n      ScaffoldMessenger.of(context).showSnackBar(',
    '      await widget.controller.applyStockAdjustment(receiptReview);\n      if (!context.mounted) return;\n      ScaffoldMessenger.of(context).showSnackBar(',
    'post-stock-write context guard',
)
replace_once(
    screen,
    '    } catch (error) {\n      if (mounted) showError(context, error);\n    }\n  }\n\n  @override\n  Widget build(BuildContext context) {\n    final ready =',
    '    } catch (error) {\n      if (context.mounted) showError(context, error);\n    }\n  }\n\n  @override\n  Widget build(BuildContext context) {\n    final ready =',
    'stock-receipt error context guard',
)
