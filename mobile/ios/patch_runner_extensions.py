#!/usr/bin/env python3
"""Patch Runner.xcodeproj/project.pbxproj: Safari Web Extension + Share extension embedded in Runner."""
from pathlib import Path

PBX = Path(__file__).resolve().parent / "Runner.xcodeproj" / "project.pbxproj"
text = PBX.read_text(encoding="utf-8")

if "CleanRoomShieldExtension" in text:
    print("Already patched.")
    raise SystemExit(0)

S = {
    "safari_appex": "E70001012EC600010004E001",
    "safari_swift": "E70001022EC600010004E002",
    "safari_plist": "E70001032EC600010004E003",
    "safari_ent": "E70001042EC600010004E004",
    "safari_manifest": "E70001052EC600010004E005",
    "safari_bg": "E70001062EC600010004E006",
    "bf_safari_swift": "E70001112EC600010004E011",
    "bf_safari_man": "E70001122EC600010004E012",
    "bf_safari_bg": "E70001132EC600010004E013",
    "bf_embed_safari": "E70001142EC600010004E014",
    "safari_src_phase": "E70001202EC600010004E020",
    "safari_fw_phase": "E70001212EC600010004E021",
    "safari_res_phase": "E70001222EC600010004E022",
    "safari_target": "E70001302EC600010004E030",
    "safari_grp": "E70001402EC600010004E040",
    "safari_res_grp": "E70001412EC600010004E041",
    "safari_xclist": "E70001502EC600010004E050",
    "safari_dbg": "E70001512EC600010004E051",
    "safari_rel": "E70001522EC600010004E052",
    "safari_prof": "E70001532EC600010004E053",
    "share_appex": "E70002012EC600010004E101",
    "share_swift": "E70002022EC600010004E102",
    "share_plist": "E70002032EC600010004E103",
    "share_ent": "E70002042EC600010004E104",
    "bf_share_swift": "E70002112EC600010004E111",
    "bf_embed_share": "E70002122EC600010004E112",
    "share_src_phase": "E70002202EC600010004E120",
    "share_fw_phase": "E70002212EC600010004E121",
    "share_target": "E70002302EC600010004E130",
    "share_grp": "E70002402EC600010004E140",
    "share_xclist": "E70002502EC600010004E150",
    "share_dbg": "E70002512EC600010004E151",
    "share_rel": "E70002522EC600010004E152",
    "share_prof": "E70002532EC600010004E153",
    "embed_phase": "E70009012EC600010004E901",
    "proxy_safari": "E70009112EC600010004E911",
    "dep_safari": "E70009122EC600010004E912",
    "proxy_share": "E70009132EC600010004E913",
    "dep_share": "E70009142EC600010004E914",
}


def xc_cfg(key: str, name: str, ent: str, plist: str, display: str, bundle: str, safari_ld: bool) -> str:
    tid = S[key]
    ld = (
        '\t\t\t\tOTHER_LDFLAGS = (\n\t\t\t\t\t"-framework",\n\t\t\t\t\tSafariServices,\n\t\t\t\t);\n'
        if safari_ld
        else ""
    )
    return (
        "\t\t{tid} /* {name} */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {{\n"
        "\t\t\t\tCODE_SIGN_ENTITLEMENTS = {ent};\n"
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
        "\t\t\t\tDEVELOPMENT_TEAM = V3J8MR637G;\n"
        "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n"
        "\t\t\t\tINFOPLIST_FILE = {plist};\n"
        '\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "{display}";\n'
        "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;\n"
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n"
        '\t\t\t\t\t"$(inherited)",\n'
        '\t\t\t\t\t"@executable_path/Frameworks",\n'
        '\t\t\t\t\t"@executable_path/../../Frameworks",\n'
        "\t\t\t\t);\n"
        "\t\t\t\tMARKETING_VERSION = 1.0;\n"
        "{ld}"
        "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.sixcleanroom.sixCleanRoom.{bundle};\n"
        '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
        "\t\t\t\tSKIP_INSTALL = YES;\n"
        "\t\t\t\tSWIFT_VERSION = 5.0;\n"
        '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
        "\t\t\t}};\n"
        "\t\t\tname = {name};\n"
        "\t\t}};\n"
    ).format(tid=tid, name=name, ent=ent, plist=plist, display=display, bundle=bundle, ld=ld)


