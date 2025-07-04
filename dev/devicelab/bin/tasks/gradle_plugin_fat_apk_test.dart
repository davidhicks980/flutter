// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_devicelab/framework/apk_utils.dart';
import 'package:flutter_devicelab/framework/framework.dart';
import 'package:flutter_devicelab/framework/task_result.dart';
import 'package:flutter_devicelab/framework/utils.dart';
import 'package:path/path.dart' as path;

Future<void> main() async {
  await task(() async {
    try {
      await runPluginProjectTest((FlutterPluginProject pluginProject) async {
        section('APK content for task assembleDebug without explicit target platform');
        await inDirectory(pluginProject.exampleAndroidPath, () {
          return flutter('build', options: <String>['apk', '--debug']);
        });

        Iterable<String> apkFiles = await getFilesInApk(pluginProject.debugApkPath);

        checkCollectionContains<String>(<String>[
          ...flutterAssets,
          ...debugAssets,
          ...baseApkFiles,
          'lib/armeabi-v7a/libflutter.so',
          'lib/arm64-v8a/libflutter.so',
          // Debug mode intentionally includes `x86_64`.
          'lib/x86_64/libflutter.so',
        ], apkFiles);

        checkCollectionDoesNotContain<String>(<String>[
          'lib/arm64-v8a/libapp.so',
          'lib/armeabi-v7a/libapp.so',
          'lib/x86_64/libapp.so',
        ], apkFiles);

        section('APK content for task assembleRelease without explicit target platform');

        await inDirectory(pluginProject.exampleAndroidPath, () {
          return flutter('build', options: <String>['apk', '--release']);
        });

        apkFiles = await getFilesInApk(pluginProject.releaseApkPath);

        checkCollectionContains<String>(<String>[
          ...flutterAssets,
          ...baseApkFiles,
          'lib/armeabi-v7a/libflutter.so',
          'lib/armeabi-v7a/libapp.so',
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libapp.so',
          'lib/x86_64/libflutter.so',
          'lib/x86_64/libapp.so',
        ], apkFiles);

        checkCollectionDoesNotContain<String>(debugAssets, apkFiles);

        section(
          'APK content for task assembleRelease with target platform = android-arm, android-arm64',
        );

        await inDirectory(pluginProject.exampleAndroidPath, () {
          return flutter(
            'build',
            options: <String>['apk', '--release', '--target-platform=android-arm,android-arm64'],
          );
        });

        apkFiles = await getFilesInApk(pluginProject.releaseApkPath);

        checkCollectionContains<String>(<String>[
          ...flutterAssets,
          ...baseApkFiles,
          'lib/armeabi-v7a/libflutter.so',
          'lib/armeabi-v7a/libapp.so',
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libapp.so',
        ], apkFiles);

        checkCollectionDoesNotContain<String>(debugAssets, apkFiles);

        section(
          'APK content for task assembleRelease with '
          'target platform = android-arm, android-arm64 and split per ABI',
        );

        await inDirectory(pluginProject.exampleAndroidPath, () {
          return flutter(
            'build',
            options: <String>[
              'apk',
              '--release',
              '--split-per-abi',
              '--target-platform=android-arm,android-arm64',
            ],
          );
        });

        final Iterable<String> armApkFiles = await getFilesInApk(pluginProject.releaseArmApkPath);

        checkCollectionContains<String>(<String>[
          ...flutterAssets,
          ...baseApkFiles,
          'lib/armeabi-v7a/libflutter.so',
          'lib/armeabi-v7a/libapp.so',
        ], armApkFiles);

        checkCollectionDoesNotContain<String>(debugAssets, armApkFiles);

        final Iterable<String> arm64ApkFiles = await getFilesInApk(
          pluginProject.releaseArm64ApkPath,
        );

        checkCollectionContains<String>(<String>[
          ...flutterAssets,
          ...baseApkFiles,
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libapp.so',
        ], arm64ApkFiles);

        checkCollectionDoesNotContain<String>(debugAssets, arm64ApkFiles);
      });

      await runProjectTest((FlutterProject project) async {
        section('gradlew assembleRelease');

        await inDirectory(project.rootPath, () {
          return flutter('build', options: <String>['apk', '--release']);
        });

        // When the platform-target isn't specified, we generate the snapshots
        // for arm and arm64.
        final List<String> targetPlatforms = <String>['arm64-v8a', 'armeabi-v7a'];
        for (final String targetPlatform in targetPlatforms) {
          final String androidArmSnapshotPath = path.join(
            project.rootPath,
            'build',
            'app',
            'intermediates',
            'flutter',
            'release',
            targetPlatform,
          );

          final String sharedLibrary = path.join(androidArmSnapshotPath, 'app.so');
          if (!File(sharedLibrary).existsSync()) {
            throw TaskResult.failure("Shared library doesn't exist");
          }
        }

        section('AGP cxx build artifacts');

        final String defaultPath = path.join(project.rootPath, 'android', 'app', '.cxx');

        final String modifiedPath = path.join(project.rootPath, 'build', '.cxx');
        if (Directory(defaultPath).existsSync()) {
          throw TaskResult.failure('Producing unexpected build artifacts in $defaultPath');
        }
        if (!Directory(modifiedPath).existsSync()) {
          throw TaskResult.failure(
            'Not producing external native build output directory in $modifiedPath',
          );
        }
      });

      return TaskResult.success(null);
    } on TaskResult catch (taskResult) {
      return taskResult;
    } catch (e, stackTrace) {
      print('Task exception stack trace:\n$stackTrace');
      return TaskResult.failure(e.toString());
    }
  });
}
