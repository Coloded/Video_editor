#!/usr/bin/env python3
"""Extract every decoded frame and build a reproducible forensic summary.

Uses only Python's standard library plus ffmpeg/ffprobe. No cloud or AI service.
"""

from __future__ import annotations

import argparse
import hashlib
import csv
import json
import math
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], *, stdout=None, stderr=None) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, check=True, stdout=stdout, stderr=stderr, text=True)


def probe(video: Path) -> dict:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=codec_name,width,height,pix_fmt,r_frame_rate,avg_frame_rate,nb_frames:format=duration,size,bit_rate:format_tags",
            "-of", "json", str(video),
        ],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def fraction(value: str) -> float:
    left, right = value.split("/", 1)
    return float(left) / float(right)


def extract_frames(video: Path, frames_dir: Path, expected: int | None) -> int:
    frames_dir.mkdir(parents=True, exist_ok=True)
    identity_path = frames_dir / "source.json"
    digest = hashlib.sha256()
    with video.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    identity = {"sha256": digest.hexdigest(), "format": "png", "version": 1}
    existing = sorted(frames_dir.glob("frame_*.png"))
    saved = json.loads(identity_path.read_text()) if identity_path.is_file() else {}
    if existing and any(saved.get(key) != value for key, value in identity.items()):
        raise RuntimeError("Frame directory belongs to a different or unverified source; choose a new output directory.")
    for index, frame in enumerate(existing):
        if frame.name != f"frame_{index:06d}.png":
            raise RuntimeError("Frame sequence has missing or unexpected names.")
        with frame.open("rb") as handle:
            header = handle.read(24)
            handle.seek(-12, 2)
            footer = handle.read()
        if header[:8] != b"\x89PNG\r\n\x1a\n" or b"IEND" not in footer:
            raise RuntimeError(f"Incomplete PNG frame: {frame}")
    if existing and saved.get("frame_count") == len(existing) and (expected is None or len(existing) == expected):
        print(f"Frames already complete: {len(existing)}")
        return len(existing)
    if existing:
        raise RuntimeError(
            f"Found an incomplete frame set ({len(existing)} files) in {frames_dir}. "
            "Move/delete that specific directory before rerunning."
        )
    identity_path.write_text(json.dumps(identity), encoding="utf-8")
    cmd = [
        "ffmpeg", "-hide_banner", "-nostdin", "-n", "-i", str(video),
        "-map", "0:v:0", "-an", "-sn", "-dn", "-fps_mode", "passthrough",
        "-start_number", "0", "-compression_level", "4",
        str(frames_dir / "frame_%06d.png"),
    ]
    run(cmd)
    count = len(list(frames_dir.glob("frame_*.png")))
    if expected and count != expected:
        raise RuntimeError(f"Expected {expected} frames, extracted {count}")
    identity_path.write_text(json.dumps({**identity, "frame_count": count}), encoding="utf-8")
    return count


def write_manifest(video: Path, destination: Path) -> list[dict[str, str]]:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
            "-show_entries", "frame=best_effort_timestamp_time,pts_time,duration_time,key_frame,pict_type,pkt_size",
            "-of", "json", str(video),
        ],
        check=True, capture_output=True, text=True,
    )
    frames = json.loads(result.stdout).get("frames", [])
    rows: list[dict[str, str]] = []
    with destination.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["frame", "file", "time_seconds", "duration_seconds", "key_frame", "picture_type", "packet_size"])
        for index, frame in enumerate(frames):
            row = {
                "frame": str(index), "file": f"frames/frame_{index:06d}.png",
                "time_seconds": str(frame.get("best_effort_timestamp_time", frame.get("pts_time", ""))),
                "duration_seconds": str(frame.get("duration_time", "")),
                "key_frame": str(frame.get("key_frame", "")),
                "picture_type": str(frame.get("pict_type", "")),
                "packet_size": str(frame.get("pkt_size", "")),
            }
            rows.append(row)
            writer.writerow(row.values())
    return rows


