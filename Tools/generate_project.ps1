# Regenerates CameraApp.xcodeproj/project.pbxproj from the source tree.
#
# Why a generator instead of a hand-written project file: the project is kept in
# the legacy pbxproj format (objectVersion 56) with explicit file references, so it
# opens in Xcode 14, 15, 16 and 26 alike. Modern "synchronized folder" projects
# (objectVersion 77) only open in Xcode 16+, which rules out older Intel Macs.
#
# Usage:  powershell -ExecutionPolicy Bypass -File Tools/generate_project.ps1
# Run after adding or removing a .swift file. CI runs it automatically.

param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$TargetName  = "CameraApp"
)

$ErrorActionPreference = "Stop"
$sourceRoot = Join-Path $ProjectRoot $TargetName

if (-not (Test-Path $sourceRoot)) {
    throw "Source folder not found: $sourceRoot"
}

$T = [char]9   # tab
$Q = '"'       # quote

# ---------------------------------------------------------------- helpers

function Get-Id([string]$seed) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    $hex = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    return $hex.Substring(0, 24)
}

# ---------------------------------------------------------------- collect

$swiftFiles = @(Get-ChildItem -Path $sourceRoot -Recurse -Filter *.swift -File | Sort-Object FullName)
$assetDirs  = @(Get-ChildItem -Path $sourceRoot -Recurse -Directory | Where-Object { $_.Name -like "*.xcassets" } | Sort-Object FullName)

if ($swiftFiles.Count -eq 0) { throw "No Swift files found under $sourceRoot" }

Write-Host ("Found {0} Swift files, {1} asset catalogs" -f $swiftFiles.Count, $assetDirs.Count)

$entries = [System.Collections.ArrayList]::new()
foreach ($f in $swiftFiles) {
    $rel = $f.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
    [void]$entries.Add([pscustomobject]@{ Rel = $rel; Kind = 'swift' })
}
foreach ($d in $assetDirs) {
    $rel = $d.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
    [void]$entries.Add([pscustomobject]@{ Rel = $rel; Kind = 'asset' })
}

# ---------------------------------------------------------------- ids

$projectId      = Get-Id 'P:project'
$targetId       = Get-Id 'P:target'
$productId      = Get-Id 'P:product'
$productsGroupId = Get-Id 'P:products'
$sourceGroupId  = Get-Id 'P:sourceGroup'
$sourcesPhase   = Get-Id 'P:sources'
$frameworksPhase = Get-Id 'P:frameworks'
$resourcesPhase = Get-Id 'P:resources'
$projConfigList = Get-Id 'P:projConfigList'
$targetConfigList = Get-Id 'P:targetConfigList'
$projDebugId    = Get-Id 'P:projDebug'
$projReleaseId  = Get-Id 'P:projRelease'
$targetDebugId  = Get-Id 'P:targetDebug'
$targetReleaseId = Get-Id 'P:targetRelease'
$rootGroupId    = Get-Id 'P:rootGroup'

# ---------------------------------------------------------------- per-file records

$fileRefLines   = [System.Collections.ArrayList]::new()
$buildFileLines = [System.Collections.ArrayList]::new()
$groupChildLines = [System.Collections.ArrayList]::new()
$sourcesLines   = [System.Collections.ArrayList]::new()
$resourcesLines = [System.Collections.ArrayList]::new()
$groupIds       = [System.Collections.ArrayList]::new()

