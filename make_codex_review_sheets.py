#!/usr/bin/env python3
"""Build configurable contact sheets; importing this module has no side effects."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--crop", help="Optional FFmpeg crop expression, e.g. 310:230:0:0")
    parser.add_argument("--fps", type=float, default=1)
    args = parser.parse_args()
    if not args.video.is_file():
        parser.error("Source video does not exist")
    if not 0 < args.fps <= 60:
        parser.error("--fps must be greater than 0 and no greater than 60")
    # A fresh directory prevents mixing sheets from different runs.
    args.output.mkdir(parents=True, exist_ok=False)
    filters = [f"fps={args.fps}"]
    if args.crop:
        filters.append(f"crop={args.crop}")
    filters.extend(["scale=640:360:force_original_aspect_ratio=decrease", "pad=640:360:(ow-iw)/2:(oh-ih)/2", "tile=5x5:padding=6:margin=8"])
    subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-n", "-i", str(args.video.resolve()), "-an", "-vf", ",".join(filters), "-fps_mode", "passthrough", str(args.output / "overview_%02d.png")], check=True)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
