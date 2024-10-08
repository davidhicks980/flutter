// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:native_assets_builder/native_assets_builder.dart'
    hide NativeAssetsBuildRunner;
import 'package:native_assets_cli/native_assets_cli_internal.dart';

import '../../../base/file_system.dart';
import '../../../build_info.dart';
import '../../../globals.dart' as globals;
import '../native_assets.dart';
import 'native_assets_host.dart';

/// Dry run the native builds.
///
/// This does not build native assets, it only simulates what the final paths
/// of all assets will be so that this can be embedded in the kernel file and
/// the Xcode project.
Future<Uri?> dryRunNativeAssetsMacOS({
  required NativeAssetsBuildRunner buildRunner,
  required Uri projectUri,
  bool flutterTester = false,
  required FileSystem fileSystem,
}) async {
  if (!await nativeBuildRequired(buildRunner)) {
    return null;
  }

  final Uri buildUri = nativeAssetsBuildUri(projectUri, OSImpl.macOS);
  final Iterable<KernelAsset> nativeAssetPaths = await dryRunNativeAssetsMacOSInternal(
    fileSystem,
    projectUri,
    flutterTester,
    buildRunner,
  );
  final Uri nativeAssetsUri = await writeNativeAssetsYaml(
    KernelAssets(nativeAssetPaths),
    buildUri,
    fileSystem,
  );
  return nativeAssetsUri;
}

Future<Iterable<KernelAsset>> dryRunNativeAssetsMacOSInternal(
  FileSystem fileSystem,
  Uri projectUri,
  bool flutterTester,
  NativeAssetsBuildRunner buildRunner,
) async {
  const OSImpl targetOS = OSImpl.macOS;
  final Uri buildUri = nativeAssetsBuildUri(projectUri, targetOS);

  globals.logger.printTrace('Dry running native assets for $targetOS.');
  final BuildDryRunResult buildDryRunResult = await buildRunner.buildDryRun(
    linkModePreference: LinkModePreferenceImpl.dynamic,
    targetOS: targetOS,
    workingDirectory: projectUri,
    includeParentEnvironment: true,
  );
  ensureNativeAssetsBuildDryRunSucceed(buildDryRunResult);
  // No link hooks in JIT mode.
  final List<AssetImpl> nativeAssets = buildDryRunResult.assets;
  globals.logger.printTrace('Dry running native assets for $targetOS done.');
  final Uri? absolutePath = flutterTester ? buildUri : null;
  final Map<AssetImpl, KernelAsset> assetTargetLocations =
      _assetTargetLocations(
    nativeAssets,
    absolutePath,
  );
  return assetTargetLocations.values;
}