foreach ($e in $entries) {
    $fileId   = Get-Id ("F:" + $e.Rel)
    $buildId  = Get-Id ("B:" + $e.Rel)
    $groupId  = Get-Id ("G:" + $e.Rel)
    $name     = [System.IO.Path]::GetFileName($e.Rel)

    [void]$groupIds.Add($groupId)

    # The file reference path must be the path RELATIVE TO THE GROUP ROOT
    # (i.e. "App/CameraApp.swift"), not just the leaf name. Using only the leaf
    # makes Xcode look for CameraApp/CameraApp.swift and mark every file as a
    # "recovered reference".
    if ($e.Kind -eq 'swift') {
        [void]$fileRefLines.Add(($T + $fileId + ' /* ' + $e.Rel + ' */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ' + $Q + $e.Rel + $Q + '; sourceTree = ' + $Q + '<group>' + $Q + '; };'))
        [void]$buildFileLines.Add(($T + $buildId + ' /* ' + $name + ' in Sources */ = {isa = PBXBuildFile; fileRef = ' + $fileId + ' /* ' + $e.Rel + ' */; };'))
        [void]$sourcesLines.Add(($T + $T + $buildId + ' /* ' + $name + ' in Sources */,'))
    } else {
        [void]$fileRefLines.Add(($T + $fileId + ' /* ' + $e.Rel + ' */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = ' + $Q + $e.Rel + $Q + '; sourceTree = ' + $Q + '<group>' + $Q + '; };'))
        [void]$buildFileLines.Add(($T + $buildId + ' /* ' + $name + ' in Resources */ = {isa = PBXBuildFile; fileRef = ' + $fileId + ' /* ' + $e.Rel + ' */; };'))
        [void]$resourcesLines.Add(($T + $T + $buildId + ' /* ' + $name + ' in Resources */,'))
    }

    [void]$groupChildLines.Add(($T + $T + $groupId + ' /* ' + $e.Rel + ' */,'))
}

# ---------------------------------------------------------------- build settings

$projectCommon = @(
    'ALWAYS_SEARCH_USER_PATHS = NO;',
    'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;',
    'CLANG_ANALYZER_NONNULL = YES;',
    'CLANG_ENABLE_MODULES = YES;',
    'CLANG_ENABLE_OBJC_ARC = YES;',
    'CLANG_WARN_DOCUMENTATION_COMMENTS = YES;',
    'COPY_PHASE_STRIP = NO;',
    'ENABLE_STRICT_OBJC_MSGSEND = YES;',
    'ENABLE_USER_SCRIPT_SANDBOXING = YES;',
    'GCC_C_LANGUAGE_STANDARD = gnu17;',
    'GCC_NO_COMMON_BLOCKS = YES;',
    'IPHONEOS_DEPLOYMENT_TARGET = 17.0;',
    'MTL_FAST_MATH = YES;',
    'SDKROOT = iphoneos;',
    'SWIFT_VERSION = 5.0;'
)

$projectDebug = @(
    'DEBUG_INFORMATION_FORMAT = dwarf;',
    'ENABLE_TESTABILITY = YES;',
    'GCC_DYNAMIC_NO_PIC = NO;',
    'GCC_OPTIMIZATION_LEVEL = 0;',
    ('GCC_PREPROCESSOR_DEFINITIONS = (' + $T + $Q + 'DEBUG=1' + $Q + ',' + $T + $Q + '$(inherited)' + $Q + ',' + $T + ');'),
    'MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;',
    'ONLY_ACTIVE_ARCH = YES;',
    ('SWIFT_ACTIVE_COMPILATION_CONDITIONS = ' + $Q + 'DEBUG $(inherited)' + $Q + ';'),
    'SWIFT_OPTIMIZATION_LEVEL = ' + $Q + '-Onone' + $Q + ';'
)

$projectRelease = @(
    'DEBUG_INFORMATION_FORMAT = ' + $Q + 'dwarf-with-dsym' + $Q + ';',
    'ENABLE_NS_ASSERTIONS = NO;',
    'MTL_ENABLE_DEBUG_INFO = NO;',
    'SWIFT_COMPILATION_MODE = wholemodule;',
    'VALIDATE_PRODUCT = YES;'
)

# Usage strings live in a separate UTF-8 JSON file rather than inline in this
# script: PowerShell 5.1 reads BOM-less scripts as ANSI, which would mangle the
# Cyrillic. Reading the file with an explicit encoding avoids that entirely.
$usagePath = Join-Path $ProjectRoot 'Resources/Info/UsageDescriptions.json'
if (-not (Test-Path $usagePath)) {
    throw "Usage descriptions not found: $usagePath"
}
$usage = ConvertFrom-Json ([System.IO.File]::ReadAllText($usagePath, [System.Text.Encoding]::UTF8))

