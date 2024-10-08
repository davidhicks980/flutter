// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:native_assets_builder/native_assets_builder.dart'
    hide NativeAssetsBuildRunner;
import 'package:native_assets_cli/native_assets_cli_internal.dart';

import '../../../base/file_system.dart';
import '../../../build_info.dart';
import '../../../globals.dart' as globals;
import '../macos/native_assets_host.dart';
import '../native_assets.dart';

/// Dry run the native builds.
///
/// This does not build native assets, it only simulates what the final paths
/// of all assets will be so that this can be embedded in the kernel file and
/// the Xcode project.
Future<Uri?> dryRunNativeAssetsIOS({
  required NativeAssetsBuildRunner buildRunner,
  required Uri projectUri,
  required FileSystem fileSystem,
}) async {
  if (!await nativeBuildRequired(buildRunner)) {
    return null;
  }

  final Uri buildUri = nativeAssetsBuildUri(projectUri, OSImpl.iOS);
  final Iterable<KernelAsset> assetTargetLocations = await dryRunNativeAssetsIOSInternal(
    fileSystem,
    projectUri,
    buildRunner,
  );
  final Uri nativeAssetsUri = await writeNativeAssetsYaml(
    KernelAssets(assetTargetLocations),
    buildUri,
    fileSystem,
  );
  return nativeAssetsUri;
}

Future<Iterable<KernelAsset>> dryRunNativeAssetsIOSInternal(
  FileSystem fileSystem,
  Uri projectUri,
  NativeAssetsBuildRunner buildRunner,
) async {
  const OSImpl targetOS = OSImpl.iOS;
  globals.logger.printTrace('Dry running native assets for $targetOS.');
  final BuildDryRunResult buildDryRunResult = await buildRunner.buildDryRun(
    linkModePreference: LinkModePreferenceImpl.dynamic,
    targetOS: targetOS,
    workingDirectory: projectUri,
    includeParentEnvironment: true,
  );
  ensureNativeAssetsBuildDryRunSucceed(buildDryRunResult);
  // No link hooks in JIT.
  final List<AssetImpl> nativeAssets = buildDryRunResult.assets;
  globals.logger.printTrace('Dry running native assets for $targetOS done.');
  return _assetTargetLocations(nativeAssets).values;
}

/// Builds native assets.
Future<List<Uri>> buildNativeAssetsIOS({
  required NativeAssetsBuildRunner buildRunner,
  required List<DarwinArch> darwinArchs,
  required EnvironmentType environmentType,
  required Uri projectUri,
  required BuildMode buildMode,
  String? codesignIdentity,
  required Uri yamlParentDirectory,
  required FileSystem fileSystem,
}) async {
  if (!await nativeBuildRequired(buildRunner)) {
    await writeNativeAssetsYaml(KernelAssets(), yamlParentDirectory, fileSystem);
    return <Uri>[];
  }

  final List<Target> targets = darwinArchs.map(_getNativeTarget).toList();
  final BuildModeImpl buildModeCli = nativeAssetsBuildMode(buildMode);
  final bool linkingEnabled = buildModeCli == BuildModeImpl.release;

  const OSImpl targetOS = OSImpl.iOS;
  final Uri buildUri = nativeAssetsBuildUri(projectUri, targetOS);
  final IOSSdkImpl iosSdk = _getIOSSdkImpl(environmentType);

  globals.logger.printTrace('Building native assets for $targets $buildModeCli.');
  final List<AssetImpl> nativeAssets = <AssetImpl>[];
  final Set<Uri> dependencies = <Uri>{};
  for (final Target target in targets) {
    final BuildResult buildResult = await buildRunner.build(
      linkModePreference: LinkModePreferenceImpl.dynamic,
      target: target,
      targetIOSSdkImpl: iosSdk,
      buildMode: buildModeCli,
      workingDirectory: projectUri,
      includeParentEnvironment: true,
      cCompilerConfig: await buildRunner.cCompilerConfig,
      // TODO(dcharkes): Fetch minimum iOS version from somewhere. https://github.com/flutter/flutter/issues/145104
      targetIOSVersion: 12,
      linkingEnabled: linkingEnabled,
    );
    ensureNativeAssetsBuildSucceed(buildResult);
    nativeAssets.addAll(buildResult.assets);
    dependencies.addAll(buildResult.dependencies);
    if (linkingEnabled) {
      final LinkResult linkResult = await buildRunner.link(
        linkModePreference: LinkModePreferenceImpl.dynamic,
        target: target,
        targetIOSSdkImpl: iosSdk,
        buildMode: buildModeCli,
        workingDirectory: projectUri,
        includeParentEnvironment: true,
        cCompilerConfig: await buildRunner.cCompilerConfig,
        buildResult: buildResult,
        // TODO(dcharkes): Fetch minimum iOS version from somewhere. https://github.com/flutter/flutter/issues/145104
        targetIOSVersion: 12,
      );
      ensureNativeAssetsLinkSucceed(linkResult);
      nativeAssets.addAll(linkResult.assets);
      dependencies.addAll(linkResult.dependencies);
    }
  }
  globals.logger.printTrace('Building native assets for $targets done.');
  final Map<KernelAssetPath, List<AssetImpl>> fatAssetTargetLocations =
      _fatAssetTargetLocations(nativeAssets);
  await _copyNativeAssetsIOS(
    buildUri,
    fatAssetTargetLocations,
    codesignIdentity,
    buildMode,
    fileSystem,
  );

  final Map<AssetImpl, KernelAsset> assetTargetLocations =
      _assetTargetLocations(nativeAssets);
  await writeNativeAssetsYaml(
    KernelAssets(assetTargetLocations.values),
    yamlParentDirectory,
    fileSystem,
  );
  return dependencies.toList();
}