def signalstats(video: Path, output: Path, crop: str | None = None) -> list[tuple[float, float]]:
    filters = []
    if crop:
        filters.append(f"crop={crop}")
    filters.extend(["signalstats", "metadata=print:file=-"])
    with output.open("w", encoding="utf-8") as metadata_file:
        run(
        ["ffmpeg", "-hide_banner", "-i", str(video), "-vf", ",".join(filters), "-an", "-f", "null", "-"],
            stdout=metadata_file, stderr=subprocess.DEVNULL,
        )
    time_re = re.compile(r"pts_time:([0-9.]+)")
    diff_re = re.compile(r"lavfi\.signalstats\.YDIF=([0-9.]+)")
    current_time = 0.0
    values: list[tuple[float, float]] = []
    for line in output.read_text(encoding="utf-8").splitlines():
        if match := time_re.search(line):
            current_time = float(match.group(1))
        elif match := diff_re.search(line):
            values.append((current_time, float(match.group(1))))
    return values


def robust_score(values: list[float]) -> tuple[float, float, list[float]]:
    positive = [x for x in values[1:] if x > 0.02]
    median = statistics.median(positive) if positive else 0.0
    deviations = [abs(x - median) for x in positive]
    mad = statistics.median(deviations) if deviations else 1.0
    scale = max(1.4826 * mad, 0.05)
    return median, mad, [(x - median) / scale for x in values]


def group_events(times: list[float], scores: list[float], threshold: float = 6.0) -> list[dict]:
    indices = [i for i, score in enumerate(scores) if score >= threshold]
    groups: list[list[int]] = []
    for index in indices:
        if not groups or index > groups[-1][-1] + 2:
            groups.append([index])
        else:
            groups[-1].append(index)
    events = []
    for group in groups:
        peak = max(group, key=lambda i: scores[i])
        events.append({
            "start_frame": group[0], "end_frame": group[-1],
            "start_time": times[group[0]], "end_time": times[group[-1]],
            "peak_frame": peak, "peak_time": times[peak], "robust_score": scores[peak],
        })
    return events


def find_hold_transitions(times: list[float], values: list[float], scores: list[float]) -> list[dict]:
    """Find an editorial hold/duplicate immediately followed by a short dissolve."""
    events = []
    for index in range(1, len(values) - 4):
        if values[index] >= 0.02:
            continue
        end = index
        while end + 1 < len(scores) and end - index < 8 and scores[end + 1] >= 3.0:
            end += 1
        if end - index >= 3:
            peak = max(range(index + 1, end + 1), key=lambda i: scores[i])
            events.append({
                "start_frame": index, "end_frame": end,
                "start_time": times[index], "end_time": times[end],
                "peak_frame": peak, "peak_time": times[peak], "robust_score": scores[peak],
                "evidence": "duplicate/held frame followed by multi-frame transition",
            })
    return events