/// Builds native assets.
///
/// If [darwinArchs] is omitted, the current target architecture is used.
///
/// If [flutterTester] is true, absolute paths are emitted in the native
/// assets mapping. This can be used for JIT mode without sandbox on the host.
/// This is used in `flutter test` and `flutter run -d flutter-tester`.
Future<(Uri? nativeAssetsYaml, List<Uri> dependencies)> buildNativeAssetsMacOS({
  required NativeAssetsBuildRunner buildRunner,
  List<DarwinArch>? darwinArchs,
  required Uri projectUri,
  required BuildMode buildMode,
  bool flutterTester = false,
  String? codesignIdentity,
  Uri? yamlParentDirectory,
  required FileSystem fileSystem,
}) async {
  const OSImpl targetOS = OSImpl.macOS;
  final Uri buildUri = nativeAssetsBuildUri(projectUri, targetOS);
  if (!await nativeBuildRequired(buildRunner)) {
    final Uri nativeAssetsYaml = await writeNativeAssetsYaml(
      KernelAssets(),
      yamlParentDirectory ?? buildUri,
      fileSystem,
    );
    return (nativeAssetsYaml, <Uri>[]);
  }

  final List<Target> targets = darwinArchs != null
      ? darwinArchs.map(_getNativeTarget).toList()
      : <Target>[Target.current];
  final BuildModeImpl buildModeCli =
      nativeAssetsBuildMode(buildMode);
  final bool linkingEnabled = buildModeCli == BuildModeImpl.release;

  globals.logger
      .printTrace('Building native assets for $targets $buildModeCli.');
  final List<AssetImpl> nativeAssets = <AssetImpl>[];
  final Set<Uri> dependencies = <Uri>{};
  for (final Target target in targets) {
    final BuildResult buildResult = await buildRunner.build(
      linkModePreference: LinkModePreferenceImpl.dynamic,
      target: target,
      buildMode: buildModeCli,
      workingDirectory: projectUri,
      includeParentEnvironment: true,
      cCompilerConfig: await buildRunner.cCompilerConfig,
      // TODO(dcharkes): Fetch minimum MacOS version from somewhere. https://github.com/flutter/flutter/issues/145104
      targetMacOSVersion: 13,
      linkingEnabled: linkingEnabled,
    );
    ensureNativeAssetsBuildSucceed(buildResult);
    nativeAssets.addAll(buildResult.assets);
    dependencies.addAll(buildResult.dependencies);
    if (linkingEnabled) {
      final LinkResult linkResult = await buildRunner.link(
        linkModePreference: LinkModePreferenceImpl.dynamic,
        target: target,
        buildMode: buildModeCli,
        workingDirectory: projectUri,
        includeParentEnvironment: true,
        cCompilerConfig: await buildRunner.cCompilerConfig,
        buildResult: buildResult,
        // TODO(dcharkes): Fetch minimum MacOS version from somewhere. https://github.com/flutter/flutter/issues/145104
        targetMacOSVersion: 13,
      );
      ensureNativeAssetsLinkSucceed(linkResult);
      nativeAssets.addAll(linkResult.assets);
      dependencies.addAll(linkResult.dependencies);
    }
  }
  globals.logger.printTrace('Building native assets for $targets done.');
  final Uri? absolutePath = flutterTester ? buildUri : null;
  final Map<AssetImpl, KernelAsset> assetTargetLocations =
      _assetTargetLocations(nativeAssets, absolutePath);
  final Map<KernelAssetPath, List<AssetImpl>> fatAssetTargetLocations =
      _fatAssetTargetLocations(nativeAssets, absolutePath);
  if (flutterTester) {
    await _copyNativeAssetsMacOSFlutterTester(
      buildUri,
      fatAssetTargetLocations,
      codesignIdentity,
      buildMode,
      fileSystem,
    );
  } else {
    await _copyNativeAssetsMacOS(
      buildUri,
      fatAssetTargetLocations,
      codesignIdentity,
      buildMode,
      fileSystem,
    );
  }
  final Uri nativeAssetsUri = await writeNativeAssetsYaml(
    KernelAssets(assetTargetLocations.values),
    yamlParentDirectory ?? buildUri,
    fileSystem,
  );
  return (nativeAssetsUri, dependencies.toList());
}

/// Extract the [Target] from a [DarwinArch].
Target _getNativeTarget(DarwinArch darwinArch) {
  return switch (darwinArch) {
    DarwinArch.arm64  => Target.macOSArm64,
    DarwinArch.x86_64 => Target.macOSX64,
    DarwinArch.armv7  => throw Exception('Unknown DarwinArch: $darwinArch.'),
  };
}

Map<KernelAssetPath, List<AssetImpl>> _fatAssetTargetLocations(
  List<AssetImpl> nativeAssets,
  Uri? absolutePath,
) {
  final Set<String> alreadyTakenNames = <String>{};
  final Map<KernelAssetPath, List<AssetImpl>> result =
      <KernelAssetPath, List<AssetImpl>>{};
  final Map<String, KernelAssetPath> idToPath = <String, KernelAssetPath>{};
  for (final AssetImpl asset in nativeAssets) {
    // Use same target path for all assets with the same id.
    final KernelAssetPath path = idToPath[asset.id] ??
        _targetLocationMacOS(
          asset,
          absolutePath,
          alreadyTakenNames,
        ).path;
    idToPath[asset.id] = path;
    result[path] ??= <AssetImpl>[];
    result[path]!.add(asset);
  }
  return result;
}

