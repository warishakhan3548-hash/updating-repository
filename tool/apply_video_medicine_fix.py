#!/usr/bin/env python3
"""Apply the reviewed Aaris Pharmacy video/medicine repair to a matching checkout.
Usage: python3 apply_video_medicine_fix.py [repository-directory]
Requires only Python 3 and Git. Does not build, send OCR, or push.
"""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

MANIFEST = json.loads(r'''{
  "android/app/src/main/kotlin/com/aaris/pharmacy/MainActivity.kt": {
    "before": "8409da2b4219539130bceeb288c7468ead0cfa05572f7a0616e0423277ba1038",
    "after": "54deb07cdafbeba65576cecd83bdf9c39b32d6a66b95daabce84cb140362f6f1"
  },
  "docs/CODEBASE_TREE.md": {
    "before": "62456b7b736344e33efe683056a721f1d3bd6bbb52d0a14c340d97f1c61acb39",
    "after": "7719a47c106af0b941e244d889364a1aba12faf1b3897d0485a35dd7290e7b55"
  },
  "docs/VIDEO_MEDICINE_AUDIT_2026_09_12.md": {
    "before": null,
    "after": "4d6d4a029ae3c5afd67783a33c94de93dee877c24c30fd026970fd4fe7de366b"
  },
  "lib/domain/ai_configuration.dart": {
    "before": null,
    "after": "11a153535f68486f44b439c3b75295a149b45c4cee093c3c7d62b99055a356f7"
  },
  "lib/domain/medicine_intake.dart": {
    "before": "000f621446a9b7cb38a467b6fba7b281e5a818bada6703c2bf479c617fe705d0",
    "after": "1a445802324ce4fcc82d3cd6cddc0913b4e62a313d8068e83f252b0c44201b08"
  },
  "lib/domain/medicine_understanding.dart": {
    "before": "ab7ea2a2040d39e2292c1f3fdf60fc3d992d540e5695a23d29217b9cb0fcf4fa",
    "after": "f6bb58483f2e31ecc36bc9c162cb57517b6ff93da0e49d5fc9084b1a18d901a6"
  },
  "lib/services/ai_service.dart": {
    "before": "a17d59fd676ed320f3a40b1c0e85e5b8f10ab15541225ded4772bf4a424072b5",
    "after": "08e9de71807064168fb2cc6dcd35237df9442ebe0049a7b11d0cf4d1634870f0"
  },
  "lib/services/cloud_scan_ai_service.dart": {
    "before": "da4260b3dda655bb65e6a2bdbc606f1da80f5d662aceead17885efd8c8c9a4f5",
    "after": "2614f6108d009bb2681d4c44a99f54181f24a56b7cdc275250a32ebf99a0538f"
  },
  "lib/services/media_import_service.dart": {
    "before": "df3b308307507fb1d0be611f1f9034fb8407c85bd16cf96bb85ae32a1f675c94",
    "after": "4e0581dbfa581f6c72a1994b5a6b7c7dc1f65a389fc0aad970ed4f0a39d46586"
  },
  "lib/services/medicine_intake_service.dart": {
    "before": "8a3a478c837bdd13d91e312b4d8e79fa6683f298ff8a8ecc43e3c9f9ffeadd9f",
    "after": "6109433d1e9bba1016ae4d9ac20e395998e5700279c4f2ee5b6fdf834b5cb63a"
  },
  "lib/ui/medicine_intake_panel.dart": {
    "before": "e1eadc6a61dca1dbfa1ff4082dc281338b5ee4966fd2c5e8182d2bf2c3c1f6d3",
    "after": "a3f7e379976191a5a5e9a305a0a54414c649c8b5222c4ae364b8094b4fa6541a"
  },
  "test/cloud_scan_bounds_test.dart": {
    "before": null,
    "after": "410d4988249f204f90e238779bfb851202234c39020712072f9cec942eba401f"
  },
  "test/medicine_intake_concurrency_test.dart": {
    "before": "0ed557ec90a1e4cb3891aedda61ef68c75bb1c4f3d70df7c38d64751512a8696",
    "after": "fc7dd5b8907d43b5dd602f32daed46fd45e5e073289aa1d504da607738794ed9"
  },
  "test/video_medicine_contract.dart": {
    "before": null,
    "after": "3c29eb213daf07eba77168675a594062786f88f06e84767f50cc9b1004ad1b86"
  },
  "test/video_medicine_test.dart": {
    "before": null,
    "after": "d2e2fb5c9f340915578d38014fec6d24151f5ed732be7cb57ee2b869bbf11f3f"
  },
  "test/video_sampling_contract_test.dart": {
    "before": null,
    "after": "d82f08b611d24f526fcdb1d2df6c5f8caebf8189510b0ae17eb0f5ef57590568"
  },
  "tool/check_video_medicine.dart": {
    "before": null,
    "after": "d9e9f6c17735f74e0fe19e8e06d9de9e94df64e3b8da40c3baadcc1aef322246"
  }
}''')
PATCH = zlib.decompress(base64.b64decode(
    'eNrtvdt228a2KPjur0C8szfJiATvN8mStyzLiU7ky7KUZO3l6MggUJQQkwAXAFpWHJ3H/oD+mX7vT+kv6XmpKhRuFGV77R6juz1G'
    'IgmoKlTNmveac5bnz+dWq3XlJ5bTdgIvCn2v7axW7Thy20vHD9ofwmQBP9xw2XacyI/bq2snWjrubfslvD50E/+jn9zaHxJr9pUD'
    'PPIDT3yyeiN36rndiSccdzocdabT2XjuDHuj/rjf7fa6nf5k1O95A9vuTWfeaOKN5pORK7zRaNjrik6/M/c6A2c473d6bt+Zj7oD'
    'q9vpjAaDR61W66tX+WhnZ+frV/qf/2m1+uPmyNqB/08t+NNdOHFsme2sXevFYp0kIlJP6g3r8yML/60i/6OTCOujE1krEXh+cHUu'
    'PiVvRbxeJLvWS5Fch97RtRMEYmHz06fWvhWsF4vKAV4Kz3e+ZISFtboOkxC6RL4bP1vHt9DwMAmXvvssDBfCCepzZxGLxqMd7Nhu'
    'W4fWcydKrMRfinCdWF4oYisIE8t1AlcsrMCB9QrLE26IE7Otn4VYWWEgH4nICm8CEenh1kHiLyxA4Ug4i8Wt5UUAxtiKQ+stzOkW'
    'h8XR4wQ/Gn4U0QK2DQa2Zn6ydFbWTRh9WISOF9s8pLm0j74nwjNnuYKdvdq0NovBgsNH0MearwPLDYO5f7WOhNzI4+DKD0R9bv6l'
    'd5n/1FuM/+L1SkT2NqM0CKW6nW6z27F2up1BE9D+wWhV9S+i/bdhZWFUf+wHABjfuyTQPG5aj3/FX6yVk1xbfmwt/TjGXYM3iC2N'
    '+4ZO1lHwn7FIJMrBDv4E1LWA/a3sdMf7VPbPn1v17wqbBjBcrpxIHAbemUh4y5pWEq1FAxe/s/3iaejLGYyJKz+/FoAt4qMfrmNG'
    'FcAywFUAQww4ubDmfuDH14TEjIvxdRgli9sUOjtfCp2dauhUjnd+DSTi3bfdOM97muA/JI955CyBePetGKEtCBPqiAlNa+l8ekFv'
    'AfgicsVJUO82rXGv0XjUum/oaB28Dn7x1XTVHsRr1xVxXOevNjbhwYNGstMBNw52B6wkca+tOiHDrnX8yRWrxA+Dxjbwyk3l/g4F'
    '7GMi7/ZRcHR7nebk25G4+Q8Rs7ld88b9ze7ZpDukEWLbn+/fzSJhx4qc75nJhp29s0ky1CtGuGOo9/rNLoK932v2/vtY6wk/kLzl'
    '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'
    'fo76o3F3ZNvzft8d90aj/mTccd3OfNwbd3pud+70RsPe0J073mDQn83GxRPxyimk5+CVTeiUqTnGM6Zmt4+yiwvpWjVEcudK7M65'
    'nsslV1m5lFVW2uWPaVDMZciPgll0bfwft8BYaPyrpCWVgbxcLdZxO/1Vj/toR7W37Y057OYkMk3Blk9CN1xsaEXOhctNbam4wqUs'
    '93WZA6rZUA+Vb/CoVZVS36pOqW9tTqlvlabUt6pS6lslKfWtbVLqW5xS33pgSn3rvpT6FjbZkFLfKk+pb5Wk1LfKU+pbhZT61saU'
    '+lZlSn1r65T61n0p9a2tU+pb1Sn1rW+RUs9BrLQNW6TUt6pT6ltlKfWt6pT6Vj6lvvWQlPoWqeKtr06pb1Wk1Le+IqW+9cCU+tYX'
    'pdS3HpBS3/q6lPqW9gURnmRT6ltfllLf+mYp9aZ+vimlvvUVKfWtb5RS38pdMFdMqW89KKW+9eCUemMvCycsW6bUtypT6ltbpNS3'
    'NqfUt7ZKqW9Vp9S3NqbUb4F2BlD/VSn15ZuQTalv0fM7Krm0rfbzyFIahrxGg7Vm/Wf9M+ljRwu68+TFOuATm8ZTLJgGj14wM71r'
    'bNCJqe7hJWawXt6jHle3lJrysO918Sq7wXw8m3jTqTOejGejSWfoeaD9zmbupOfMJrO5bXcG0864K0bTSb8/mQ/Hc8/rDpzRfDjv'
    '94ajiejMXXc2G3U3aMobZlOiNG9oTf4fcryz2/3heu9D1M58W5qSrGW5ofGG8Ffo0NJKbUFLfYiy/QjM67b1Bm97cm9b+iI7Koyp'
    'JtCS5b/VNQE2deLktk4TjBD4f3dgwrFEc8bP6JtDOKW+Le990IExtvWarl6SV6VyQFKMsUBhkN60wJfQNXnIOFT1cKXeKcu1UUVT'
    '4zYt2Su2FX0V76th1lJ8vj3FtTj36TLzHPOmMn+DQDcGtANxQ66Esg+zi2Grz8ssi+dKAVeFWs9lKeJ9ySpVg7qszL1r9YcNVYVq'
    '18JapFFSz/c+0P1sLIlsZJhcFj+Ue2K0fThgtGArB0JuSCN3RAMiP0GZOYq1GnxXAkUZwjAlWQj1jAzkM35c51OkbJcMPXHUZU3V'
    '7bMd3868r6kE30mzC2yn1+83+4bPuRQZKRDHiW8DN+s4wUqz6DN5hj+fYZk8EdXR3jISC1TGCheS3sfsc0JO58aRt/hIVwrVo2Zn'
    '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'
    '/OI7ug1FfPKTo9CTt3MBKv/fKHxuIw=='
))

