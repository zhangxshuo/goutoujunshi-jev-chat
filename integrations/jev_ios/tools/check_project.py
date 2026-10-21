#!/usr/bin/env python3
"""Check checked-in target membership, embedding, signing, resources and provenance."""
import json
import plistlib
import struct
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output([
    "plutil", "-convert", "json", "-o", "-", str(ROOT / "GoutouJunshi.xcodeproj/project.pbxproj")
]))
objects = project["objects"]
targets = {value["name"]: value for value in objects.values() if value["isa"] == "PBXNativeTarget"}
assert set(targets) == {"GoutouJunshi", "GoutouKeyboard", "GoutouCapture"}
shared = {p.relative_to(ROOT).as_posix() for p in (ROOT / "Shared").glob("*.swift")}
recognition = {p.relative_to(ROOT).as_posix() for p in (ROOT / "ImageRecognition").glob("*.swift")}


def phase_paths(target, phase):
    phases = [objects[key] for key in target["buildPhases"] if objects[key]["isa"] == phase]
    return {objects[objects[key]["fileRef"]]["path"] for item in phases for key in item["files"]}


for name, folder in [("GoutouJunshi", "App"), ("GoutouKeyboard", "Keyboard"), ("GoutouCapture", "Capture")]:
    target = targets[name]
    sources = {p.relative_to(ROOT).as_posix() for p in (ROOT / folder / "Sources").glob("*.swift")}
    if name == "GoutouKeyboard":
        sources |= {p.relative_to(ROOT).as_posix() for p in (ROOT / "Keyboard/Input").glob("*.swift")}
    common = {"Shared/Domain.swift", "Shared/Store.swift", "Shared/CaptureMailbox.swift"} if name == "GoutouCapture" else shared
    assert phase_paths(target, "PBXSourcesBuildPhase") == common | recognition | sources, name + " source membership"
    assert "PrivacyInfo.xcprivacy" in phase_paths(target, "PBXResourcesBuildPhase")
    for path in phase_paths(target, "PBXSourcesBuildPhase") | phase_paths(target, "PBXResourcesBuildPhase"):
        assert (ROOT / path).exists(), "Missing: " + path
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for key in configurations:
        config = objects[key]
        assert objects[config["baseConfigurationReference"]]["path"] == "Signing.xcconfig"
        settings = config["buildSettings"]
        assert settings["IPHONEOS_DEPLOYMENT_TARGET"] == "16.0"
        assert settings["CODE_SIGN_ENTITLEMENTS"].startswith(folder + "/")
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"].startswith("$(GOUTOU_BUNDLE_ID)")
        if name != "GoutouJunshi":
            assert settings["APPLICATION_EXTENSION_API_ONLY"] == "YES"
        if name == "GoutouCapture":
            assert "GOUTOU_CAPTURE" in settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split()

assert phase_paths(targets["GoutouJunshi"], "PBXCopyFilesBuildPhase") == {"GoutouKeyboard.appex", "GoutouCapture.appex"}
assert len(targets["GoutouJunshi"]["dependencies"]) == 2
app_resources = phase_paths(targets["GoutouJunshi"], "PBXResourcesBuildPhase")
assert sum(path.endswith(".csv") for path in app_resources) == 5
entitlements = [plistlib.loads((ROOT / file).read_bytes()) for file in (
    "App/GoutouJunshi.entitlements", "Keyboard/GoutouKeyboard.entitlements")]
assert entitlements[0] == entitlements[1] == {
    "com.apple.security.application-groups": ["$(GOUTOU_APP_GROUP)"],
}
for file in ("App/Info.plist", "Keyboard/Info.plist"):
    info = plistlib.loads((ROOT / file).read_bytes())
    assert "NSAppTransportSecurity" not in info
    assert info["GoutouAppGroup"] == "$(GOUTOU_APP_GROUP)"
    assert info["GoutouKeychainGroup"] == "$(GOUTOU_KEYCHAIN_GROUP)"
keyboard = plistlib.loads((ROOT / "Keyboard/Info.plist").read_bytes())["NSExtension"]
assert keyboard["NSExtensionAttributes"]["RequestsOpenAccess"] is True
assert keyboard["NSExtensionAttributes"]["IsASCIICapable"] is True
assert keyboard["NSExtensionAttributes"]["PrimaryLanguage"] == "zh-Hans"
assert keyboard["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).KeyboardViewController"
# This API compiles with the SDK but aborts at runtime in a keyboard extension.
# A build-11 device crash hit _UIApplicationAssertForExtensionType from
# UIAlertController initialization in confirmInsert(). Keep dialogs in-view.
for source in (ROOT / "Keyboard/Sources").glob("*.swift"):
    assert "UIAlertController" not in source.read_text(), "System alert disallowed in keyboard: " + str(source)
capture = plistlib.loads((ROOT / "Capture/Info.plist").read_bytes())["NSExtension"]
assert capture["NSExtensionPointIdentifier"] == "com.apple.broadcast-services-upload"
assert capture["NSExtensionAttributes"]["RPBroadcastProcessMode"] == "RPBroadcastProcessModeSampleBuffer"
assert capture["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).SampleHandler"
assert plistlib.loads((ROOT / "Capture/GoutouCapture.entitlements").read_bytes()) == {
    "com.apple.security.application-groups": ["$(GOUTOU_APP_GROUP)"]
}
assert "Shared/Networking.swift" not in phase_paths(targets["GoutouCapture"], "PBXSourcesBuildPhase")
assert {"Keyboard/Resources/pinyin.tsv", "Keyboard/Resources/Pinyin-LICENSE.txt"} <= phase_paths(targets["GoutouKeyboard"], "PBXResourcesBuildPhase")
scheme = ET.parse(ROOT / "GoutouJunshi.xcodeproj/xcshareddata/xcschemes/GoutouJunshi.xcscheme")
for item in scheme.findall(".//BuildableReference"):
    assert objects[item.attrib["BlueprintIdentifier"]]["name"] == "GoutouJunshi"
icons = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
for item in json.loads((icons / "Contents.json").read_text())["images"]:
    png = (icons / item["filename"]).read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    width, height, _, color = struct.unpack(">IIBB", png[16:26])
    expected = int(float(item["size"].split("x")[0]) * int(item["scale"][0]))
    assert width == height == expected and color in (0, 2), "Icon dimensions or alpha"
manifest = plistlib.loads((ROOT / "PrivacyInfo.xcprivacy").read_bytes())
assert manifest["NSPrivacyTracking"] is False
assert manifest["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"] == ["1C8F.1"]
provenance = json.loads((ROOT / "vendor/UPSTREAM.json").read_text())
assert len(provenance["commit"]) == 40 and len(provenance["archive_sha256"]) == 64
assert (ROOT / "vendor/LICENSE").is_file() and (ROOT / "vendor/NOTICE").is_file()
assert not list(ROOT.rglob("*.ipa")), "Unsigned source preview must not masquerade as an IPA"
print("PASS: Xcode target membership, signing groups, embedded keyboard/capture, icons and privacy metadata")
