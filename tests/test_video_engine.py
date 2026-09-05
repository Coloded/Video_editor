#!/usr/bin/env python3
"""End-to-end regression tests; only temporary synthetic media is created."""
import json
from concurrent.futures import ThreadPoolExecutor
import array
import signal
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'VideoEditorMac/Resources/video_engine'
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'


def run(args, timeout=90):
    return subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, 'PATH': f'{Path(FFMPEG).parent}:/usr/bin:/bin:/usr/sbin:/sbin'})


class EngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='video-editor-tests-')
        cls.root = Path(cls.temp.name)
        cls.source = cls.root / "source ' footage.mp4"
        result = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=30:d=2',
                      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2', '-c:v', 'libx264',
                      '-c:a', 'aac', '-shortest', cls.source])
        assert result.returncode == 0, result.stderr

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def probe(self, path):
        result = run([FFPROBE, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', path])
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def join(self, name, speed=1, extra=(), rows=None):
        manifest = self.root / f'{name}.tsv'
        manifest.write_text(rows or f'{self.source}\t0\t2\t1\t{speed}\n')
        output = self.root / f'{name}.mp4'
        result = run([ENGINE, 'join', '--manifest', manifest, '--no-gpu', '--convert-sdr',
                      '--plain-progress', '-o', output, *extra])
        return result, output

    def test_custom_compression_parameters(self):
        for codec, audio in [('h264', 'remove'), ('hevc', 'aac')]:
            output = self.root / f'custom-{codec}.mp4'
            result = run([ENGINE, 'compress', '2160', '-f', self.source, '-o', output,
                          '--short-side', '128', '--bitrate', '0.3', '--codec', codec,
                          '--fps', '15', '--audio-mode', audio, '--audio-bitrate', '64',
                          '--allow-larger', '--cpu', '--convert-sdr', '--plain-progress'])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            data = self.probe(output)
            video = data['streams'][0]
            self.assertEqual(video['codec_name'], codec)
            self.assertEqual(video['height'], 128)
            self.assertEqual(video['avg_frame_rate'], '15/1')
            self.assertEqual(len(data['streams']), 1 if audio == 'remove' else 2)
            self.assertAlmostEqual(float(data['format']['duration']), 2, delta=.15)
            self.assertIn('экономия', result.stdout)
        invalid = self.root / 'invalid-profile.mp4'
        result = run([ENGINE, 'compress', '240', '-f', self.source, '-o', invalid,
                      '--short-side', '129', '--cpu'])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(invalid.exists())

    def test_output_containers(self):
        manifest = self.root / 'formats.tsv'
        manifest.write_text(f'{self.source}\t0\t2\t1\t1\n')
        for ext in ['mp4', 'mov', 'mkv']:
            with self.subTest(container=ext):
                output = self.root / f'container.{ext}'
                result = run([ENGINE, 'join', '--manifest', manifest, '--no-gpu', '--convert-sdr', '--plain-progress', '-o', output])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                metadata = self.probe(output)
                self.assertEqual([s['codec_name'] for s in metadata['streams']], ['h264', 'aac'])
                self.assertAlmostEqual(float(metadata['format']['duration']), 2, delta=0.15)
                self.assertIn('matroska' if ext == 'mkv' else 'mov', metadata['format']['format_name'])
                if ext in ['mp4', 'mov']:
                    # ffprobe groups the two ISO-BMFF containers; the brand distinguishes them.
                    self.assertEqual(metadata['format']['tags']['major_brand'], 'qt  ' if ext == 'mov' else 'isom')

    def test_speed_and_audio(self):
        for speed in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5, 0.1]:
            with self.subTest(speed=speed):
                result, output = self.join(f'speed-{speed}', speed)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                metadata = self.probe(output)
                self.assertAlmostEqual(float(metadata['format']['duration']), 2 / speed, delta=0.16)
                self.assertEqual({s['codec_type'] for s in metadata['streams']}, {'video', 'audio'})

    def test_split_then_change_speed(self):
        rows = f'{self.source}\t0\t1\t1\t1\n{self.source}\t1\t2\t1\t2\n'
        result, output = self.join('split', rows=rows)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertAlmostEqual(float(self.probe(output)['format']['duration']), 1.5, delta=0.12)

    def test_existing_output_survives(self):
        output = self.root / 'existing.mp4'
        output.write_bytes(b'previous user file')
        result, _ = self.join('existing')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(output.read_bytes(), b'previous user file')
        self.assertTrue((self.root / 'existing-1.mp4').is_file())
        self.assertIn('RESULT_BASE64=', result.stdout)

    def test_source_cannot_be_overwritten(self):
        manifest = self.root / 'same.tsv'
        manifest.write_text(f'{self.source}\t0\t2\t1\t1\n')
        before = self.source.read_bytes()
        result = run([ENGINE, 'join', '--manifest', manifest, '-o', self.source, '-y', '--no-gpu'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.source.read_bytes(), before)

    def test_invalid_speed(self):
        for speed in ['nan', 'inf', '-1', '0', '11', '1junk']:
            result, output = self.join(f'invalid-{speed}', speed)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_concurrent_publication(self):
        rows = f'{self.source}\t0\t2\t1\t1\n'
        manifest = self.root / 'race.tsv'
        manifest.write_text(rows)
        output = self.root / 'race.mp4'
        command = [ENGINE, 'join', '--manifest', manifest, '--no-gpu', '--convert-sdr', '--plain-progress', '-o', output]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: run(command), range(2)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output.exists())
        self.assertTrue((self.root / 'race-1.mp4').exists())
        self.assertFalse(list(self.root.glob('.video-editor.*')))

    def test_audio_pitch_at_speed(self):
        result, output = self.join('pitch', 2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        pcm = subprocess.run([FFMPEG, '-v', 'error', '-i', str(output), '-map', '0:a:0', '-ac', '1',
                              '-ar', '16000', '-f', 's16le', '-'], check=True, capture_output=True).stdout
        samples = array.array('h', pcm)[1600:11200]
        self.assertGreater(max(samples), 100)
        crossings = sum(a <= 0 < b for a, b in zip(samples, samples[1:]))
        self.assertAlmostEqual(crossings / (len(samples) / 16000), 440, delta=6)

    def test_cancel_preserves_existing_output(self):
        manifest = self.root / 'cancel.tsv'
        manifest.write_text(f'{self.source}\t0\t2\t1\t0.1\n')
        output = self.root / 'cancel.mp4'
        output.write_bytes(b'original result')
        process = subprocess.Popen(list(map(str, [ENGINE, 'join', '--manifest', manifest, '--no-gpu',
                                   '--plain-progress', '-o', output])), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env={**os.environ, 'PATH': f'{Path(FFMPEG).parent}:/usr/bin:/bin:/usr/sbin:/sbin'})
        try:
            for line in process.stdout:
                if 'Результат:' in line:
                    process.send_signal(signal.SIGINT)
                    break
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(output.read_bytes(), b'original result')
            self.assertFalse(list(self.root.glob('.video-editor.*')))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_anamorphic_display_geometry(self):
        source = self.root / 'anamorphic.mp4'
        result = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=120x90:r=5:d=1',
                      '-vf', 'setsar=4/3', '-c:v', 'libx264', source])
        self.assertEqual(result.returncode, 0, result.stderr)
        result, output = self.join('anamorphic-output', rows=f'{source}\t0\t1\t1\t1\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        video = self.probe(output)['streams'][0]
        self.assertEqual((video['width'], video['height']), (160, 90))
        pixels = subprocess.run([FFMPEG, '-v', 'error', '-i', str(output), '-frames:v', '1', '-pix_fmt', 'gray',
                                 '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
        self.assertGreater(pixels[160 * 45], 40, 'Unexpected black bars from coded aspect ratio')
        self.assertGreater(pixels[160 * 45 + 159], 40)

    def test_compression_hdr_progress(self):
        source = self.root / 'compression-hdr.mkv'
        result = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i',
                      'testsrc2=s=480x240:r=30:d=1,setparams=color_trc=arib-std-b67:color_primaries=bt2020:colorspace=bt2020nc',
                      '-c:v', 'ffv1', '-pix_fmt', 'yuv420p10le', source])
        self.assertEqual(result.returncode, 0, result.stderr)
        for ext in ['mp4', 'mov', 'mkv']:
            output = self.root / f'compressed-hdr.{ext}'
            result = run([ENGINE, 'compress', '240', '-f', source, '--no-gpu', '--convert-sdr', '--plain-progress', '-o', output])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.probe(output)['streams'][0]['color_transfer'], 'bt709')
            self.assertLess(output.stat().st_size, source.stat().st_size)

    def test_rotation(self):
        rotated = self.root / 'rotated.mp4'
        result = run([FFMPEG, '-v', 'error', '-display_rotation', '90', '-i', self.source, '-c', 'copy', rotated])
        self.assertEqual(result.returncode, 0, result.stderr)
        result, output = self.join('rotation', rows=f'{rotated}\t0\t2\t1\t1\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        video = next(s for s in self.probe(output)['streams'] if s['codec_type'] == 'video')
        self.assertEqual((video['width'], video['height']), (90, 160))

    def test_hdr_highlights_remain_distinct(self):
        for transfer in ['arib-std-b67', 'smpte2084']:
            source = self.root / f'{transfer}.mkv'
            result = run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i',
                          f'nullsrc=s=160x90:r=5:d=1,format=gbrpf32le,geq=r=X/W:g=X/W:b=X/W,setparams=color_trc={transfer}:color_primaries=bt2020',
                          '-c:v', 'ffv1', '-pix_fmt', 'gbrp16le', '-color_trc', transfer,
                          '-color_primaries', 'bt2020', source])
            self.assertEqual(result.returncode, 0, result.stderr)
            result, output = self.join(transfer, rows=f'{source}\t0\t1\t1\t1\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            decoded = subprocess.run([FFMPEG, '-v', 'error', '-i', str(output), '-frames:v', '1',
                                      '-pix_fmt', 'gray', '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
            values = [decoded[45 * 160 + x] for x in [90, 115, 140]]
            self.assertTrue(values[0] + 3 < values[1] < values[2] - 3, values)
            self.assertEqual(self.probe(output)['streams'][0]['color_transfer'], 'bt709')

    def test_cut_progress_completes(self):
        output = self.root / 'cut.mp4'
        result = run([ENGINE, 'cut', '-f', self.source, '-s', '0', '-e', '1', '-o', output, '--plain-progress'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output.is_file())


if __name__ == '__main__':
    unittest.main()