BUILD_FILES = """\
		{bf_safari_swift} /* SafariWebExtensionHandler.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {safari_swift} /* SafariWebExtensionHandler.swift */; }};
		{bf_safari_man} /* manifest.json in Resources */ = {{isa = PBXBuildFile; fileRef = {safari_manifest} /* manifest.json */; }};
		{bf_safari_bg} /* background.js in Resources */ = {{isa = PBXBuildFile; fileRef = {safari_bg} /* background.js */; }};
		{bf_embed_safari} /* CleanRoomShieldExtension.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {safari_appex} /* CleanRoomShieldExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
		{bf_share_swift} /* ShareViewController.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {share_swift} /* ShareViewController.swift */; }};
		{bf_embed_share} /* BlockShareExtension.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {share_appex} /* BlockShareExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
""".format(**S)

FILE_REFS = """\
		{safari_appex} /* CleanRoomShieldExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = CleanRoomShieldExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
		{safari_swift} /* SafariWebExtensionHandler.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SafariWebExtensionHandler.swift; sourceTree = "<group>"; }};
		{safari_plist} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{safari_ent} /* CleanRoomShieldExtension.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = CleanRoomShieldExtension.entitlements; sourceTree = "<group>"; }};
		{safari_manifest} /* manifest.json */ = {{isa = PBXFileReference; lastKnownFileType = text.json; path = manifest.json; sourceTree = "<group>"; }};
		{safari_bg} /* background.js */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.javascript; path = background.js; sourceTree = "<group>"; }};
		{share_appex} /* BlockShareExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = BlockShareExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
		{share_swift} /* ShareViewController.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareViewController.swift; sourceTree = "<group>"; }};
		{share_plist} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{share_ent} /* BlockShareExtension.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = BlockShareExtension.entitlements; sourceTree = "<group>"; }};
""".format(**S)

COPY_PHASE = """\
		{embed_phase} /* Embed App Extensions */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				{bf_embed_safari} /* CleanRoomShieldExtension.appex in Embed App Extensions */,
				{bf_embed_share} /* BlockShareExtension.appex in Embed App Extensions */,
			);
			name = "Embed App Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};
""".format(**S)

FW_SAFARI = """\
		{safari_fw_phase} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""".format(**S)

FW_SHARE = """\
		{share_fw_phase} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""".format(**S)

RES_SAFARI = """\
		{safari_res_phase} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf_safari_man} /* manifest.json in Resources */,
				{bf_safari_bg} /* background.js in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""".format(**S)

SRC_SAFARI = """\
		{safari_src_phase} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf_safari_swift} /* SafariWebExtensionHandler.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""".format(**S)

SRC_SHARE = """\
		{share_src_phase} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{bf_share_swift} /* ShareViewController.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""".format(**S)

GROUPS = """\
		{safari_res_grp} /* Resources */ = {{
			isa = PBXGroup;
			children = (
				{safari_manifest} /* manifest.json */,
				{safari_bg} /* background.js */,
			);
			path = Resources;
			sourceTree = "<group>";
		}};
		{safari_grp} /* CleanRoomShieldExtension */ = {{
			isa = PBXGroup;
			children = (
				{safari_res_grp} /* Resources */,
				{safari_swift} /* SafariWebExtensionHandler.swift */,
				{safari_plist} /* Info.plist */,
				{safari_ent} /* CleanRoomShieldExtension.entitlements */,
			);
			path = CleanRoomShieldExtension;
			sourceTree = "<group>";
		}};
		{share_grp} /* BlockShareExtension */ = {{
			isa = PBXGroup;
			children = (
				{share_swift} /* ShareViewController.swift */,
				{share_plist} /* Info.plist */,
				{share_ent} /* BlockShareExtension.entitlements */,
			);
			path = BlockShareExtension;
			sourceTree = "<group>";
		}};
""".format(**S)

TARGET_SAFARI = """\
		{safari_target} /* CleanRoomShieldExtension */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {safari_xclist} /* Build configuration list for PBXNativeTarget "CleanRoomShieldExtension" */;
			buildPhases = (
				{safari_src_phase} /* Sources */,
				{safari_fw_phase} /* Frameworks */,
				{safari_res_phase} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = CleanRoomShieldExtension;
			productName = CleanRoomShieldExtension;
			productReference = {safari_appex} /* CleanRoomShieldExtension.appex */;
			productType = "com.apple.product-type.app-extension";
		}};
""".format(**S)

TARGET_SHARE = """\
		{share_target} /* BlockShareExtension */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {share_xclist} /* Build configuration list for PBXNativeTarget "BlockShareExtension" */;
			buildPhases = (
				{share_src_phase} /* Sources */,
				{share_fw_phase} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = BlockShareExtension;
			productName = BlockShareExtension;
			productReference = {share_appex} /* BlockShareExtension.appex */;
			productType = "com.apple.product-type.app-extension";
		}};
""".format(**S)

