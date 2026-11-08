#!/usr/bin/env python3
"""Build a local Apple Silicon app; no third-party packages or credentials."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

def compile_swift(output, files, frameworks, defines=()):
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macosx14.0']
    for define in defines:
        command.extend(['-D', define])
    command.extend(ROOT / name for name in files)
    command.extend(['-o', output])
    for framework in frameworks:
        command.extend(['-framework', framework])
    run(*command)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build' / 'WoW Character Retry.app')
    parser.add_argument('--preview', action='store_true')
    parser.add_argument('--test', action='store_true')
    args = parser.parse_args()
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    compile_swift(build / 'WoWRetry', ['Sources/Core.swift', 'Sources/ScreenAccess.swift', 'Sources/App.swift'], ['Cocoa', 'SwiftUI', 'ScreenCaptureKit', 'IOKit', 'ImageIO'])
    compile_swift(build / 'WoWTextReader', ['Sources/Core.swift', 'Sources/OCRHelper.swift'], ['Cocoa', 'Vision', 'ImageIO', 'CoreImage'])
    if args.test:
        compile_swift(build / 'FakeReader', ['Sources/Core.swift', 'Tests/FakeReader.swift'], ['Cocoa'])
        compile_swift(build / 'RetryTests', ['Sources/Core.swift', 'Sources/ScreenAccess.swift', 'Sources/App.swift', 'Tests/TestMain.swift'], ['Cocoa', 'SwiftUI', 'ScreenCaptureKit', 'IOKit', 'ImageIO'], ['RETRY_TESTS'])
        run(build / 'RetryTests', build)
    app = args.output.resolve()
    (app / 'Contents' / 'MacOS').mkdir(parents=True, exist_ok=True)
    (app / 'Contents' / 'Helpers').mkdir(parents=True, exist_ok=True)
    for name, subdirectory in [('WoWRetry', 'MacOS'), ('WoWTextReader', 'Helpers')]:
        destination = app / 'Contents' / subdirectory / name
        shutil.copyfile(build / name, destination)
        destination.chmod(0o755)
    info = {
        'CFBundleExecutable': 'WoWRetry',
        'CFBundleIdentifier': 'local.matt.WoWCharacterRetry.Preview' if args.preview else 'local.matt.WoWCharacterRetry',
        'CFBundleName': 'WoW Retry Preview' if args.preview else 'WoW Character Retry',
        'CFBundleDisplayName': 'WoW Retry Preview' if args.preview else 'WoW Character Retry',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '2.0.6',
        'CFBundleVersion': '8',
        'LSMinimumSystemVersion': '14.0',
        'NSHighResolutionCapable': True,
        'NSScreenCaptureUsageDescription': 'Read only the selected WoW or Battle.net window locally to recognize creation results and launcher controls.',
    }
    icon = ROOT / 'Assets' / 'AppIcon.icns'
    if icon.exists():
        (app / 'Contents' / 'Resources').mkdir(exist_ok=True)
        shutil.copyfile(icon, app / 'Contents' / 'Resources' / 'AppIcon.icns')
        info['CFBundleIconFile'] = 'AppIcon.icns'
    (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
    run('xattr', '-cr', app)
    run('codesign', '--force', '--sign', '-', app / 'Contents' / 'Helpers' / 'WoWTextReader')
    run('codesign', '--force', '--sign', '-', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    print(f'Built and verified: {app}')

if __name__ == '__main__':
    main()
