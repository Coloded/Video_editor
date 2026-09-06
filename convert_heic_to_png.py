#!/usr/bin/env python3
"""Convert HEIC/HEIF to PNG on macOS; optionally watch folders for new files."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
IGNORED = {'.git', '.codex', '.agents', 'dist', 'reference', '.build-dependencies', '__pycache__'}
EXTENSIONS = {'.heic', '.heif'}


def images(paths):
    for path in paths:
        if path.is_symlink():
            continue
        if path.is_file():
            if path.suffix.lower() in EXTENSIONS:
                yield path
        elif path.is_dir():
            for directory, folders, files in os.walk(path, followlinks=False):
                folders[:] = [f for f in folders if f not in IGNORED and not Path(directory, f).is_symlink()]
                for name in files:
                    candidate = Path(directory, name)
                    if candidate.suffix.lower() in EXTENSIONS and not candidate.is_symlink():
                        yield candidate


def signature(path):
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns


def convert(source, output_dir=None):
    destination = (output_dir or source.parent) / (source.stem + '.png')
    if destination.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    before = signature(source)
    with tempfile.TemporaryDirectory(prefix='.heic-png-', dir=destination.parent) as temp:
        output = Path(temp) / 'converted.png'
        result = subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(source), '--out', str(output)],
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or 'sips failed')
        if signature(source) != before:
            raise RuntimeError('Файл ещё копируется; повторю позже')
        with output.open('rb') as stream:
            if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                raise RuntimeError('Конвертер не создал корректный PNG')
        try:
            # Publish the completed file atomically, without replacing existing files.
            os.link(output, destination)
        except FileExistsError:
            return
    print(f'PNG: {source} → {destination}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path, help='Files or folders; default: this project')
    parser.add_argument('--watch', action='store_true', help='Watch for new files until Ctrl+C')
    parser.add_argument('--output-dir', type=Path, help='Save PNG here instead of beside each original')
    args = parser.parse_args()
    paths = [p.expanduser().absolute() for p in (args.paths or [ROOT])]
    for path in paths:
        if not path.exists():
            parser.error(f'Не найдено: {path}')
    previous = {}
    retry_after = {}
    errors = 0
    if args.watch:
        print('Наблюдение за HEIC/HEIF: ' + ', '.join(map(str, paths)), flush=True)
    try:
        while True:
            current = {}
            for source in set(images(paths)):
                try:
                    current[source] = signature(source)
                    if args.watch and (previous.get(source) != current[source] or time.monotonic() < retry_after.get(source, 0)):
                        continue
                    convert(source, args.output_dir)
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                    print(f'Ошибка: {source}: {error}', flush=True)
                    retry_after[source] = time.monotonic() + 30
                    errors += 1
            if not args.watch:
                return int(errors > 0)
            previous = current
            retry_after = {p: t for p, t in retry_after.items() if p in current}
            time.sleep(2)
    except KeyboardInterrupt:
        print('\nНаблюдение остановлено.', flush=True)
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
