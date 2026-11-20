"""Package an unsigned device app and check its bundled dependencies."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile
import hashlib

app = Path("build/device/Build/Products/Release-iphoneos/Newexplorer.app")
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == "0.2.0"
assert info["CFBundleVersion"] == "2"
assert "iPhoneOS" in info["CFBundleSupportedPlatforms"]
binary = app / info["CFBundleExecutable"]
assert "arm64" in subprocess.check_output(["lipo", "-archs", str(binary)], text=True)

def check_dependencies(binary):
    deps = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    for line in deps:
        path = line.strip().split(" ", 1)[0]
        if path.startswith("@rpath/"):
            relative = path.removeprefix("@rpath/")
            assert (app / "Frameworks" / relative).exists(), f"Missing embedded dependency {relative}"
    print("Verified dependencies", binary.name)

check_dependencies(binary)
smb = app / "Frameworks/AMSMB2.framework/AMSMB2"
assert smb.exists(), "The SMB framework must be embedded"
check_dependencies(smb)
assert (app / "Assets.car").exists()
for key in ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription", "NSLocalNetworkUsageDescription"]:
    assert info[key]
output = Path("output")
output.mkdir(exist_ok=True)
payload = output / "Payload"
payload.mkdir(exist_ok=True)
copy = payload / app.name
shutil.copytree(app, copy, dirs_exist_ok=True)
for signature in list(copy.rglob("_CodeSignature")):
    shutil.rmtree(signature)
ipa = output / "Newexplorer-v0.2.0-unsigned.ipa"
subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(ipa)], check=True)
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    assert "Payload/Newexplorer.app/Newexplorer" in archive.namelist()
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(output / "SHA256.txt").write_text(f"{digest}  {ipa.name}\n")
print(ipa, ipa.stat().st_size, "bytes")
