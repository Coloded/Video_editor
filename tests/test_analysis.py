#!/usr/bin/env python3
import importlib.util
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('analysis', ROOT / 'extract_and_analyze_video.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
os.environ['PATH'] = '/opt/homebrew/bin:' + os.environ.get('PATH', '')


class AnalysisTests(unittest.TestCase):
    def test_source_identity_and_quoted_metadata_path(self):
        with tempfile.TemporaryDirectory(prefix="video 'analysis:") as directory:
            root = Path(directory)
            video = root / 'source.mp4'
            def create(color):
                subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'color={color}:s=32x32:r=2:d=1', '-c:v', 'libx264', '-y', str(video)], check=True)
            create('red')
            frames = root / 'frames'
            self.assertEqual(analysis.extract_frames(video, frames, 2), 2)
            self.assertEqual(analysis.extract_frames(video, frames, 2), 2)
            self.assertEqual(analysis.extract_frames(video, frames, None), 2)
            values = analysis.signalstats(video, root / "metadata ' : file.txt")
            self.assertEqual(len(values), 2)
            create('blue')
            with self.assertRaisesRegex(RuntimeError, 'different or unverified source'):
                analysis.extract_frames(video, frames, 2)

    def test_standalone_compression_and_audio_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'portrait.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=240x480:r=10:d=1',
                            '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', '-f', 'lavfi', '-i', 'sine=frequency=880:duration=1',
                            '-map', '0:v', '-map', '1:a', '-map', '2:a', '-c:v', 'libx264', '-c:a', 'aac', str(source)], check=True)
            def invoke(script, *args):
                return subprocess.run(['zsh', str(ROOT / script), *map(str, args)], capture_output=True, text=True, timeout=30)
            for extra, name in [(['--720p'], 'bounded.mp4'), (['--target-mb', '0.3'], 'budget.mp4')]:
                output = root / name
                result = invoke('compress_video_for_mac.sh', '-f', source, '-o', output, *extra)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                metadata = analysis.probe(output)
                self.assertEqual((metadata['streams'][0]['width'], metadata['streams'][0]['height']), (240, 480))
                tracks = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=index', '-of', 'csv=p=0', str(output)], capture_output=True, text=True, check=True)
                self.assertEqual(len(tracks.stdout.strip().splitlines()), 2)
            wrong = root / 'wrong.mp3'
            result = invoke('extract_audio_from_video.sh', '-f', source, '-o', wrong)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(wrong.exists())
            result = invoke('extract_audio_from_video.sh', '-f', source, '-o', root / 'correct.mp3', '--format', 'mp3')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_review_import_has_no_side_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-c', 'import runpy; runpy.run_path(' + repr(str(ROOT / 'make_codex_review_sheets.py')) + ')'], cwd=directory, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_release_mismatch_is_rejected(self):
        spec = importlib.util.spec_from_file_location('release', ROOT / 'VideoEditorMac/validate_release.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'dist').mkdir()
            (root / 'VideoEditorMac').mkdir()
            (root / 'VideoEditorMac/Info.plist').write_bytes((ROOT / 'VideoEditorMac/Info.plist').read_bytes())
            (root / 'dist/Video_Editor-stable.dmg').write_bytes(b'A')
            version = plistlib.loads((ROOT / 'VideoEditorMac/Info.plist').read_bytes())['CFBundleShortVersionString']
            (root / f'dist/Video-Editor-{version}-arm64.dmg').write_bytes(b'B')
            module.ROOT, module.WORKSPACE = root / 'VideoEditorMac', root
            with self.assertRaisesRegex(ValueError, 'differ'):
                module.validate(root / 'unused.xml', check_bundle=False)


if __name__ == '__main__':
    unittest.main()