Map<AssetImpl, KernelAsset> _assetTargetLocations(
  List<AssetImpl> nativeAssets,
  Uri? absolutePath,
) {
  final Set<String> alreadyTakenNames = <String>{};
  final Map<String, KernelAssetPath> idToPath = <String, KernelAssetPath>{};
  final Map<AssetImpl, KernelAsset> result = <AssetImpl, KernelAsset>{};
  for (final AssetImpl asset in nativeAssets) {
    final KernelAssetPath path = idToPath[asset.id] ??
        _targetLocationMacOS(asset, absolutePath, alreadyTakenNames).path;
    idToPath[asset.id] = path;
    result[asset] = KernelAsset(
      id: (asset as NativeCodeAssetImpl).id,
      target: Target.fromArchitectureAndOS(asset.architecture!, asset.os),
      path: path,
    );
  }
  return result;
}

KernelAsset _targetLocationMacOS(
  AssetImpl asset,
  Uri? absolutePath,
  Set<String> alreadyTakenNames,
) {
  final LinkModeImpl linkMode = (asset as NativeCodeAssetImpl).linkMode;
  final KernelAssetPath kernelAssetPath;
  switch (linkMode) {
    case DynamicLoadingSystemImpl _:
      kernelAssetPath = KernelAssetSystemPath(linkMode.uri);
    case LookupInExecutableImpl _:
      kernelAssetPath = KernelAssetInExecutable();
    case LookupInProcessImpl _:
      kernelAssetPath = KernelAssetInProcess();
    case DynamicLoadingBundledImpl _:
      final String fileName = asset.file!.pathSegments.last;
      Uri uri;
      if (absolutePath != null) {
        // Flutter tester needs full host paths.
        uri = absolutePath.resolve(fileName);
      } else {
        // Flutter Desktop needs "absolute" paths inside the app.
        // "relative" in the context of native assets would be relative to the
        // kernel or aot snapshot.
        uri = frameworkUri(fileName, alreadyTakenNames);
      }
      kernelAssetPath = KernelAssetAbsolutePath(uri);
    default:
      throw Exception(
        'Unsupported asset link mode $linkMode in asset $asset',
      );
  }
  return KernelAsset(
    id: asset.id,
    target: Target.fromArchitectureAndOS(asset.architecture!, asset.os),
    path: kernelAssetPath,
  );
}

/// Copies native assets into a framework per dynamic library.
///
/// The framework contains symlinks according to
/// https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/FrameworkAnatomy.html
///
/// For `flutter run -release` a multi-architecture solution is needed. So,
/// `lipo` is used to combine all target architectures into a single file.
///
/// The install name is set so that it matches with the place it will
/// be bundled in the final app. Install names that are referenced in dependent
/// libraries are updated to match the new install name, so that the referenced
/// library can be found the dynamic linker.
///
/// Code signing is also done here, so that it doesn't have to be done in
/// in macos_assemble.sh.
Future<void> _copyNativeAssetsMacOS(
  Uri buildUri,
  Map<KernelAssetPath, List<AssetImpl>> assetTargetLocations,
  String? codesignIdentity,
  BuildMode buildMode,
  FileSystem fileSystem,
) async {
  if (assetTargetLocations.isNotEmpty) {
    globals.logger.printTrace(
      'Copying native assets to ${buildUri.toFilePath()}.',
    );

    final Map<String, String> oldToNewInstallNames = <String, String>{};
    final List<(File, String, Directory)> dylibs = <(File, String, Directory)>[];

    for (final MapEntry<KernelAssetPath, List<AssetImpl>> assetMapping
        in assetTargetLocations.entries) {
      final Uri target = (assetMapping.key as KernelAssetAbsolutePath).uri;
      final List<File> sources = <File>[
        for (final AssetImpl source in assetMapping.value) fileSystem.file(source.file),
      ];
      final Uri targetUri = buildUri.resolveUri(target);
      final String name = targetUri.pathSegments.last;
      final Directory frameworkDir = fileSystem.file(targetUri).parent;
      if (await frameworkDir.exists()) {
        await frameworkDir.delete(recursive: true);
      }
      // MyFramework.framework/                           frameworkDir
      //   MyFramework  -> Versions/Current/MyFramework   dylibLink
      //   Resources    -> Versions/Current/Resources     resourcesLink
      //   Versions/                                      versionsDir
      //     A/                                           versionADir
      //       MyFramework                                dylibFile
      //       Resources/                                 resourcesDir
      //         Info.plist
      //     Current  -> A                                currentLink
      final Directory versionsDir = frameworkDir.childDirectory('Versions');
      final Directory versionADir = versionsDir.childDirectory('A');
      final Directory resourcesDir = versionADir.childDirectory('Resources');
      await resourcesDir.create(recursive: true);
      final File dylibFile = versionADir.childFile(name);
      final Link currentLink = versionsDir.childLink('Current');
      await currentLink.create(fileSystem.path.relative(
        versionADir.path,
        from: currentLink.parent.path,
      ));
      final Link resourcesLink = frameworkDir.childLink('Resources');
      await resourcesLink.create(fileSystem.path.relative(
        resourcesDir.path,
        from: resourcesLink.parent.path,
      ));
      await lipoDylibs(dylibFile, sources);
      final Link dylibLink = frameworkDir.childLink(name);
      await dylibLink.create(fileSystem.path.relative(
        versionsDir.childDirectory('Current').childFile(name).path,
        from: dylibLink.parent.path,
      ));

      final String dylibFileName = dylibFile.basename;
      final String newInstallName = '@rpath/$dylibFileName.framework/$dylibFileName';
      final Set<String> oldInstallNames = await getInstallNamesDylib(dylibFile);
      for (final String oldInstallName in oldInstallNames) {
        oldToNewInstallNames[oldInstallName] = newInstallName;
      }
      dylibs.add((dylibFile, newInstallName, frameworkDir));

      await createInfoPlist(name, resourcesDir);
    }

    for (final (File dylibFile, String newInstallName, Directory frameworkDir) in dylibs) {
      await setInstallNamesDylib(dylibFile, newInstallName, oldToNewInstallNames);
      // Do not code-sign the libraries here with identity. Code-signing
      // for bundled dylibs is done in `macos_assemble.sh embed` because the
      // "Flutter Assemble" target does not have access to the signing identity.
      if (codesignIdentity != null) {
        await codesignDylib(codesignIdentity, buildMode, frameworkDir);
      }
    }

    globals.logger.printTrace('Copying native assets done.');
  }
}

