#!/usr/bin/env python3
"""Replay the Aaris UI/AI accuracy upgrade without overwriting other edits.

Usage: python apply_ui_ai_accuracy_upgrade.py --repo /path/to/repository [--check]
The complete patch is embedded. Requires Python 3 and Git; uses no network.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

BASE_COMMIT = "1187a8e78fc644f543430572610cd344b881c5d2"
PATCH_SHA256 = '98c7aeaadacd2cb1b2ec52519b6e21d0dbd5e3643fe2019099274acb401a9e45'
MANIFEST = json.loads('{"docs/UI_AI_ACCURACY_2026_09_15.md": {"after": "f1b6de46afe7297af9aea0bec02e9e6fcfeed3355674105e356a011efe5ebe1e", "before": null}, "lib/app.dart": {"after": "55af6972acacda096536edb19267637d1b9b2c511d67998f47845b650d3bc9ad", "before": "f679fa7c62110300977b372e9ee908f5346cde92bcbb2f7cab1619545d751730"}, "lib/domain/local_ai_protocol.dart": {"after": "aa901579cfe9ebfcc42e3cb42348f8c04778567b721b837bc90ca00f9f4cd315", "before": "d32327156e01e9e2e3b0c0aae11d7356804a32a86810074138b05f5fca0be9d2"}, "lib/domain/medicine_resolution_v2.dart": {"after": "95da1eb43e272a3ec357fa3b9dfa4b98774978177f32b3da386e2bdfd905701c", "before": "7ca53c55b034b498a6285942f0ce712f32ada23d550db4aa632f5c5c4077cb20"}, "lib/domain/medicine_scan_commit.dart": {"after": "edf2e012e3245b3501b9939408571cb9db4860921a4c173bc31256853faa76d1", "before": "f8c2e3c8f1aac546815a10bd7c36cc30d71281f35e0ce305af4a0f05e21150c1"}, "lib/domain/medicine_semantic_roles.dart": {"after": "49a6c3ff3c3172fd6793279b80108715260ed5871d9038b927303b343d7a9c79", "before": "1ecc10b11603ed0fd0856d36f6401c7583be62f72d55b78a6c78b2fc98dc865b"}, "lib/domain/medicine_strength.dart": {"after": "26f69e4f30e0cb94f294a0a4ddfe3dc7d52ab6e85a86b4079956bd61ab80e84e", "before": null}, "lib/domain/medicine_understanding.dart": {"after": "dc7b1f5db9f2921267955a54ac34b80d7cfd368a7dbcead9c1f360c22b4aed0b", "before": "56d74b9c073a68745dc28dc0b90ca4b12515a7adffec3f6e546df10d4aa05ea5"}, "lib/main.dart": {"after": "832bd2c51c00e6e13dafaa8994664b60502506428dcc009e2803535f78732656", "before": "35588644069afe111b080bfd36654a064bdc9fd8b1a5d0e163444607da81395c"}, "lib/services/local_ai_runtime.dart": {"after": "1cda014210b360a1cc5a16a496f23f6ab09db79f65f8a1dec53513718af66dd5", "before": "46da7b892a37bdea0b580f94a22704bf83c308c67b2d62479058e9e32f33d7e5"}, "lib/ui/ai_screen.dart": {"after": "06b0bd8367ea0c5f3b6e9c524aca5766d80c7dc23695cdb3a5f483fefd990c01", "before": "2e425de974357630e08350b3d60582cae07552e08ede4829cc2bb91902b5ea2c"}, "lib/ui/design.dart": {"after": "653777354555bf69ae5aa11de9c314ca3441a9eaf2755d31d4c6e561ef9db51f", "before": "74b0915ce04319eaf6a75a796109238fcbff3a0d95ec0f56ae737e91da848acf"}, "lib/ui/home_screen.dart": {"after": "0b99cdb8026f68b085384389c2221fd7431102d0328f3afec5cd3ea9fe142557", "before": "2692369621bba925a6222e93167ea3946ecba504f79322635bb92192a010694b"}, "lib/ui/scanner_view.dart": {"after": "b93a70e55dd587439755bebfe7d26cd87cf5722b94010f84a0db447531f8e5e0", "before": "c1b185c3c8524074f48b7bd8b5cb58f793d5e920cf7a7a39538bb783aa4d6219"}, "test/app_test.dart": {"after": "17c96063afb73c92a02e8d01e1415416442c061904d1fd88c7742a4fe9060acd", "before": "e4d6135909a045a4de03dcf93ac0d4d7c537bc4b3e61f8e37c1e9cb2d9bbcfbd"}, "tool/check_local_ai_error_drain.dart": {"after": "68a27f168f0f374aa79f148f0185a4f2051659c2234bc8067f4efe3925f96d1b", "before": null}, "tool/check_scan_accuracy.dart": {"after": "a15985dda88956412772b3599a9bb1a611561db957fbdbf45b55ac1f6c839e3d", "before": null}}')
PATCH_DATA = (
    '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'
    'OOGbtlOYPwTFDVV4IS983vk6fLBnVv5s9fZGpH+wtCpJBZnza32VkKTjKqov5kqlTFpE+4zpLpFumfpwFSdNFFjSrUyRxNJ3nB+y'
    'kiiL7n99wpQpaK7UtiEDrdfx7a4Ham+8PzGHh76KWopVOUZv/UsM/L0zkM3DMQY7460ts3N88QcmQmHg+5kUnpPYgRui/Y8YqHkE'
    'l5vDK9Fwe9OFS1ECraHWSKqYF9ZMCknXq1xqe6hwPno6R168zHQVO3LV0f1RgEE5lRDiLjptQG/EpUu2mlcZ/HzzUiPCFZL3gHqq'
    'f1ZHNo1mdrf2bPn5bVh3HGL3miPLdwWtpjdg8SwMA+7VBxF8EMvVUh14g6RHXuQxX15XuAD4iB1mSXAcCSgWg/dax+/Yw8Wh7YzR'
    'F2LV5m6vGTmGLLlXnxMyTJjBHxnGxdVlxDrs6JbmzRQN6/Tuujq8k6tYomwpTlO6wk2vmvw2dnd5/bLiXrOskspNtoCShdk1nawb'
    'sNpoqbSr2hlFWWtCQMoMZa9FLm+j83NIueh1JZSrk9LqjapBtzaVCUYayCWE2R3LMJgFhVzAW8XktuJOw6AF+aLt6QHucNnRMNI3'
    'Rh09Z2Vtw4bbgfpWNFb+hy+L+tLqtMYEiAt3NgOuOrtp8FbX39/OTe3v7Y52J+vc1A29W/7pyc629k+fIcd9hrOz/NLz4CPScEqF'
    '8mgLB7CbGSq/A3XK5waIUDEtNFFHZ39w1vigxecrpwmMxxdwMYtncf0SoXL7hRwCuoA5xTA8zPHiw+S2HxEskICD7Laf4LnLBMvl'
    'eebeIlpO2W4ZFJ5e9tSutmFCd+rrW27RfhHz5VOTlVKytXkUeUVIC+hZIO3p0fMXgJ3UvSC8NsNoQomPlkjapR+ncu8t2mP0R+P0'
    'rNveXGmuY2a0OvGj8ycyY8Cb0zhZuJkJ1Oku+BvyvpQ+kUnqI16YxQJq0TzDYm/zTDtd0zhPZvDlJ/79hA7RUwVGMqtqX3dZQvgh'
    'qjC6rVaAte7zRHSuT8YwPygb+VbpCIpgYeGIihegM01QQOEhcRc5d/VgdwePeuHrM7y+zM/cRRzW28gEO8Vcq03Qq4/dvMbYaVbu'
    '4QvG91FTqhwJ56gbxQtPPtLtx76nIUUx3JqvhrCxEq7r15w5cz4IdqCc/e3a+zRfIlWB4tj4KXDpzPcOdM50v83bxs6GxL1+TT4i'
    '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'
    'G0Am'
)

def run_git(repo, *args, data=None):
    result = subprocess.run(["git", "-C", str(repo), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", "replace").strip())
    return result.stdout


def digest(repo, relative):
    path = repo / relative
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents
                                if parent != repo and repo in parent.parents):
        raise RuntimeError("Refusing a symlink target: " + relative)
    if not path.resolve().is_relative_to(repo):
        raise RuntimeError("Target escapes repository: " + relative)
    if not path.exists():
        return None
    if not path.is_file():
        raise RuntimeError("Target is not a regular file: " + relative)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--check", action="store_true", help="Verify without writing")
    args = parser.parse_args()
    repo = args.repo.expanduser().resolve()
    top = Path(run_git(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if top != repo:
        raise RuntimeError("--repo must name the repository root: " + str(top))
    patch = zlib.decompress(base64.b64decode(PATCH_DATA))
    if hashlib.sha256(patch).hexdigest() != PATCH_SHA256:
        raise RuntimeError("Embedded patch integrity check failed.")
    current = {name: digest(repo, name) for name in MANIFEST}
    if all(current[name] == facts["after"] for name, facts in MANIFEST.items()):
        print("Upgrade already applied. No files changed.")
        return
    changed = [name for name, facts in MANIFEST.items()
               if current[name] != facts["before"]]
    if changed:
        raise RuntimeError("Affected files differ from the expected source. Nothing changed.\n"
                           + "\n".join(changed))
    # Git verifies all hunks before applying; never use --reject or force/reset.
    run_git(repo, "apply", "--check", "--whitespace=error", "-", data=patch)
    if args.check:
        print(f"Ready: {len(MANIFEST)} files verified. No files changed.")
        return
    run_git(repo, "apply", "--whitespace=error", "-", data=patch)
    wrong = [name for name, facts in MANIFEST.items()
             if digest(repo, name) != facts["after"]]
    if wrong:
        raise RuntimeError("Post-apply verification failed: " + ", ".join(wrong))
    print(f"Applied and verified {len(MANIFEST)} files. No commit, push, build or CI started.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, zlib.error) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
