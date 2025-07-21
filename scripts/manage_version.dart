import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    print('Usage: dart scripts/manage_version.dart <flavor>');
    exit(1);
  }

  final flavor = args[0];

  final file = File('version.json');
  if (!file.existsSync()) {
    print('version.json not found.');
    exit(1);
  }

  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final version = json[flavor] as Map<String, dynamic>?;
  if (version == null) {
    print('No version info for flavor: $flavor');
    exit(1);
  }

  final buildName = version['build_name'];
  var buildNumber = version['build_number'];

  if (buildName == null || buildNumber == null) {
    print('Invalid version info for $flavor.');
    exit(1);
  }

  // Increment build number automatically
  buildNumber++;

  // Update version.json
  version['build_number'] = buildNumber;
  await file.writeAsString(JsonEncoder.withIndent('  ').convert(json));

  // Update pubspec.yaml
  final pubspec = File('pubspec.yaml');
  final lines = await pubspec.readAsLines();
  final newLines = lines.map((line) {
    if (line.startsWith('version:')) {
      return 'version: $buildName+$buildNumber';
    }
    return line;
  }).toList();
  await pubspec.writeAsString(newLines.join('\n'));

  // Export variables for Codemagic
  print('BUILD_NAME=$buildName');
  print('BUILD_NUMBER=$buildNumber');
}