def main():
    requested = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
    lookup = subprocess.run(['git', '-C', str(requested), 'rev-parse', '--show-toplevel'],
                            capture_output=True, text=True)
    if lookup.returncode:
        raise SystemExit('Choose an existing Git checkout of Aaris Pharmacy.')
    root = Path(lookup.stdout.strip()).resolve()
    states = []
    divergent = []
    for name, hashes in MANIFEST.items():
        target = root / name
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents if parent != root):
            raise SystemExit('Refusing a symlinked patch target: ' + name)
        digest = hashlib.sha256(target.read_bytes()).hexdigest() if target.is_file() else None
        if digest == hashes['after']:
            states.append('after')
        elif digest == hashes['before'] and (digest is not None or not target.exists()):
            states.append('before')
        else:
            divergent.append(name)
    if divergent:
        raise SystemExit('No files changed. These targets differ from the reviewed base:\n' + '\n'.join(divergent))
    if all(state == 'after' for state in states):
        print('The complete repair is already applied; no files changed.')
        return
    if any(state == 'after' for state in states):
        raise SystemExit('No files changed. This checkout has a partial repair; review it before applying.')
    checked = subprocess.run(['git', '-C', str(root), 'apply', '--check', '--binary', '-'],
                             input=PATCH, capture_output=True)
    if checked.returncode:
        raise SystemExit('No files changed. Git rejected the patch:\n' + checked.stderr.decode(errors='replace'))
    applied = subprocess.run(['git', '-C', str(root), 'apply', '--binary', '-'], input=PATCH)
    if applied.returncode:
        raise SystemExit('Git could not apply the repair. Inspect git diff before retrying.')
    for name, hashes in MANIFEST.items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != hashes['after']:
            raise SystemExit('Post-apply verification failed for ' + name)
    print('Applied and verified all %d source, test and documentation files. No build or push was run.' % len(MANIFEST))

if __name__ == '__main__':
    main()