/// Copies native assets for flutter tester.
///
/// For `flutter run -release` a multi-architecture solution is needed. So,
/// `lipo` is used to combine all target architectures into a single file.
///
/// The install names are set to the absolute paths from which the
/// flutter_tester executable with load them. Install names that are
/// referenced in dependent libraries are updated to match the new install name,
/// so that the referenced library can be found the dynamic linker.
///
/// Code signing is also done here.
Future<void> _copyNativeAssetsMacOSFlutterTester(
  Uri buildUri,
  Map<KernelAssetPath, List<AssetImpl>> assetTargetLocations,
  String? codesignIdentity,
  BuildMode buildMode,
  FileSystem fileSystem,
) async {
  if (assetTargetLocations.isNotEmpty) {
    globals.logger.printTrace(
      'Copying native assets to ${buildUri.toFilePath()}.',
    );

    final Map<String, String> oldToNewInstallNames = <String, String>{};
    final List<(File, String)> dylibs = <(File, String)>[];

    for (final MapEntry<KernelAssetPath, List<AssetImpl>> assetMapping
        in assetTargetLocations.entries) {
      final Uri target = (assetMapping.key as KernelAssetAbsolutePath).uri;
      final List<File> sources = <File>[
        for (final AssetImpl source in assetMapping.value) fileSystem.file(source.file),
      ];
      final Uri targetUri = buildUri.resolveUri(target);
      final File dylibFile = fileSystem.file(targetUri);
      final Directory targetParent = dylibFile.parent;
      if (!await targetParent.exists()) {
        await targetParent.create(recursive: true);
      }
      await lipoDylibs(dylibFile, sources);
      final String newInstallName = dylibFile.path;
      final Set<String> oldInstallNames = await getInstallNamesDylib(dylibFile);
      for (final String oldInstallName in oldInstallNames) {
        oldToNewInstallNames[oldInstallName] = newInstallName;
      }
      dylibs.add((dylibFile, newInstallName));
    }

    for (final (File dylibFile, String newInstallName) in dylibs) {
      await setInstallNamesDylib(dylibFile, newInstallName, oldToNewInstallNames);
      await codesignDylib(codesignIdentity, buildMode, dylibFile);
    }

    globals.logger.printTrace('Copying native assets done.');
  }
}
