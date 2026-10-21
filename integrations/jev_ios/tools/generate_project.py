#!/usr/bin/env python3
"""Generate an app with embedded keyboard and local one-frame capture extensions."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def identity(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(token, kind, **values):
    key = identity(token)
    objects[key] = {"isa": kind, **values}
    return key


def serial(value, indent=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + json.dumps(str(k)) + " = " + serial(v, indent + 1) + ";\n" for k, v in value.items()) + "\t" * indent + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serial(v, indent) for v in value) + ("," if value else "") + ")"
    return json.dumps(str(value), ensure_ascii=False)


def file(path, filetype):
    return add("file:" + path, "PBXFileReference", path=path, lastKnownFileType=filetype, sourceTree="SOURCE_ROOT")


def build(target, path, filetype="sourcecode.swift"):
    return add(f"build:{target}:{path}", "PBXBuildFile", fileRef=file(path, filetype))


shared = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Shared").glob("*.swift"))
recognition = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "ImageRecognition").glob("*.swift"))
app = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "App/Sources").glob("*.swift"))
keyboard = sorted(p.relative_to(ROOT).as_posix() for folder in ("Keyboard/Sources", "Keyboard/Input")
                  for p in (ROOT / folder).glob("*.swift"))
capture = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Capture/Sources").glob("*.swift"))
capture_shared = ["Shared/Domain.swift", "Shared/Store.swift", "Shared/CaptureMailbox.swift"]
keyboard_resources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Keyboard/Resources").glob("*") if p.is_file())
resources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "App/Resources").glob("*.csv"))
app_id = identity("target:app")
keyboard_id = identity("target:keyboard")
capture_id = identity("target:capture")
project_id = identity("project")
signing = file("Signing.xcconfig", "text.xcconfig")


def configurations(name, extra):
    common = {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "TARGETED_DEVICE_FAMILY": "1", "CODE_SIGN_STYLE": "Automatic",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GENERATE_INFOPLIST_FILE": "NO", **extra,
    }
    entries = []
    for config in ("Debug", "Release"):
        settings = {**common, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
                    "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym"}
        if config == "Debug":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG " + settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        entries.append(add(f"config:{name}:{config}", "XCBuildConfiguration", name=config,
                           baseConfigurationReference=signing, buildSettings=settings))
    return add("configlist:" + name, "XCConfigurationList", buildConfigurations=entries,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


products = []
targets = []
for name, files, product, kind, identifier, info, entitlement in [
    ("GoutouJunshi", app, "GoutouJunshi.app", "com.apple.product-type.application",
     "$(GOUTOU_BUNDLE_ID)", "App/Info.plist", "App/GoutouJunshi.entitlements"),
    ("GoutouKeyboard", keyboard, "GoutouKeyboard.appex", "com.apple.product-type.app-extension",
     "$(GOUTOU_BUNDLE_ID).keyboard", "Keyboard/Info.plist", "Keyboard/GoutouKeyboard.entitlements"),
    ("GoutouCapture", capture, "GoutouCapture.appex", "com.apple.product-type.app-extension",
     "$(GOUTOU_BUNDLE_ID).capture", "Capture/Info.plist", "Capture/GoutouCapture.entitlements"),
]:
    target_key = {"GoutouJunshi": app_id, "GoutouKeyboard": keyboard_id, "GoutouCapture": capture_id}[name]
    product_ref = add("product:" + name, "PBXFileReference", explicitFileType="wrapper.application" if name == "GoutouJunshi" else "wrapper.app-extension",
                      path=product, sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
    products.append(product_ref)
    sources = add("sources:" + name, "PBXSourcesBuildPhase", buildActionMask=2147483647,
                  files=[build(name, p) for p in (capture_shared if name == "GoutouCapture" else shared) + recognition + files], runOnlyForDeploymentPostprocessing=0)
    frameworks = add("frameworks:" + name, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    resource_files = [build(name, "PrivacyInfo.xcprivacy", "text.xml"),
                      build(name, "Shared/BrandAssets.xcassets", "folder.assetcatalog")]
    if name == "GoutouJunshi":
        resource_files += [build(name, p, "text") for p in resources]
    elif name == "GoutouKeyboard":
        resource_files += [build(name, p, "text") for p in keyboard_resources]
    if name == "GoutouJunshi":
        resource_files.append(build(name, "App/Assets.xcassets", "folder.assetcatalog"))
    resource_phase = add("resources:" + name, "PBXResourcesBuildPhase", buildActionMask=2147483647,
                         files=resource_files, runOnlyForDeploymentPostprocessing=0)
    phases = [sources, frameworks, resource_phase]
    dependencies = []
    if name == "GoutouJunshi":
        embedded = []
        for token, target, product_name in [("keyboard", keyboard_id, "GoutouKeyboard"), ("capture", capture_id, "GoutouCapture")]:
            proxy = add(token + "-proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
                        remoteGlobalIDString=target, remoteInfo=product_name)
            dependencies.append(add(token + "-dependency", "PBXTargetDependency", target=target, targetProxy=proxy))
            embedded.append(add("embed-" + token, "PBXBuildFile", fileRef=identity("product:" + product_name),
                                settings={"ATTRIBUTES": ["RemoveHeadersOnCopy", "CodeSignOnCopy"]}))
        phases.append(add("embed-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="",
                          dstSubfolderSpec=13, files=embedded, name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0))
    settings = {"PRODUCT_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER": identifier,
                "INFOPLIST_FILE": info, "CODE_SIGN_ENTITLEMENTS": entitlement,
                "CURRENT_PROJECT_VERSION": "13", "MARKETING_VERSION": "0.1.1",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]}
    if name != "GoutouJunshi":
        settings.update({"APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
                         "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]})
        if name == "GoutouCapture":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "GOUTOU_CAPTURE"
    else:
        settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    objects[target_key] = {"isa": "PBXNativeTarget", "name": name, "productName": name, "productType": kind,
                          "productReference": product_ref, "buildConfigurationList": configurations(name, settings),
                          "buildPhases": phases, "buildRules": [], "dependencies": dependencies}
    targets.append(target_key)

groups = []
for title, files in [("Shared", shared), ("ImageRecognition", recognition), ("App", app), ("Keyboard", keyboard), ("Capture", capture), ("Resources", resources + keyboard_resources)]:
    refs = [file(p, "sourcecode.swift" if p.endswith(".swift") else "text") for p in files]
    if title == "Shared": refs.append(file("Shared/BrandAssets.xcassets", "folder.assetcatalog"))
    if title == "App": refs += [file("App/Info.plist", "text.plist.xml"), file("App/GoutouJunshi.entitlements", "text.plist.entitlements"),
                                file("App/Assets.xcassets", "folder.assetcatalog")]
    if title == "Keyboard": refs += [file("Keyboard/Info.plist", "text.plist.xml"), file("Keyboard/GoutouKeyboard.entitlements", "text.plist.entitlements")]
    if title == "Capture": refs += [file("Capture/Info.plist", "text.plist.xml"), file("Capture/GoutouCapture.entitlements", "text.plist.entitlements")]
    groups.append(add("group:" + title, "PBXGroup", name=title, children=refs, sourceTree="<group>"))
groups += [signing, file("PrivacyInfo.xcprivacy", "text.xml"),
           add("products-group", "PBXGroup", name="Products", children=products, sourceTree="<group>")]
main = add("main-group", "PBXGroup", children=groups, sourceTree="<group>")
objects[project_id] = {
    "isa": "PBXProject", "attributes": {"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1500"},
    "buildConfigurationList": configurations("project", {}), "compatibilityVersion": "Xcode 14.0",
    "developmentRegion": "zh-Hans", "hasScannedForEncodings": 0, "knownRegions": ["zh-Hans", "en", "Base"],
    "mainGroup": main, "productRefGroup": identity("products-group"), "projectDirPath": "", "projectRoot": "", "targets": targets,
}
directory = ROOT / "GoutouJunshi.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serial({
    "archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id
}) + "\n")
scheme = directory / "xcshareddata/xcschemes"
scheme.mkdir(parents=True, exist_ok=True)
(scheme / "GoutouJunshi.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="GoutouJunshi.app" BlueprintName="GoutouJunshi" ReferencedContainer="container:GoutouJunshi.xcodeproj"/>
    </BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="GoutouJunshi.app" BlueprintName="GoutouJunshi" ReferencedContainer="container:GoutouJunshi.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

base_info = {
    "CFBundleDevelopmentRegion": "zh-Hans", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "GoutouAppGroup": "$(GOUTOU_APP_GROUP)", "GoutouKeychainGroup": "$(GOUTOU_KEYCHAIN_GROUP)",
    "ITSAppUsesNonExemptEncryption": False,
}
for path, info in [
    ("App/Info.plist", {**base_info, "CFBundleDisplayName": "狗头军师", "CFBundlePackageType": "APPL",
                        "LSRequiresIPhoneOS": True, "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]}),
    ("Keyboard/Info.plist", {**base_info, "CFBundleDisplayName": "狗头军师", "CFBundlePackageType": "XPC!",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.keyboard-service",
                       "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).KeyboardViewController",
                       "NSExtensionAttributes": {"IsASCIICapable": True, "PrefersRightToLeft": False,
                                                 "PrimaryLanguage": "zh-Hans", "RequestsOpenAccess": True}}}),
    ("Capture/Info.plist", {**base_info, "CFBundleDisplayName": "狗头军师 · 本地截屏识图", "CFBundlePackageType": "XPC!",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.broadcast-services-upload",
                       "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).SampleHandler",
                       "NSExtensionAttributes": {"RPBroadcastProcessMode": "RPBroadcastProcessModeSampleBuffer"}}}),
]:
    (ROOT / path).write_bytes(plistlib.dumps(info, sort_keys=False))
entitlements = {"com.apple.security.application-groups": ["$(GOUTOU_APP_GROUP)"],
                "keychain-access-groups": ["$(GOUTOU_KEYCHAIN_GROUP)"]}
for path in ["App/GoutouJunshi.entitlements", "Keyboard/GoutouKeyboard.entitlements"]:
    (ROOT / path).write_bytes(plistlib.dumps(entitlements))
(ROOT / "Capture/GoutouCapture.entitlements").write_bytes(plistlib.dumps({
    "com.apple.security.application-groups": ["$(GOUTOU_APP_GROUP)"]
}))
print(f"Generated {directory.name}: {len(shared)} shared, {len(app)} app, {len(keyboard)} keyboard sources")
