#!/usr/bin/env python3
"""Compile and exercise the real AppKit model and editor actions without installing the app."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='video-editor-swift-tests-') as temp:
    temp = Path(temp)
    source = (ROOT / 'VideoEditorMac/Sources/main.swift').read_text().split('let application = NSApplication.shared')[0]
    (temp / 'main.swift').write_text(source + '\n' + (ROOT / 'tests/EditorRegression.swift').read_text())
    sparkle = ROOT / 'VideoEditorMac/.build-dependencies/Sparkle-2.9.6'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', '/tmp/video-editor-swift-cache',
                    '-F', str(sparkle), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(sparkle),
                    str(temp / 'main.swift'), '-o', str(temp / 'test-editor')], check=True)
    fixture = temp / 'fixture.mp4'
    subprocess.run(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=30:d=2',
                    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2', '-c:v', 'libx264', '-c:a', 'aac',
                    '-shortest', str(fixture)], check=True)
    subprocess.run([str(temp / 'test-editor'), str(fixture)], check=True, timeout=45,
                    env={**os.environ, 'VIDEO_EDITOR_TESTING': '1'})