PROXY_BLOCK = """\
		{proxy_safari} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = 97C146E61CF9000F007C117D /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {safari_target};
			remoteInfo = CleanRoomShieldExtension;
		}};
		{proxy_share} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = 97C146E61CF9000F007C117D /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {share_target};
			remoteInfo = BlockShareExtension;
		}};
""".format(**S)

DEP_BLOCK = """\
		{dep_safari} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {safari_target} /* CleanRoomShieldExtension */;
			targetProxy = {proxy_safari} /* PBXContainerItemProxy */;
		}};
		{dep_share} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {share_target} /* BlockShareExtension */;
			targetProxy = {proxy_share} /* PBXContainerItemProxy */;
		}};
""".format(**S)

XC_INSERT = (
    xc_cfg("safari_dbg", "Debug", "CleanRoomShieldExtension/CleanRoomShieldExtension.entitlements", "CleanRoomShieldExtension/Info.plist", "Six Clean Room Shield", "CleanRoomShieldExtension", True)
    + xc_cfg("safari_rel", "Release", "CleanRoomShieldExtension/CleanRoomShieldExtension.entitlements", "CleanRoomShieldExtension/Info.plist", "Six Clean Room Shield", "CleanRoomShieldExtension", True)
    + xc_cfg("safari_prof", "Profile", "CleanRoomShieldExtension/CleanRoomShieldExtension.entitlements", "CleanRoomShieldExtension/Info.plist", "Six Clean Room Shield", "CleanRoomShieldExtension", True)
    + xc_cfg("share_dbg", "Debug", "BlockShareExtension/BlockShareExtension.entitlements", "BlockShareExtension/Info.plist", "차단에 추가", "BlockShareExtension", False)
    + xc_cfg("share_rel", "Release", "BlockShareExtension/BlockShareExtension.entitlements", "BlockShareExtension/Info.plist", "차단에 추가", "BlockShareExtension", False)
    + xc_cfg("share_prof", "Profile", "BlockShareExtension/BlockShareExtension.entitlements", "BlockShareExtension/Info.plist", "차단에 추가", "BlockShareExtension", False)
)

XC_LIST_SAFARI = """\
		{safari_xclist} /* Build configuration list for PBXNativeTarget "CleanRoomShieldExtension" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{safari_dbg} /* Debug */,
				{safari_rel} /* Release */,
				{safari_prof} /* Profile */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
""".format(**S)

XC_LIST_SHARE = """\
		{share_xclist} /* Build configuration list for PBXNativeTarget "BlockShareExtension" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{share_dbg} /* Debug */,
				{share_rel} /* Release */,
				{share_prof} /* Profile */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
""".format(**S)

# --- apply ---
text = text.replace("/* End PBXBuildFile section */", BUILD_FILES + "\n" + "/* End PBXBuildFile section */", 1)
text = text.replace("/* End PBXFileReference section */", FILE_REFS + "\n" + "/* End PBXFileReference section */", 1)
text = text.replace("/* End PBXCopyFilesBuildPhase section */", COPY_PHASE + "\n" + "/* End PBXCopyFilesBuildPhase section */", 1)
text = text.replace(
    "/* End PBXFrameworksBuildPhase section */", FW_SAFARI + FW_SHARE + "\n" + "/* End PBXFrameworksBuildPhase section */", 1
)
text = text.replace("/* End PBXResourcesBuildPhase section */", RES_SAFARI + "\n" + "/* End PBXResourcesBuildPhase section */", 1)
text = text.replace("/* End PBXSourcesBuildPhase section */", SRC_SAFARI + SRC_SHARE + "\n" + "/* End PBXSourcesBuildPhase section */", 1)
text = text.replace("/* End PBXGroup section */", GROUPS + "\n" + "/* End PBXGroup section */", 1)
text = text.replace("/* End PBXNativeTarget section */", TARGET_SAFARI + TARGET_SHARE + "\n" + "/* End PBXNativeTarget section */", 1)

text = text.replace(
    "\t\t331C8085294A63A400263BE5 /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = 97C146E61CF9000F007C117D /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = 97C146ED1CF9000F007C117D;\n\t\t\tremoteInfo = Runner;\n\t\t};\n/* End PBXContainerItemProxy section */",
    "\t\t331C8085294A63A400263BE5 /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = 97C146E61CF9000F007C117D /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = 97C146ED1CF9000F007C117D;\n\t\t\tremoteInfo = Runner;\n\t\t};\n"
    + PROXY_BLOCK
    + "/* End PBXContainerItemProxy section */",
    1,
)

