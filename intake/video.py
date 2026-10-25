from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path


MAX_SECONDS = 10 * 60


class VideoExtractionError(RuntimeError):
    pass


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise VideoExtractionError("ffmpeg and ffprobe are required for video intake") from exc
    except subprocess.CalledProcessError as exc:
        raise VideoExtractionError(exc.stderr.strip() or "ffmpeg failed") from exc


def extract_video(path: str | Path, output: str | Path, *, transcriber=None) -> dict:
    path, output = Path(path), Path(output)
    if not path.is_file():
        raise FileNotFoundError(path)
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise VideoExtractionError("ffmpeg and ffprobe are required for video intake")
    output.mkdir(parents=True, exist_ok=True)
    probe = _run(["ffprobe", "-v", "error", "-protocol_whitelist", "file", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(path)])
    duration = float(probe.stdout.strip() or 0)
    limited = min(duration, MAX_SECONDS)
    audio = output / "audio.wav"
    _run(["ffmpeg", "-protocol_whitelist", "file", "-y", "-i", str(path), "-t", str(MAX_SECONDS), "-vn", "-ac", "1", "-ar", "16000", str(audio)])
    frames = output / "frames"
    frames.mkdir(exist_ok=True)
    _run(["ffmpeg", "-protocol_whitelist", "file", "-y", "-i", str(path), "-t", str(MAX_SECONDS), "-vf", "fps=1/30", str(frames / "%03d.jpg")])
    result = {"duration_seconds": duration, "processed_seconds": limited, "audio_path": audio.as_posix(), "frames_dir": frames.as_posix(), "frame_interval_seconds": 30, "limits_applied": ["video limited to first 10 minutes"] if duration > MAX_SECONDS else []}
    if transcriber is None:
        result["transcript"] = {"status": "unavailable", "reason": "T002 threshold/model is not available in this intake process; use extracted audio or frames"}
    else:
        result["transcript"] = transcriber(audio, output / "transcript.txt")
    (output / "video.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result
