// release.dart
import 'dart:convert';
import 'dart:io';

const supportedFlavors = ['workplacebyls', 'workplacebytsphub', 'tiabytsp'];
const supportedPlatforms = ['android', 'ios'];
const versionFilePath = 'version.json';
const changelogFilePath = 'CHANGELOG.md';
const flutterVersion = '3.29.1';

void main(List<String> args) async {
  if (args.isEmpty || args.contains('--help')) {
    printHelp();
    exit(0);
  }

  final command = args[0];

  switch (command) {
    case 'bump':
      await handleBump(args.skip(1).toList());
      break;
    case 'bump-all':
      await handleBumpAll();
      break;
    case 'release':
      await handleRelease(args.skip(1).toList());
      break;
    case 'release-all':
      await handleReleaseAll();
      break;
    default:
      print('❌ Unknown command: $command\n');
      printHelp();
      exit(1);
  }
}

void printHelp() {
  print('''
Usage:
  dart release.dart <command> [options]

Commands:
  bump <flavor> <platform>        Bump version for specific flavor/platform
  bump-all                        Bump build numbers for all flavors/platforms
  release <flavor> <platform>     Bump + shorebird release + fastlane publish
  release-all                     Perform release for all combinations
  --help                          Show this help menu
''');
}

Future<Map<String, dynamic>> readVersionFile() async {
  final file = File(versionFilePath);
  if (!file.existsSync()) throw 'Missing $versionFilePath';
  return jsonDecode(await file.readAsString());
}

Future<void> writeVersionFile(Map<String, dynamic> json) async {
  final file = File(versionFilePath);
  await file.writeAsString(JsonEncoder.withIndent('  ').convert(json));
}

Future<void> appendChangelog(
    String flavor, String platform, String buildName, int buildNumber) async {
  final changelog = File(changelogFilePath);
  final date = DateTime.now().toIso8601String().split('T').first;
  final entry = '- [$date] $flavor ($platform): $buildName+$buildNumber\n';
  await changelog.writeAsString(entry, mode: FileMode.append);
}

Future<void> updatePubspecYaml(String buildName, int buildNumber) async {
  final file = File('pubspec.yaml');
  final lines = await file.readAsLines();
  final updated = lines.map((line) {
    if (line.startsWith('version:')) {
      return 'version: $buildName+$buildNumber';
    }
    return line;
  }).toList();
  await file.writeAsString(updated.join('\n'));
  print('📝 Updated pubspec.yaml with version: $buildName+$buildNumber');
}

Future<void> updateCodemagicYaml(String buildName, int buildNumber) async {
  final file = File('codemagic.yaml');
  if (!file.existsSync()) return;
  final lines = await file.readAsLines();
  final updated = lines.map((line) {
    if (line.contains('BUILD_NAME')) {
      return '      BUILD_NAME: "$buildName"';
    } else if (line.contains('BUILD_NUMBER')) {
      return '      BUILD_NUMBER: "$buildNumber"';
    }
    return line;
  }).toList();
  await file.writeAsString(updated.join('\n'));
  print('📝 Updated codemagic.yaml with BUILD_NAME and BUILD_NUMBER');
}

String getAabPath(String flavor) {
  // final capitalized = flavor[0].toUpperCase() + flavor.substring(1);
  final variantName = '${flavor}Release';
  return 'build/app/outputs/bundle/$variantName/app-$flavor-release.aab';
}

Future<void> uploadToGooglePlay(String flavor) async {
  final aabPath = getAabPath(flavor);
  if (!File(aabPath).existsSync()) {
    print('❌ AAB not found. Did you run `flutter build appbundle`?');
    return;
  }

  final credentials = await loadCredentials(flavor);
  final serviceAccountPath = credentials['google_play'];

  print('📤 Uploading $aabPath to Google Play...');
  final result = await Process.run('fastlane', [
    'supply',
    '--aab',
    aabPath,
    '--package_name',
    getPackageName(flavor),
    '--track',
    'production',
    '--json_key',
    serviceAccountPath,
    '--skip_upload_metadata',
    '--skip_upload_images',
    '--skip_upload_screenshots'
  ]);

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode == 0) {
    print('✅ Uploaded to Google Play Store');
  } else {
    print('❌ Google Play upload failed');
  }
}

String getIpaPath(String flavor) {
  switch (flavor) {
    case 'tiabytsp':
      return 'build/ios/ipa/TIA by TSP.ipa';
    case 'workplacebyls':
      return 'build/ios/ipa/Workplace By LS.ipa';
    case 'workplacebytsphub':
      return 'build/ios/ipa/Workplace By TSPHub.ipa';
    default:
      throw '❌ Unknown flavor for IPA: $flavor';
  }
}

Future<void> uploadToAppStore(String flavor) async {
  final ipaPath = getIpaPath(flavor);
  if (!File(ipaPath).existsSync()) {
    print('❌ IPA not found at $ipaPath');
    return;
  }

  final credentials = await loadCredentials(flavor);
  print('📤 Uploading $ipaPath to App Store Connect...');
  final result = await Process.run('fastlane', [
    'deliver',
    '--ipa',
    ipaPath,
    '--skip_metadata',
    '--skip_screenshots',
    '--submit_for_review',
    '--automatic_release',
    '--api_key_path',
    credentials['app_store_key_path']
  ]);

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode == 0) {
    print('✅ Uploaded to App Store Connect');
  } else {
    print('❌ App Store upload failed');
  }
}