text = text.replace(
    "\t\t331C8086294A63A400263BE5 /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = 97C146ED1CF9000F007C117D /* Runner */;\n\t\t\ttargetProxy = 331C8085294A63A400263BE5 /* PBXContainerItemProxy */;\n\t\t};\n/* End PBXTargetDependency section */",
    "\t\t331C8086294A63A400263BE5 /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = 97C146ED1CF9000F007C117D /* Runner */;\n\t\t\ttargetProxy = 331C8085294A63A400263BE5 /* PBXContainerItemProxy */;\n\t\t};\n"
    + DEP_BLOCK
    + "/* End PBXTargetDependency section */",
    1,
)

text = text.replace(
    "\t\t\t\t97C146F01CF9000F007C117D /* Runner */,\n",
    "\t\t\t\t97C146F01CF9000F007C117D /* Runner */,\n"
    "\t\t\t\t{safari_grp} /* CleanRoomShieldExtension */,\n"
    "\t\t\t\t{share_grp} /* BlockShareExtension */,\n".format(**S),
    1,
)

text = text.replace(
    "\t\t\t\t97C146EE1CF9000F007C117D /* Runner.app */,\n",
    "\t\t\t\t97C146EE1CF9000F007C117D /* Runner.app */,\n"
    "\t\t\t\t{safari_appex} /* CleanRoomShieldExtension.appex */,\n"
    "\t\t\t\t{share_appex} /* BlockShareExtension.appex */,\n".format(**S),
    1,
)

text = text.replace(
    "\t\t\ttargets = (\n\t\t\t\t97C146ED1CF9000F007C117D /* Runner */,\n\t\t\t\t331C8080294A63A400263BE5 /* RunnerTests */,\n\t\t\t);",
    "\t\t\ttargets = (\n\t\t\t\t97C146ED1CF9000F007C117D /* Runner */,\n"
    "\t\t\t\t{safari_target} /* CleanRoomShieldExtension */,\n"
    "\t\t\t\t{share_target} /* BlockShareExtension */,\n"
    "\t\t\t\t331C8080294A63A400263BE5 /* RunnerTests */,\n\t\t\t);".format(**S),
    1,
)

runner_deps = (
    "\t\t\tdependencies = (\n"
    "\t\t\t\t{dep_safari} /* PBXTargetDependency */,\n"
    "\t\t\t\t{dep_share} /* PBXTargetDependency */,\n"
    "\t\t\t);\n"
    "\t\t\tname = Runner;\n"
).format(**S)
text = text.replace("\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = Runner;\n", runner_deps, 1)

text = text.replace(
    "\t\t\t\t97C146EC1CF9000F007C117D /* Resources */,\n"
    "\t\t\t\t9705A1C41CF9048500538489 /* Embed Frameworks */,\n"
    "\t\t\t\t3B06AD1E1E4923F5004D2608 /* Thin Binary */,",
    "\t\t\t\t97C146EC1CF9000F007C117D /* Resources */,\n"
    "\t\t\t\t9705A1C41CF9048500538489 /* Embed Frameworks */,\n"
    "\t\t\t\t{embed_phase} /* Embed App Extensions */,\n"
    "\t\t\t\t3B06AD1E1E4923F5004D2608 /* Thin Binary */,".format(**S),
    1,
)

text = text.replace(
    "\t\t\t\t97C146ED1CF9000F007C117D = {\n\t\t\t\t\tCreatedOnToolsVersion = 7.3.1;\n\t\t\t\t\tLastSwiftMigration = 1100;\n\t\t\t\t};",
    "\t\t\t\t97C146ED1CF9000F007C117D = {\n\t\t\t\t\tCreatedOnToolsVersion = 7.3.1;\n\t\t\t\t\tLastSwiftMigration = 1100;\n"
    "\t\t\t\t};\n"
    "\t\t\t\t"
    + S["safari_target"]
    + " = {\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t};\n\t\t\t\t"
    + S["share_target"]
    + " = {\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t};",
    1,
)

text = text.replace("/* End XCBuildConfiguration section */", XC_INSERT + "\n" + "/* End XCBuildConfiguration section */", 1)

text = text.replace(
    "/* End XCConfigurationList section */", XC_LIST_SAFARI + XC_LIST_SHARE + "\n" + "/* End XCConfigurationList section */", 1
)

PBX.write_text(text, encoding="utf-8")
print("Patched OK:", PBX)
