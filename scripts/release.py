import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SUPPORTED_FLAVORS = ['workplacebyls', 'workplacebytsphub', 'tiabytsp']
SUPPORTED_PLATFORMS = ['android', 'ios']
VERSION_FILE_PATH = 'version.json'
CHANGELOG_FILE_PATH = 'CHANGELOG.md'
FLUTTER_VERSION = '3.29.1'

def print_help():
    print('''
Usage:
  python release.py <command> [options]

Commands:
  bump <flavor> <platform>        Bump version for specific flavor/platform
  bump-all                        Bump build numbers for all flavors/platforms
  release <flavor> <platform>     Bump + shorebird release + fastlane publish
  release-all                     Perform release for all combinations
  --help                          Show this help menu
''')

def read_version_file():
    if not Path(VERSION_FILE_PATH).exists():
        raise FileNotFoundError(f'Missing {VERSION_FILE_PATH}')
    with open(VERSION_FILE_PATH) as f:
        return json.load(f)

def run_shell_command(cmd):
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            'LANG': 'en_US.UTF-8',
            'TERM': 'xterm-256color',
            'HOME': os.environ.get('HOME', ''),
            'PATH': os.environ.get('PATH', '')
        },
        shell=True
    )



def write_version_file(data):
    with open(VERSION_FILE_PATH, 'w') as f:
        json.dump(data, f, indent=2)

def append_changelog(flavor, platform, build_name, build_number):
    date = datetime.now().strftime('%Y-%m-%d')
    entry = f'- [{date}] {flavor} ({platform}): {build_name}+{build_number}\n'
    with open(CHANGELOG_FILE_PATH, 'a') as f:
        f.write(entry)

def update_pubspec_yaml(build_name, build_number):
    with open('pubspec.yaml') as f:
        lines = f.readlines()
    with open('pubspec.yaml', 'w') as f:
        for line in lines:
            if line.startswith('version:'):
                f.write(f'version: {build_name}+{build_number}\n')
            else:
                f.write(line)
    print(f'📝 Updated pubspec.yaml with version: {build_name}+{build_number}')

def update_codemagic_yaml(build_name, build_number):
    path = Path('codemagic.yaml')
    if not path.exists():
        return
    with path.open() as f:
        lines = f.readlines()
    with path.open('w') as f:
        for line in lines:
            if 'BUILD_NAME' in line:
                f.write(f'      BUILD_NAME: "{build_name}"\n')
            elif 'BUILD_NUMBER' in line:
                f.write(f'      BUILD_NUMBER: "{build_number}"\n')
            else:
                f.write(line)
    print('📝 Updated codemagic.yaml with BUILD_NAME and BUILD_NUMBER')

def get_aab_path(flavor):
    return f'build/app/outputs/bundle/{flavor}Release/app-{flavor}-release.aab'

def get_ipa_path(flavor):
    return {
        'tiabytsp': 'build/ios/ipa/TIA by TSP.ipa',
        'workplacebyls': 'build/ios/ipa/Workplace By LS.ipa',
        'workplacebytsphub': 'build/ios/ipa/Workplace By TSPHub.ipa',
    }.get(flavor, f'build/ios/ipa/{flavor}.ipa')

def get_package_name(flavor):
    return {
        'workplacebyls': 'com.locationsolutions.workplacebyls',
        'workplacebytsphub': 'com.locationsolutions.workplacebytsphub',
        'tiabytsp': 'com.locationsolutions.tiabytsp'
    }.get(flavor, 'com.locationsolutions.workplacebyls')

def load_credentials(flavor):
    path = Path('credentials/ayman-sctipt-credentials.json')
    if not path.exists():
        raise FileNotFoundError('Missing ayman-sctipt-credentials.json')
    with path.open() as f:
        data = json.load(f)
    if flavor not in data:
        raise KeyError(f'No credentials found for {flavor}')

    print(f'🔑 Loaded credentials for {flavor} {data[flavor]}')
    return data[flavor]