String getPackageName(String flavor) {
  switch (flavor) {
    case 'workplacebyls':
      return 'com.locationsolutions.workplacebyls';
    case 'workplacebytsphub':
      return 'com.locationsolutions.workplacebytsphub';
    case 'tiabytsp':
      return 'com.locationsolutions.tiabytsp';
    default:
      return 'com.locationsolutions.workplacebyls';
  }
}

Future<void> handleBump(List<String> args) async {
  if (args.length < 2) {
    print('❌ Usage: bump <flavor> <platform>');
    exit(1);
  }

  final flavor = args[0];
  final platform = args[1];

  if (!supportedFlavors.contains(flavor) ||
      !supportedPlatforms.contains(platform)) {
    print('❌ Invalid flavor or platform.');
    exit(1);
  }

  final json = await readVersionFile();
  final current = json[flavor]?[platform];
  if (current == null) {
    print('❌ No version info for $flavor / $platform');
    exit(1);
  }

  final buildName = json[flavor]['build_name'];
  final buildNumber = current['build_number'];
  final newBuildNumber = buildNumber + 1;

  json[flavor][platform]['build_number'] = newBuildNumber;
  await writeVersionFile(json);
  await appendChangelog(flavor, platform, buildName, newBuildNumber);

  print('✅ Bumped $flavor ($platform) to $buildName+$newBuildNumber');
  print('BUILD_NAME=$buildName');
  print('BUILD_NUMBER=$newBuildNumber');
}

Future<void> handleBumpAll() async {
  final json = await readVersionFile();
  for (final flavor in supportedFlavors) {
    for (final platform in supportedPlatforms) {
      final current = json[flavor]?[platform];
      if (current != null) {
        final buildName = json[flavor]['build_name'];
        final buildNumber = current['build_number'];
        final newBuildNumber = buildNumber + 1;
        json[flavor][platform]['build_number'] = newBuildNumber;
        await appendChangelog(flavor, platform, buildName, newBuildNumber);
        print('✅ Bumped $flavor ($platform) to $buildName+$newBuildNumber');
      }
    }
  }
  await writeVersionFile(json);
  print('📦 All versions bumped and saved to version.json');
}

Future<Map<String, dynamic>> loadCredentials(String flavor) async {
  final file = File('credentials/ayman-sctipt-credentials.json');
  if (!file.existsSync()) throw 'Missing ayman-sctipt-credentials.json';
  final data = jsonDecode(await file.readAsString());
  if (!data.containsKey(flavor)) throw 'No credentials found for $flavor';
  return data[flavor];
}

Future<void> handleRelease(List<String> args) async {
  if (args.length < 2) {
    print('❌ Usage: release <flavor> <platform>');
    exit(1);
  }

  final flavor = args[0];
  final platform = args[1];

  final json = await readVersionFile();
  final current = json[flavor]?[platform];

  if (current == null) {
    print('❌ No version found for $flavor / $platform');
    exit(1);
  }

  final buildName = json[flavor]['build_name'];
  final buildNumber = current['build_number'];
  final newBuildNumber = buildNumber + 1;

  await updatePubspecYaml(buildName, buildNumber);
  await updateCodemagicYaml(buildName, buildNumber);

  final target = 'lib/main_$flavor.dart';
  final result = await Process.run('shorebird', [
    'release',
    platform,
    '--flutter-version=$flutterVersion',
    '--flavor',
    flavor,
    '-t',
    target,
    '--build-name=$buildName',
    '--build-number=$buildNumber'
  ]);

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (platform == 'android') {
    await uploadToGooglePlay(flavor);
  } else if (platform == 'ios') {
    await uploadToAppStore(flavor);
  }

  json[flavor][platform]['build_number'] = newBuildNumber;
  await writeVersionFile(json);
  await appendChangelog(flavor, platform, buildName, newBuildNumber);

  print('✅ Released and bumped to $buildName+$newBuildNumber');
}

Future<void> handleReleaseAll() async {
  print('📦 Bumping all...');

  await handleBumpAll();

  final json = await readVersionFile();
  for (final flavor in supportedFlavors) {
    for (final platform in supportedPlatforms) {
      final current = json[flavor]?[platform];
      if (current == null) continue;

      final buildName = json[flavor]['build_name'];
      final buildNumber = current['build_number'];

      final target = 'lib/main_$flavor.dart';

      await updatePubspecYaml(buildName, buildNumber);
      await updateCodemagicYaml(buildName, buildNumber);

      print('🚀 Releasing $flavor ($platform)...');

      print(json[flavor][platform]);

      final result = await Process.run(
        'shorebird',
        [
          'release',
          'ios',
          '--flutter-version=$flutterVersion',
          '--flavor',
          flavor,
          '-t',
          target,
          '--build-name=$buildName',
          '--build-number=$buildNumber'
        ],
        environment: {
          'HOME': Platform.environment['HOME'] ?? '',
          'PATH': Platform.environment['PATH'] ?? '',
          'LANG': 'en_US.UTF-8',
          'TERM': 'xterm-256color'
        },
        runInShell: true,
      );

      stdout.write(result.stdout);
      stderr.write(result.stderr);

      if (platform == 'android') {
        await uploadToGooglePlay(flavor);
      } else if (platform == 'ios') {
        await uploadToAppStore(flavor);
      }

      await appendChangelog(flavor, platform, buildName, buildNumber);
      print('✅ Done: $flavor ($platform) -> $buildName+$buildNumber');
    }
  }

  await writeVersionFile(json);
  print('✅ All releases done.');
}