def make_contact_sheet(frames_dir: Path, events: list[dict], output: Path, frame_count: int) -> None:
    selected: list[Path] = []
    for event in sorted(events, key=lambda x: x["robust_score"], reverse=True)[:12]:
        center = int(event["peak_frame"])
        for index in (center - 2, center - 1, center, center + 1, center + 2):
            if 0 <= index < frame_count:
                selected.append(frames_dir / f"frame_{index:06d}.png")
    # ffmpeg's concat demuxer avoids shell globs and produces one compact visual index.
    list_file = output.with_suffix(".concat.txt")
    with list_file.open("w", encoding="utf-8") as handle:
        for path in selected:
            escaped = str(path.resolve()).replace("'", "'\\''")
            handle.write(f"file '{escaped}'\n")
            handle.write("duration 0.04\n")
    if selected:
        run([
            "ffmpeg", "-hide_banner", "-f", "concat", "-safe", "0", "-i", str(list_file),
            "-vf", "scale=568:-1,tile=5x12:padding=3:margin=5", "-frames:v", "1", "-update", "1", str(output), "-y",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    video = args.video.resolve()
    if not video.is_file():
        parser.error(f"Video not found: {video}")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        parser.error("ffmpeg and ffprobe are required")

    root = (args.output or video.with_name(video.stem + "_frames")).resolve()
    frames_dir = root / "frames"
    root.mkdir(parents=True, exist_ok=True)
    info = probe(video)
    stream = info["streams"][0]
    expected = int(stream["nb_frames"]) if stream.get("nb_frames", "").isdigit() else None
    frame_rate = fraction(stream["avg_frame_rate"])
    count = extract_frames(video, frames_dir, expected)
    manifest = write_manifest(video, root / "manifest.csv")

    width, height = int(stream["width"]), int(stream["height"])
    regions = {
        "global": None,
        "upper": f"{width}:{max(1, height // 3)}:0:0",
        "middle": f"{width}:{max(1, height // 3)}:0:{height // 3}",
        "lower": f"{width}:{height - 2 * (height // 3)}:0:{2 * (height // 3)}",
    }
    metrics: dict[str, list[tuple[float, float]]] = {}
    for name, crop in regions.items():
        metrics[name] = signalstats(video, root / f"signalstats_{name}.txt", crop)
    times = [item[0] for item in metrics["global"]]
    global_values = [item[1] for item in metrics["global"]]
    median, mad, scores = robust_score(global_values)
    events = group_events(times, scores)
    likely_edits = find_hold_transitions(times, global_values, scores)

    with (root / "frame_metrics.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["frame", "time_seconds", "global_ydif", "upper_ydif", "middle_ydif", "lower_ydif", "robust_score"])
        for index, time_s in enumerate(times):
            writer.writerow([
                index, f"{time_s:.6f}",
                *(f"{metrics[name][index][1]:.6f}" for name in regions),
                f"{scores[index]:.3f}",
            ])

    with (root / "events.json").open("w", encoding="utf-8") as handle:
        json.dump({"high_motion_candidates": events, "likely_edit_transitions": likely_edits}, handle, ensure_ascii=False, indent=2)

    duplicate_frames = [i for i, value in enumerate(global_values) if i > 0 and value < 0.02]
    report = [
        f"Video: {video.name}",
        f"Resolution: {width}x{height}",
        f"Frame rate: {frame_rate:.6f} fps",
        f"Duration: {float(info['format']['duration']):.3f} s",
        f"Extracted frames: {count}",
        f"Manifest entries: {len(manifest)}",
        f"Median frame difference (YDIF): {median:.6f}",
        f"MAD: {mad:.6f}",
        f"Exact/near duplicate decoded frames: {len(duplicate_frames)}",
        f"Candidate change events (robust score >= 6): {len(events)}",
        f"Likely edit transitions (hold + serial change): {len(likely_edits)}",
        "",
        "Likely edit transitions:",
    ]
    for event in likely_edits:
        report.append(
            f"- {event['start_time']:.3f}-{event['end_time']:.3f}s; "
            f"frames {event['start_frame']}-{event['end_frame']}; {event['evidence']}"
        )
    report.extend(["", "High-motion candidates (not automatically edits):"])
    for event in events:
        report.append(
            f"- {event['start_time']:.3f}-{event['end_time']:.3f}s; "
            f"peak {event['peak_time']:.3f}s, frame {event['peak_frame']}, score {event['robust_score']:.2f}"
        )
    report.extend(["", "Duplicate frame indices:", ", ".join(map(str, duplicate_frames)) or "none"])
    (root / "analysis_summary.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    make_contact_sheet(frames_dir, likely_edits + events, root / "candidate_events.png", count)
    (root / "source_metadata.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\n".join(report))
    print(f"\nResult directory: {root}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"Command failed with exit code {error.returncode}", file=sys.stderr)
        raise SystemExit(error.returncode)
