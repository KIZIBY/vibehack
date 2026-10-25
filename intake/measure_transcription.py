#!/usr/bin/env python3
"""Measure local faster-whisper transcription for up to three recordings.

The benchmark intentionally does not download a model or audio fixtures. Pass
three local recordings explicitly and install faster-whisper in the benchmark
environment before running it.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", action="append", required=True, help="local audio path; repeat exactly three times")
    parser.add_argument("--model", default="small", help="faster-whisper model name (default: small)")
    parser.add_argument("--language", default="ru", help="language hint (default: ru)")
    parser.add_argument("--output", type=Path, default=Path("transcription-benchmark.json"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if len(args.audio) != 3:
        print("error: --audio must be supplied exactly three times", file=sys.stderr)
        return 2
    paths = [Path(item) for item in args.audio]
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        print(json.dumps({"status": "blocked", "reason": "missing_audio", "missing": missing}, ensure_ascii=False))
        return 2
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print(json.dumps({"status": "blocked", "reason": "faster_whisper_not_installed"}, ensure_ascii=False))
        return 2

    model = WhisperModel(args.model, device="cpu", compute_type="int8", cpu_threads=2)
    samples: list[dict[str, object]] = []
    for path in paths:
        started = time.monotonic()
        segments, info = model.transcribe(str(path), language=args.language, vad_filter=True)
        text = " ".join(segment.text.strip() for segment in segments).strip()
        elapsed = time.monotonic() - started
        samples.append({"file": str(path), "elapsed_seconds": round(elapsed, 2), "audio_seconds": round(float(info.duration), 2), "realtime_factor": round(elapsed / max(float(info.duration), 0.001), 3), "language_probability": round(float(info.language_probability), 3), "text_chars": len(text)})

    result = {"status": "ok", "model": args.model, "language": args.language, "cpu_threads": 2, "pid": os.getpid(), "samples": samples, "threshold": {"max_elapsed_seconds_for_10_minute_audio": 360, "max_realtime_factor": 0.6}}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