def upload_to_google_play(flavor):
    aab_path = get_aab_path(flavor)
    if not Path(aab_path).exists():
        print('❌ AAB not found. Did you run `flutter build appbundle`?')
        return

    creds = load_credentials(flavor)
    cmd = [
        'fastlane', 'supply',
        '--aab', aab_path,
        '--package_name', get_package_name(flavor),
        '--track', 'production',
        '--json_key', creds['google_play'],
        '--skip_upload_metadata',
        '--skip_upload_images',
        '--skip_upload_screenshots'
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    print(result.stdout)
    print(result.stderr)
    print('✅ Uploaded to Google Play Store' if result.returncode == 0 else '❌ Google Play upload failed')

def upload_to_app_store(flavor):
    ipa_path = get_ipa_path(flavor)
    if not Path(ipa_path).exists():
        print(f'❌ IPA not found at {ipa_path}')
        return

    creds = load_credentials(flavor)
    cmd = [
        'fastlane', 'deliver',
        '--ipa', ipa_path,
        '--skip_metadata',
        '--skip_screenshots',
        '--submit_for_review',
        '--automatic_release',
        '--api_key_path', creds['app_store_key_path']
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    print(result.stdout)
    print(result.stderr)
    print('✅ Uploaded to App Store Connect' if result.returncode == 0 else '❌ App Store upload failed')

def handle_bump(args):
    if len(args) < 2:
        print('❌ Usage: bump <flavor> <platform>')
        sys.exit(1)
    flavor, platform = args
    if flavor not in SUPPORTED_FLAVORS or platform not in SUPPORTED_PLATFORMS:
        print('❌ Invalid flavor or platform.')
        sys.exit(1)
    data = read_version_file()
    current = data[flavor][platform]
    build_name = data[flavor]['build_name']
    build_number = current['build_number'] + 1
    data[flavor][platform]['build_number'] = build_number
    write_version_file(data)
    append_changelog(flavor, platform, build_name, build_number)
    print(f'✅ Bumped {flavor} ({platform}) to {build_name}+{build_number}')
    print(f'BUILD_NAME={build_name}')
    print(f'BUILD_NUMBER={build_number}')

def handle_bump_all():
    data = read_version_file()
    for flavor in SUPPORTED_FLAVORS:
        for platform in SUPPORTED_PLATFORMS:
            current = data[flavor][platform]
            build_name = data[flavor]['build_name']
            build_number = current['build_number'] + 1
            data[flavor][platform]['build_number'] = build_number
            append_changelog(flavor, platform, build_name, build_number)
            print(f'✅ Bumped {flavor} ({platform}) to {build_name}+{build_number}')
    write_version_file(data)
    print('📦 All versions bumped and saved to version.json')

def handle_release(args):
    if len(args) < 2:
        print('❌ Usage: release <flavor> <platform>')
        sys.exit(1)
    flavor, platform = args
    data = read_version_file()
    current = data[flavor][platform]
    build_name = data[flavor]['build_name']
    build_number = current['build_number']
    new_build_number = build_number + 1

    update_pubspec_yaml(build_name, build_number)
    update_codemagic_yaml(build_name, build_number)

    target = f'lib/main_{flavor}.dart'
    cmd = [
        'shorebird', 'release', platform,
        f'--flutter-version={FLUTTER_VERSION}',
        '--flavor', flavor,
        '-t', target,
        f'--build-name={build_name}',
        f'--build-number={build_number}'
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    print(result.stdout)
    print(result.stderr)

    if platform == 'android':
        upload_to_google_play(flavor)
    elif platform == 'ios':
        upload_to_app_store(flavor)

    data[flavor][platform]['build_number'] = new_build_number
    write_version_file(data)
    append_changelog(flavor, platform, build_name, new_build_number)
    print(f'✅ Released and bumped to {build_name}+{new_build_number}')

def handle_release_all():
    print('📦 Bumping all...')
    handle_bump_all()
    data = read_version_file()
    for platform in SUPPORTED_PLATFORMS:
        for flavor in SUPPORTED_FLAVORS:
            current = data[flavor][platform]
            build_name = data[flavor]['build_name']
            build_number = current['build_number']
            target = f'lib/main_{flavor}.dart'
            update_pubspec_yaml(build_name, build_number)
            update_codemagic_yaml(build_name, build_number)
            print(f'🚀 Releasing {flavor} ({platform})...')
            cmd = [
                'shorebird', 'release', platform,
                f'--flutter-version={FLUTTER_VERSION}',
                '--flavor', flavor,
                '-t', target,
                f'--build-name={build_name}',
                f'--build-number={build_number}'
            ]
            result = subprocess.run(cmd, capture_output=True, text=True,shell=True, env={
                **os.environ,
                'LANG': 'en_US.UTF-8',
                'TERM': 'xterm-256color',
                'HOME': os.environ.get('HOME', ''),
                'PATH': os.environ.get('PATH', '')
            })
            print(result.stdout)
            print(result.stderr)
    
            if platform == 'android':
                upload_to_google_play(flavor)
            elif platform == 'ios':
                upload_to_app_store(flavor)

            append_changelog(flavor, platform, build_name, build_number)
            print(f'✅ Done: {flavor} ({platform}) -> {build_name}+{build_number}')
    write_version_file(data)
    print('✅ All releases done.')

def main():
    args = sys.argv[1:]
    if not args or '--help' in args:
        print_help()
        return

    command = args[0]
    options = args[1:]

    commands = {
    'bump': handle_bump,
    'bump-all': lambda _: handle_bump_all(),
    'release': handle_release,
    'release-all': lambda _: handle_release_all()
}


    if command not in commands:
        print(f'❌ Unknown command: {command}\n')
        print_help()
        sys.exit(1)

    commands[command](options)

if __name__ == '__main__':
    main()
