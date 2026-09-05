#!/usr/bin/env python3
"""Validate a release against source metadata, embedded bundle, and public EdDSA key."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(appcast, check_bundle=True):
    plist = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    version, build = plist['CFBundleShortVersionString'], plist['CFBundleVersion']
    stable = WORKSPACE / 'dist/Video_Editor-stable.dmg'
    versioned = WORKSPACE / f'dist/Video-Editor-{version}-arm64.dmg'
    if digest(stable) != digest(versioned):
        raise ValueError('Stable and versioned DMG differ')
    item = ET.parse(appcast).getroot().find('./channel/item')
    if item is None:
        raise ValueError('Appcast has no item')
    if item.findtext('sparkle:version', namespaces=NS) != build or item.findtext('sparkle:shortVersionString', namespaces=NS) != version:
        raise ValueError('Appcast version/build differs from Info.plist')
    enclosure = item.find('enclosure')
    if enclosure is None or int(enclosure.get('length', '-1')) != stable.stat().st_size:
        raise ValueError('Appcast size differs from stable DMG')
    if enclosure.get('url') != 'https://github.com/Coloded/Video_editor/releases/latest/download/Video_Editor-stable.dmg':
        raise ValueError('Unexpected release download URL')
    signature = enclosure.get(f'{{{NS["sparkle"]}}}edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid EdDSA signature encoding')
    with tempfile.TemporaryDirectory(prefix='video-editor-validate-') as temporary:
        temporary = Path(temporary)
        verifier = temporary / 'verify.swift'
        verifier.write_text('''import Foundation
import CryptoKit
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
let signature = Data(base64Encoded: args[2])!
let payload = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: payload) else { fputs("Invalid release signature\\n", stderr); exit(1) }
''')
        subprocess.run(['xcrun', 'swift', '-module-cache-path', str(temporary / 'modules'), str(verifier), plist['SUPublicEDKey'], signature, str(stable)], check=True)
        if check_bundle:
            mount = temporary / 'mount'
            mount.mkdir()
            subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(stable)], check=True, stdout=subprocess.DEVNULL)
            try:
                bundle = mount / 'Video_Editor.app/Contents'
                embedded = plistlib.loads((bundle / 'Info.plist').read_bytes())
                for key in ['CFBundleVersion', 'CFBundleShortVersionString', 'SUPublicEDKey']:
                    if embedded[key] != plist[key]:
                        raise ValueError(f'Embedded bundle differs: {key}')
                manifest = json.loads((bundle / 'Resources/BuildManifest.json').read_text())
                for name, path in [('main.swift', ROOT / 'Sources/main.swift'), ('video_engine', ROOT / 'Resources/video_engine'), ('Info.plist', ROOT / 'Info.plist')]:
                    if manifest.get(name) != digest(path):
                        raise ValueError(f'Bundle was built from different source: {name}')
                if digest(bundle / 'Resources/video_engine') != digest(ROOT / 'Resources/video_engine'):
                    raise ValueError('Embedded engine differs from current source')
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle.parent)], check=True)
            finally:
                subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
    print(f'Validated Video Editor {version}, build {build}: source, bundle, DMG, appcast, EdDSA')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--appcast', type=Path, default=WORKSPACE / 'updates/appcast.xml')
    args = parser.parse_args()
    validate(args.appcast)


if __name__ == '__main__':
    main()