IOSSdkImpl _getIOSSdkImpl(EnvironmentType environmentType) {
  return switch (environmentType) {
    EnvironmentType.physical  => IOSSdkImpl.iPhoneOS,
    EnvironmentType.simulator => IOSSdkImpl.iPhoneSimulator,
  };
}

/// Extract the [Target] from a [DarwinArch].
Target _getNativeTarget(DarwinArch darwinArch) {
  return switch (darwinArch) {
    DarwinArch.armv7  => Target.iOSArm,
    DarwinArch.arm64  => Target.iOSArm64,
    DarwinArch.x86_64 => Target.iOSX64,
  };
}

Map<KernelAssetPath, List<AssetImpl>> _fatAssetTargetLocations(
    List<AssetImpl> nativeAssets) {
  final Set<String> alreadyTakenNames = <String>{};
  final Map<KernelAssetPath, List<AssetImpl>> result =
      <KernelAssetPath, List<AssetImpl>>{};
  final Map<String, KernelAssetPath> idToPath = <String, KernelAssetPath>{};
  for (final AssetImpl asset in nativeAssets) {
    // Use same target path for all assets with the same id.
    final KernelAssetPath path = idToPath[asset.id] ??
        _targetLocationIOS(
          asset,
          alreadyTakenNames,
        ).path;
    idToPath[asset.id] = path;
    result[path] ??= <AssetImpl>[];
    result[path]!.add(asset);
  }
  return result;
}

Map<AssetImpl, KernelAsset> _assetTargetLocations(
    List<AssetImpl> nativeAssets) {
  final Set<String> alreadyTakenNames = <String>{};
  final Map<String, KernelAssetPath> idToPath = <String, KernelAssetPath>{};
  final Map<AssetImpl, KernelAsset> result = <AssetImpl, KernelAsset>{};
  for (final AssetImpl asset in nativeAssets) {
    final KernelAssetPath path = idToPath[asset.id] ??
        _targetLocationIOS(asset, alreadyTakenNames).path;
    idToPath[asset.id] = path;
    result[asset] = KernelAsset(
      id: (asset as NativeCodeAssetImpl).id,
      target: Target.fromArchitectureAndOS(asset.architecture!, asset.os),
      path: path,
    );
  }
  return result;
}

KernelAsset _targetLocationIOS(AssetImpl asset, Set<String> alreadyTakenNames) {
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
      kernelAssetPath = KernelAssetAbsolutePath(frameworkUri(
        fileName,
        alreadyTakenNames,
      ));
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
/// For `flutter run -release` a multi-architecture solution is needed. So,
/// `lipo` is used to combine all target architectures into a single file.
///
/// The install name is set so that it matches with the place it will
/// be bundled in the final app. Install names that are referenced in dependent
/// libraries are updated to match the new install name, so that the referenced
/// library can be found by the dynamic linker.
///
/// Code signing is also done here, so that it doesn't have to be done in
/// in xcode_backend.dart.
Future<void> _copyNativeAssetsIOS(
  Uri buildUri,
  Map<KernelAssetPath, List<AssetImpl>> assetTargetLocations,
  String? codesignIdentity,
  BuildMode buildMode,
  FileSystem fileSystem,
) async {
  if (assetTargetLocations.isNotEmpty) {
    globals.logger
        .printTrace('Copying native assets to ${buildUri.toFilePath()}.');

    final Map<String, String> oldToNewInstallNames = <String, String>{};
    final List<(File, String, Directory)> dylibs = <(File, String, Directory)>[];

    for (final MapEntry<KernelAssetPath, List<AssetImpl>> assetMapping
        in assetTargetLocations.entries) {
      final Uri target = (assetMapping.key as KernelAssetAbsolutePath).uri;
      final List<File> sources = <File>[
        for (final AssetImpl source in assetMapping.value) fileSystem.file(source.file)
      ];
      final Uri targetUri = buildUri.resolveUri(target);
      final File dylibFile = fileSystem.file(targetUri);
      final Directory frameworkDir = dylibFile.parent;
      if (!await frameworkDir.exists()) {
        await frameworkDir.create(recursive: true);
      }
      await lipoDylibs(dylibFile, sources);

      final String dylibFileName = dylibFile.basename;
      final String newInstallName = '@rpath/$dylibFileName.framework/$dylibFileName';
      final Set<String> oldInstallNames = await getInstallNamesDylib(dylibFile);
      for (final String oldInstallName in oldInstallNames) {
        oldToNewInstallNames[oldInstallName] = newInstallName;
      }
      dylibs.add((dylibFile, newInstallName, frameworkDir));

      // TODO(knopp): Wire the value once there is a way to configure that in the hook.
      // https://github.com/dart-lang/native/issues/1133
      await createInfoPlist(targetUri.pathSegments.last, frameworkDir, minimumIOSVersion: '12.0');
    }

    for (final (File dylibFile, String newInstallName, Directory frameworkDir) in dylibs) {
      await setInstallNamesDylib(dylibFile, newInstallName, oldToNewInstallNames);
      await codesignDylib(codesignIdentity, buildMode, frameworkDir);
    }

    globals.logger.printTrace('Copying native assets done.');
  }
}