$targetCommon = @(
    'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;',
    'CODE_SIGN_STYLE = Automatic;',
    'CURRENT_PROJECT_VERSION = 1;',
    'ENABLE_PREVIEWS = YES;',
    'GENERATE_INFOPLIST_FILE = YES;',
    'INFOPLIST_KEY_CFBundleDisplayName = Frame;',
    ('INFOPLIST_KEY_NSCameraUsageDescription = ' + $Q + $usage.NSCameraUsageDescription + $Q + ';'),
    ('INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = ' + $Q + $usage.NSPhotoLibraryAddUsageDescription + $Q + ';'),
    'INFOPLIST_KEY_UILaunchScreen_Generation = YES;',
    'INFOPLIST_KEY_UIRequiresFullScreen = YES;',
    'INFOPLIST_KEY_UIStatusBarHidden = YES;',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;',
    ('LD_RUNPATH_SEARCH_PATHS = (' + $T + $Q + '$(inherited)' + $Q + ',' + $T + $Q + '@executable_path/Frameworks' + $Q + ',' + $T + ');'),
    'MARKETING_VERSION = 1.0;',
    'PRODUCT_BUNDLE_IDENTIFIER = com.frameapp.CameraApp;',
    'PRODUCT_NAME = ' + $Q + '$(TARGET_NAME)' + $Q + ';',
    'SWIFT_EMIT_LOC_STRINGS = YES;',
    'TARGETED_DEVICE_FAMILY = 1;'
)

function Emit-Config([string]$id, [string]$name, [string[]]$settings) {
    $lines = @()
    $lines += ($T + $id + ' /* ' + $name + ' */ = {')
    $lines += ($T + $T + 'isa = XCBuildConfiguration;')
    $lines += ($T + $T + 'buildSettings = {')
    foreach ($s in $settings) { $lines += ($T + $T + $T + $s) }
    $lines += ($T + $T + '};')
    $lines += ($T + $T + 'name = ' + $name + ';')
    $lines += ($T + '};')
    return $lines
}

# ---------------------------------------------------------------- assemble

$out = [System.Collections.ArrayList]::new()
[void]$out.Add('// !$*UTF8*$!')
[void]$out.Add('{')
[void]$out.Add($T + 'archiveVersion = 1;')
[void]$out.Add($T + 'classes = {')
[void]$out.Add($T + '};')
[void]$out.Add($T + 'objectVersion = 56;')
[void]$out.Add($T + 'objects = {')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXBuildFile section */')
foreach ($l in $buildFileLines) { [void]$out.Add($l) }
[void]$out.Add('/* End PBXBuildFile section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXFileReference section */')
foreach ($l in $fileRefLines) { [void]$out.Add($l) }
[void]$out.Add(($T + $productId + ' /* ' + $TargetName + '.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ' + $Q + $TargetName + '.app' + $Q + '; sourceTree = BUILT_PRODUCTS_DIR; };'))
[void]$out.Add('/* End PBXFileReference section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXFrameworksBuildPhase section */')
[void]$out.Add($T + $frameworksPhase + ' /* Frameworks */ = {')
[void]$out.Add($T + $T + 'isa = PBXFrameworksBuildPhase;')
[void]$out.Add($T + $T + 'buildActionMask = 2147483647;')
[void]$out.Add($T + $T + 'files = (')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'runOnlyForDeploymentPostprocessing = 0;')
[void]$out.Add($T + '};')
[void]$out.Add('/* End PBXFrameworksBuildPhase section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXGroup section */')

# Source group: one reference per file, path relative to CameraApp/.
[void]$out.Add($T + $sourceGroupId + ' /* ' + $TargetName + ' */ = {')
[void]$out.Add($T + $T + 'isa = PBXGroup;')
[void]$out.Add($T + $T + 'children = (')
foreach ($l in $groupChildLines) { [void]$out.Add($l) }
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'path = ' + $Q + $TargetName + $Q + ';')
[void]$out.Add($T + $T + 'sourceTree = ' + $Q + '<group>' + $Q + ';')
[void]$out.Add($T + '};')

