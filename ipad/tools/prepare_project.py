"""Prepare the self-contained iPad Xcode project from the shared art library.

Run with Python 3.12+, then open App/HajiSaki.xcodeproj in Xcode.
No XcodeGen, Codex runtime, network access or signing credentials are required.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import plistlib
import shutil

IPAD = pathlib.Path(__file__).resolve().parents[1]
ROOT = IPAD.parent
APP = IPAD / "App"


def ident(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def prepare() -> None:
    resources = APP / "Resources"
    catalog = resources / "Art.xcassets"
    catalog.mkdir(parents=True, exist_ok=True)
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}), encoding="utf-8")
    icon = IPAD / "assets/app-icon-1024.png"
    if not icon.is_file():
        raise FileNotFoundError("The approved 1024px app icon is required: " + str(icon))
    icon_set = catalog / "AppIcon.appiconset"
    icon_set.mkdir(exist_ok=True)
    shutil.copyfile(icon, icon_set / "AppIcon.png")
    (icon_set / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}
    }), encoding="utf-8")
    manifest = json.loads((ROOT / "assets_pipeline/native-resources.json").read_text(encoding="utf-8"))
    manifest["profile_portrait"] = "ipad/assets/app-icon.png"
    tablet_catalog = IPAD / "assets/catalog.json"
    if tablet_catalog.is_file():
        for asset in json.loads(tablet_catalog.read_text(encoding="utf-8"))["assets"]:
            if asset["id"] in ("blink_closed", "concerned_blush"):
                manifest[asset["id"]] = asset["path"]
    for key, relative in manifest.items():
        name = {"day_room": "day-room", "night_room": "night-room"}.get(key, key)
        source = ROOT / relative
        if not source.is_file():
            raise FileNotFoundError(source)
        target = catalog / f"{name}.imageset"
        target.mkdir(exist_ok=True)
        output_name = "blink_closed.png" if name == "blink_closed" else source.name
        shutil.copyfile(source, target / output_name)
        contents = {"images": [{"filename": output_name, "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}
        (target / "Contents.json").write_text(json.dumps(contents), encoding="utf-8")
    info = {
        "CFBundleDisplayName": "哈基祥", "CFBundleName": "HajiSaki",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7",
        "LSRequiresIPhoneOS": True, "UILaunchScreen": {"UIColorName": "LaunchBackground"},
        "UIStatusBarStyle": "UIStatusBarStyleLightContent", "UIViewControllerBasedStatusBarAppearance": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": True},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UIRequiresFullScreen": False, "UISupportsDocumentBrowser": False,
        "NSLocalNetworkUsageDescription": "连接你指定的琴房主机，取回对话和文件。",
        "NSMicrophoneUsageDescription": "录下你亲自开启的语音，保留原声并交给琴房转写。",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        "LSSupportsOpeningDocumentsInPlace": True, "UIFileSharingEnabled": True,
        "CFBundleURLTypes": [{"CFBundleURLName": "app.hajisaki.theater.ipad", "CFBundleURLSchemes": ["hajisaki"], "CFBundleTypeRole": "Viewer"}],
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "琴房文档", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate", "LSItemContentTypes": ["public.data", "com.adobe.pdf", "public.image", "public.text"]}],
    }
    (APP / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    sources = sorted((APP / "Sources").rglob("*.swift"))
    entries: list[str] = []
    source_refs, source_builds, resource_refs, resource_builds = [], [], [], []
    for path in sources:
        relative = path.relative_to(APP).as_posix()
        ref, build = ident(relative), ident("build:" + relative)
        entries += [f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = "<group>"; }};', f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};']
        source_refs.append(ref)
        source_builds.append(build)
    resource_paths = [("Resources/Art.xcassets", "folder.assetcatalog")]
    if (IPAD / "assets/living-stage").is_dir():
        resource_paths.append(("../assets/living-stage", "folder"))
    if (resources / "Renderer").is_dir():
        resource_paths.append(("Resources/Renderer", "folder"))
    audio_source = IPAD / "assets/audio"
    if audio_source.is_dir():
        audio_target = resources / "audio"
        audio_target.mkdir(parents=True, exist_ok=True)
        for audio_file in audio_source.glob("*.wav"):
            shutil.copyfile(audio_file, audio_target / audio_file.name)
        resource_paths.append(("Resources/audio", "folder"))
    for relative, kind in resource_paths:
        ref, build = ident(relative), ident("build:" + relative)
        entries += [f'{ref} = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {quoted(relative)}; sourceTree = "<group>"; }};', f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};']
        resource_refs.append(ref)
        resource_builds.append(build)
    ids = {name: ident(name) for name in ["project", "root", "products", "product", "target", "sources", "resources", "frameworks", "project-list", "target-list", "project-debug", "project-release", "target-debug", "target-release"]}
    entries += [
        f'{ids["project"]} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 2630; }}; buildConfigurationList = {ids["project-list"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; knownRegions = ("zh-Hans", en, Base); mainGroup = {ids["root"]}; productRefGroup = {ids["products"]}; projectDirPath = ""; projectRoot = ""; targets = ({ids["target"]}); }};',
        f'{ids["root"]} = {{isa = PBXGroup; children = ({",".join(source_refs + resource_refs + [ids["products"]])}); sourceTree = "<group>"; }};',
        f'{ids["products"]} = {{isa = PBXGroup; children = ({ids["product"]}); name = Products; sourceTree = "<group>"; }};',
        f'{ids["product"]} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HajiSaki.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
        f'{ids["target"]} = {{isa = PBXNativeTarget; buildConfigurationList = {ids["target-list"]}; buildPhases = ({ids["sources"]},{ids["frameworks"]},{ids["resources"]}); buildRules = (); dependencies = (); name = HajiSaki; productName = HajiSaki; productReference = {ids["product"]}; productType = "com.apple.product-type.application"; }};',
        f'{ids["sources"]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_builds)}); runOnlyForDeploymentPostprocessing = 0; }};',
        f'{ids["resources"]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_builds)}); runOnlyForDeploymentPostprocessing = 0; }};',
        f'{ids["frameworks"]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
    ]
    for level in ("project", "target"):
        for config in ("debug", "release"):
            settings = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0"}
            if level == "target":
                settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "app.hajisaki.theater.ipad", "PRODUCT_NAME": "$(TARGET_NAME)", "TARGETED_DEVICE_FAMILY": "2", "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "OTHER_LDFLAGS": "-lsqlite3", "SWIFT_EMIT_LOC_STRINGS": "YES", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"})
            if config == "debug":
                settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "DEBUG_INFORMATION_FORMAT": "dwarf", "ONLY_ACTIVE_ARCH": "YES"})
            else:
                settings.update({"SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"})
            body = " ".join(f"{k} = {quoted(v)};" for k, v in settings.items())
            entries.append(f'{ids[level + "-" + config]} = {{isa = XCBuildConfiguration; buildSettings = {{{body}}}; name = {config.title()}; }};')
        entries.append(f'{ids[level + "-list"]} = {{isa = XCConfigurationList; buildConfigurations = ({ids[level + "-debug"]},{ids[level + "-release"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
    project = APP / "HajiSaki.xcodeproj"
    scheme_dir = project / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (project / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + "\n".join(entries) + f'\n}}; rootObject = {ids["project"]}; }}\n', encoding="utf-8")
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids["target"]}" BuildableName="HajiSaki.app" BlueprintName="HajiSaki" ReferencedContainer="container:HajiSaki.xcodeproj"/>'
    (scheme_dir / "HajiSaki.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''', encoding="utf-8")
    print(json.dumps({"project": str(project), "swift_files": len(sources), "art_images": len(manifest), "bundle_id": "app.hajisaki.theater.ipad"}))


if __name__ == "__main__":
    prepare()
