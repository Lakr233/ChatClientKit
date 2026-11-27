#!/usr/bin/env python3
"""Generate a standalone Xcode project that builds ChatClientKit.framework for distribution."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
from pathlib import Path


def die(message: str) -> None:
    raise SystemExit(f"[!] {message}")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def xid(*parts: str) -> str:
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def parse_upstream_versions(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def copy_chatclientkit_sources(src: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


def write_xcode_scheme(path: Path, target_id: str) -> None:
    write_text(
        path,
        """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2630"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "TARGET_ID"
               BuildableName = "ChatClientKit.framework"
               BlueprintName = "ChatClientKit"
               ReferencedContainer = "container:ChatClientKit.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""".replace("TARGET_ID", target_id),
    )


def format_settings(settings: dict[str, str], indent: str = "\t\t\t\t") -> str:
    return "\n".join(f"{indent}{key} = {value};" for key, value in settings.items())


def write_xcode_project(
    root: Path,
    mlx_swift_lm_dir: Path,
    versions: dict[str, str],
) -> None:
    project_dir = root / "build" / "ChatClientKit.xcodeproj"
    mlx_lm_rel = Path(os.path.relpath(mlx_swift_lm_dir, project_dir.parent)).as_posix()

    mlx_swift_repo = versions["MLX_SWIFT_REPO"]
    mlx_swift_version = versions["MLX_SWIFT_VERSION"]
    tokenizers_repo = versions["SWIFT_TOKENIZERS_REPO"]
    tokenizers_version = versions["SWIFT_TOKENIZERS_VERSION"]

    project_id = xid("project")
    target_id = xid("target")
    product_id = xid("product")
    main_group_id = xid("main-group")
    products_group_id = xid("products-group")
    sources_phase_id = xid("sources-phase")
    frameworks_phase_id = xid("frameworks-phase")
    resources_phase_id = xid("resources-phase")
    headers_phase_id = xid("headers-phase")
    project_config_list_id = xid("project-config-list")
    target_config_list_id = xid("target-config-list")
    project_debug_id = xid("project-debug")
    project_release_id = xid("project-release")
    target_debug_id = xid("target-debug")
    target_release_id = xid("target-release")
    sources_group_id = xid("sync-sources")

    pkg_mlx_lm_id = xid("pkg-mlx-swift-lm")
    pkg_mlx_swift_id = xid("pkg-mlx-swift")
    pkg_tokenizers_id = xid("pkg-swift-tokenizers")

    products = [
        ("MLX", pkg_mlx_swift_id),
        ("MLXLLM", pkg_mlx_lm_id),
        ("MLXVLM", pkg_mlx_lm_id),
        ("MLXLMCommon", pkg_mlx_lm_id),
        ("Tokenizers", pkg_tokenizers_id),
    ]

    dep_ids = {name: xid("dep", name) for name, _ in products}
    build_file_ids = {name: xid("build-file", name) for name, _ in products}

    # Keep project-level settings minimal so SwiftPM package dependencies keep
    # their own Swift language mode and do not inherit BUILD_LIBRARY_FOR_DISTRIBUTION.
    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "COMPILER_INDEX_STORE_ENABLE": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "SDKROOT": "auto",
        "SUPPORTED_PLATFORMS": '"macosx iphoneos iphonesimulator"',
        "SUPPORTS_MACCATALYST": "YES",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    }
    project_debug = format_settings({
        **project_common,
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    })
    project_release = format_settings({
        **project_common,
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "VALIDATE_PRODUCT": "YES",
    })

    # Target-only settings: BUILD_LIBRARY_FOR_DISTRIBUTION and SWIFT_VERSION 6.0
    # apply strictly to ChatClientKit so internal SwiftPM dependencies stay static
    # without needing library evolution themselves.
    target_common = {
        "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
        "APPLICATION_EXTENSION_API_ONLY": "NO",
        "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "COMPILER_INDEX_STORE_ENABLE": "NO",
        "COPY_PHASE_STRIP": "NO",
        "CURRENT_PROJECT_VERSION": "1",
        "DEFINES_MODULE": "YES",
        "DYLIB_COMPATIBILITY_VERSION": "1",
        "DYLIB_CURRENT_VERSION": "1",
        "DYLIB_INSTALL_NAME_BASE": '"@rpath"',
        "ENABLE_MODULE_VERIFIER": "NO",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "ChatClientKit",
        "INSTALL_PATH": '"$(LOCAL_LIBRARY_DIR)/Frameworks"',
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"',
        '"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]"': '"$(inherited) @executable_path/../Frameworks @loader_path/Frameworks"',
        "MACH_O_TYPE": "mh_dylib",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "MARKETING_VERSION": "1.0.0",
        "OTHER_SWIFT_FLAGS": '"$(inherited) -Xfrontend -no-clang-module-breadcrumbs"',
        "PRODUCT_BUNDLE_IDENTIFIER": '"wiki.qaq.ChatClientKit"',
        "PRODUCT_MODULE_NAME": "ChatClientKit",
        "PRODUCT_NAME": "ChatClientKit",
        "SDKROOT": "auto",
        "SKIP_INSTALL": "NO",
        "STRIP_INSTALLED_PRODUCT": "YES",
        "STRIP_STYLE": '"non-global"',
        "SUPPORTED_PLATFORMS": '"macosx iphoneos iphonesimulator"',
        "SUPPORTS_MACCATALYST": "YES",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_INSTALL_OBJC_HEADER": "NO",
        "SWIFT_SERIALIZE_DEBUGGING_OPTIONS": "NO",
        "SWIFT_VERSION": "6.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    target_debug = format_settings({
        **target_common,
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "ONLY_ACTIVE_ARCH": "YES",
        "STRIP_INSTALLED_PRODUCT": "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    })
    target_release = format_settings({
        **target_common,
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "DEPLOYMENT_POSTPROCESSING": "YES",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "VALIDATE_PRODUCT": "YES",
    })

    build_file_entries = "\n".join(
        f"\t\t{build_file_ids[name]} /* {name} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_ids[name]} /* {name} */; }};"
        for name, _ in products
    )
    frameworks_phase_entries = "\n".join(
        f"\t\t\t\t{build_file_ids[name]} /* {name} in Frameworks */,"
        for name, _ in products
    )
    target_dep_entries = "\n".join(
        f"\t\t\t\t{dep_ids[name]} /* {name} */,"
        for name, _ in products
    )
    swift_pkg_dep_entries = "\n".join(
        f"""\t\t{dep_ids[name]} /* {name} */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {pkg_id};
\t\t\tproductName = {name};
\t\t}};"""
        for name, pkg_id in products
    )

    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
{build_file_entries}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{product_id} /* ChatClientKit.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = ChatClientKit.framework; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{sources_group_id} /* ChatClientKit */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = "src/ChatClientKit";
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{frameworks_phase_id} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
{frameworks_phase_entries}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{main_group_id} = {{
			isa = PBXGroup;
			children = (
				{sources_group_id} /* ChatClientKit */,
				{products_group_id} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{products_group_id} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{product_id} /* ChatClientKit.framework */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXHeadersBuildPhase section */
		{headers_phase_id} /* Headers */ = {{
			isa = PBXHeadersBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXHeadersBuildPhase section */

/* Begin PBXNativeTarget section */
		{target_id} /* ChatClientKit */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {target_config_list_id} /* Build configuration list for PBXNativeTarget "ChatClientKit" */;
			buildPhases = (
				{headers_phase_id} /* Headers */,
				{sources_phase_id} /* Sources */,
				{frameworks_phase_id} /* Frameworks */,
				{resources_phase_id} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{sources_group_id} /* ChatClientKit */,
			);
			name = ChatClientKit;
			packageProductDependencies = (
{target_dep_entries}
			);
			productName = ChatClientKit;
			productReference = {product_id} /* ChatClientKit.framework */;
			productType = "com.apple.product-type.framework";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project_id} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 2630;
			}};
			buildConfigurationList = {project_config_list_id} /* Build configuration list for PBXProject "ChatClientKit" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {main_group_id};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{pkg_mlx_lm_id} /* XCLocalSwiftPackageReference "{mlx_lm_rel}" */,
				{pkg_mlx_swift_id} /* XCRemoteSwiftPackageReference "mlx-swift" */,
				{pkg_tokenizers_id} /* XCRemoteSwiftPackageReference "swift-tokenizers" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {products_group_id} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target_id} /* ChatClientKit */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_phase_id} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_phase_id} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{project_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{project_debug}
			}};
			name = Debug;
		}};
		{project_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{project_release}
			}};
			name = Release;
		}};
		{target_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_debug}
			}};
			name = Debug;
		}};
		{target_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_release}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{project_config_list_id} /* Build configuration list for PBXProject "ChatClientKit" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{project_debug_id} /* Debug */,
				{project_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{target_config_list_id} /* Build configuration list for PBXNativeTarget "ChatClientKit" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{target_debug_id} /* Debug */,
				{target_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{pkg_mlx_lm_id} /* XCLocalSwiftPackageReference "{mlx_lm_rel}" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = "{mlx_lm_rel}";
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCRemoteSwiftPackageReference section */
		{pkg_mlx_swift_id} /* XCRemoteSwiftPackageReference "mlx-swift" */ = {{
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "{mlx_swift_repo}";
			requirement = {{
				kind = exactVersion;
				version = {mlx_swift_version};
			}};
		}};
		{pkg_tokenizers_id} /* XCRemoteSwiftPackageReference "swift-tokenizers" */ = {{
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "{tokenizers_repo}";
			requirement = {{
				kind = exactVersion;
				version = {tokenizers_version};
			}};
		}};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
{swift_pkg_dep_entries}
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {project_id} /* Project object */;
}}
"""

    write_text(project_dir / "project.pbxproj", pbx)
    write_text(
        project_dir / "project.xcworkspace" / "contents.xcworkspacedata",
        """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
""",
    )
    write_xcode_scheme(
        project_dir / "xcshareddata" / "xcschemes" / "ChatClientKit.xcscheme",
        target_id,
    )
    print(f"[*] wrote {project_dir}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--mlx-swift-lm", required=True, type=Path)
    args = parser.parse_args()

    root: Path = args.root.resolve()
    mlx_swift_lm_dir: Path = args.mlx_swift_lm.resolve()
    sources_dir = root / "Sources" / "ChatClientKit"
    versions_file = root / "Upstream.versions"

    if not sources_dir.is_dir():
        die(f"ChatClientKit sources missing: {sources_dir}")
    if not (mlx_swift_lm_dir / "Package.swift").is_file():
        die(f"mlx-swift-lm checkout missing Package.swift: {mlx_swift_lm_dir}")
    if not versions_file.is_file():
        die(f"Upstream.versions missing: {versions_file}")

    versions = parse_upstream_versions(versions_file)
    src_dest = root / "build" / "src" / "ChatClientKit"
    copy_chatclientkit_sources(sources_dir, src_dest)
    write_xcode_project(root, mlx_swift_lm_dir, versions)
    print(f"[*] assembled ChatClientKit sources into {src_dest}")


if __name__ == "__main__":
    main()
