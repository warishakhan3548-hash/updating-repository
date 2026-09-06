from pathlib import Path

path = Path("test/android_build_contract_test.dart")
text = path.read_text(encoding="utf-8")
old = "      expect(mainActivity.indexOf(system), lessThan(mainActivity.indexOf(onDevice)));"
new = (
    "      expect(\n"
    "        mainActivity,\n"
    "        contains('if (preferOnDeviceAfterProviderFailure && isOnDeviceRecognitionUsable())'),\n"
    "      );\n"
    "      expect(\n"
    "        mainActivity,\n"
    "        contains('} else if (SpeechRecognizer.isRecognitionAvailable(this)) {'),\n"
    "      );"
)

if new in text:
    print("Adaptive provider contract already aligned; no changes needed.")
elif text.count(old) == 1:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Adaptive provider contract aligned with accuracy-first + failure-failover architecture.")
else:
    raise SystemExit(
        f"Expected exactly one legacy provider-order assertion, found {text.count(old)}."
    )