[void]$out.Add($T + $productsGroupId + ' /* Products */ = {')
[void]$out.Add($T + $T + 'isa = PBXGroup;')
[void]$out.Add($T + $T + 'children = (')
[void]$out.Add($T + $T + $T + $productId + ' /* ' + $TargetName + '.app */,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'name = Products;')
[void]$out.Add($T + $T + 'sourceTree = ' + $Q + '<group>' + $Q + ';')
[void]$out.Add($T + '};')

[void]$out.Add($T + $rootGroupId + ' /* Root group */ = {')
[void]$out.Add($T + $T + 'isa = PBXGroup;')
[void]$out.Add($T + $T + 'children = (')
[void]$out.Add($T + $T + $T + $sourceGroupId + ' /* ' + $TargetName + ' */,')
[void]$out.Add($T + $T + $T + $productsGroupId + ' /* Products */,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'sourceTree = ' + $Q + '<group>' + $Q + ';')
[void]$out.Add($T + '};')
[void]$out.Add('/* End PBXGroup section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXNativeTarget section */')
[void]$out.Add($T + $targetId + ' /* ' + $TargetName + ' */ = {')
[void]$out.Add($T + $T + 'isa = PBXNativeTarget;')
[void]$out.Add($T + $T + 'buildConfigurationList = ' + $targetConfigList + ' /* Build configuration list for PBXNativeTarget ' + $Q + $TargetName + $Q + ' */;')
[void]$out.Add($T + $T + 'buildPhases = (')
[void]$out.Add($T + $T + $T + $sourcesPhase + ' /* Sources */,')
[void]$out.Add($T + $T + $T + $frameworksPhase + ' /* Frameworks */,')
[void]$out.Add($T + $T + $T + $resourcesPhase + ' /* Resources */,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'buildRules = (')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'dependencies = (')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'name = ' + $TargetName + ';')
[void]$out.Add($T + $T + 'packageProductDependencies = (')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'productName = ' + $TargetName + ';')
[void]$out.Add($T + $T + 'productReference = ' + $productId + ' /* ' + $TargetName + '.app */;')
[void]$out.Add($T + $T + 'productType = ' + $Q + 'com.apple.product-type.application' + $Q + ';')
[void]$out.Add($T + '};')
[void]$out.Add('/* End PBXNativeTarget section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXProject section */')
[void]$out.Add($T + $projectId + ' /* Project object */ = {')
[void]$out.Add($T + $T + 'isa = PBXProject;')
[void]$out.Add($T + $T + 'attributes = {')
[void]$out.Add($T + $T + $T + 'BuildIndependentTargetsInParallel = 1;')
[void]$out.Add($T + $T + $T + 'LastUpgradeCheck = 1600;')
[void]$out.Add($T + $T + $T + 'TargetAttributes = {')
[void]$out.Add($T + $T + $T + $T + $targetId + ' = {')
[void]$out.Add($T + $T + $T + $T + $T + 'CreatedOnToolsVersion = 15.0;')
[void]$out.Add($T + $T + $T + $T + '};')
[void]$out.Add($T + $T + $T + '};')
[void]$out.Add($T + $T + '};')
[void]$out.Add($T + $T + 'buildConfigurationList = ' + $projConfigList + ' /* Build configuration list for PBXProject ' + $Q + $TargetName + $Q + ' */;')
[void]$out.Add($T + $T + 'compatibilityVersion = ' + $Q + 'Xcode 14.0' + $Q + ';')
[void]$out.Add($T + $T + 'developmentRegion = ru;')
[void]$out.Add($T + $T + 'hasScannedForEncodings = 0;')
[void]$out.Add($T + $T + 'knownRegions = (')
[void]$out.Add($T + $T + $T + 'ru,')
[void]$out.Add($T + $T + $T + 'en,')
[void]$out.Add($T + $T + $T + 'Base,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'mainGroup = ' + $rootGroupId + ' /* Root group */;')
[void]$out.Add($T + $T + 'productRefGroup = ' + $productsGroupId + ' /* Products */;')
[void]$out.Add($T + $T + 'projectDirPath = ' + $Q + $Q + ';')
[void]$out.Add($T + $T + 'projectRoot = ' + $Q + $Q + ';')
[void]$out.Add($T + $T + 'targets = (')
[void]$out.Add($T + $T + $T + $targetId + ' /* ' + $TargetName + ' */,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + '};')
[void]$out.Add('/* End PBXProject section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXResourcesBuildPhase section */')
[void]$out.Add($T + $resourcesPhase + ' /* Resources */ = {')
[void]$out.Add($T + $T + 'isa = PBXResourcesBuildPhase;')
[void]$out.Add($T + $T + 'buildActionMask = 2147483647;')
[void]$out.Add($T + $T + 'files = (')
foreach ($l in $resourcesLines) { [void]$out.Add($l) }
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'runOnlyForDeploymentPostprocessing = 0;')
[void]$out.Add($T + '};')
[void]$out.Add('/* End PBXResourcesBuildPhase section */')

[void]$out.Add('')
[void]$out.Add('/* Begin PBXSourcesBuildPhase section */')
[void]$out.Add($T + $sourcesPhase + ' /* Sources */ = {')
[void]$out.Add($T + $T + 'isa = PBXSourcesBuildPhase;')
[void]$out.Add($T + $T + 'buildActionMask = 2147483647;')
[void]$out.Add($T + $T + 'files = (')
foreach ($l in $sourcesLines) { [void]$out.Add($l) }
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'runOnlyForDeploymentPostprocessing = 0;')
[void]$out.Add($T + '};')
[void]$out.Add('/* End PBXSourcesBuildPhase section */')

[void]$out.Add('')
[void]$out.Add('/* Begin XCBuildConfiguration section */')
foreach ($l in (Emit-Config $projDebugId 'Debug' ($projectCommon + $projectDebug))) { [void]$out.Add($l) }
foreach ($l in (Emit-Config $projReleaseId 'Release' ($projectCommon + $projectRelease))) { [void]$out.Add($l) }
foreach ($l in (Emit-Config $targetDebugId 'Debug' $targetCommon)) { [void]$out.Add($l) }
foreach ($l in (Emit-Config $targetReleaseId 'Release' $targetCommon)) { [void]$out.Add($l) }
[void]$out.Add('/* End XCBuildConfiguration section */')

[void]$out.Add('')
[void]$out.Add('/* Begin XCConfigurationList section */')
[void]$out.Add($T + $projConfigList + ' /* Build configuration list for PBXProject ' + $Q + $TargetName + $Q + ' */ = {')
[void]$out.Add($T + $T + 'isa = XCConfigurationList;')
[void]$out.Add($T + $T + 'buildConfigurations = (')
[void]$out.Add($T + $T + $T + $projDebugId + ' /* Debug */,')
[void]$out.Add($T + $T + $T + $projReleaseId + ' /* Release */,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'defaultConfigurationIsVisible = 0;')
[void]$out.Add($T + $T + 'defaultConfigurationName = Release;')
[void]$out.Add($T + '};')
[void]$out.Add($T + $targetConfigList + ' /* Build configuration list for PBXNativeTarget ' + $Q + $TargetName + $Q + ' */ = {')
[void]$out.Add($T + $T + 'isa = XCConfigurationList;')
[void]$out.Add($T + $T + 'buildConfigurations = (')
[void]$out.Add($T + $T + $T + $targetDebugId + ' /* Debug */,')
[void]$out.Add($T + $T + $T + $targetReleaseId + ' /* Release */,')
[void]$out.Add($T + $T + ');')
[void]$out.Add($T + $T + 'defaultConfigurationIsVisible = 0;')
[void]$out.Add($T + $T + 'defaultConfigurationName = Release;')
[void]$out.Add($T + '};')
[void]$out.Add('/* End XCConfigurationList section */')

[void]$out.Add($T + '};')
[void]$out.Add($T + 'rootObject = ' + $projectId + ' /* Project object */;')
[void]$out.Add('}')

$projectDir = Join-Path $ProjectRoot ($TargetName + '.xcodeproj')
if (-not (Test-Path $projectDir)) {
    [void](New-Item -ItemType Directory -Path $projectDir)
}

$content = ($out -join "`n") + "`n"
$path = Join-Path $projectDir 'project.pbxproj'
[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))

# Verify every generated file reference resolves to a file that actually exists.
# A wrong `path` makes Xcode silently show "recovered reference" and fail the
# build with "Build input file cannot be found" — expensive to debug from the
# far side, trivial to catch here.
$missing = @()
foreach ($e in $entries) {
    $full = Join-Path $sourceRoot ($e.Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $full)) { $missing += $e.Rel }
}
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'ERROR: these file references do not exist on disk:' -ForegroundColor Red
    foreach ($m in $missing) { Write-Host ("  " + $m) -ForegroundColor Red }
    throw 'Project file would contain broken references.'
}

Write-Host ''
Write-Host ("Wrote {0}" -f $path)
Write-Host ('  objectVersion 56 - opens in Xcode 14, 15, 16 and 26')
Write-Host ('  {0} sources, {1} asset catalogs' -f $swiftFiles.Count, $assetDirs.Count)
Write-Host ('  verified: all {0} file references resolve on disk' -f $entries.Count)