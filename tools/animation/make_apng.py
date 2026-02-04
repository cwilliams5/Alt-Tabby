"""
Create an animated PNG (APNG) from PNG frames.
Usage: python make_apng.py [frames_dir] [output.png] [fps]

APNG advantages over GIF:
- Full 32-bit RGBA (proper alpha transparency)
- No 256 color limit
- Frame differencing with alpha support
- Single file, smaller than raw PNGs

Defaults:
  frames_dir: frames/
  output: animation.png
  fps: read from meta.txt or 15
"""

import os
import sys
from pathlib import Path
from PIL import Image


def make_apng(frames_dir: str, output_file: str, fps: float = 0):
    """Create APNG from PNG frames."""

    frames_path = Path(frames_dir)

    # Try to read fps from meta.txt
    meta_file = frames_path / "meta.txt"
    if meta_file.exists() and fps <= 0:
        with open(meta_file) as f:
            for line in f:
                if line.startswith("fps="):
                    fps = float(line.split("=")[1])
                    break

    if fps <= 0:
        fps = 15

    # Get sorted frame files
    frame_files = sorted(frames_path.glob("frame_*.png"))
    if not frame_files:
        print(f"Error: No frame_*.png files in {frames_dir}")
        return False

    print(f"Creating APNG from {len(frame_files)} frames at {fps:.1f} fps")

    # Load all frames
    print("  Loading frames...")
    frames = []
    for i, f in enumerate(frame_files):
        img = Image.open(f)
        # Ensure RGBA mode for proper alpha
        if img.mode != 'RGBA':
            img = img.convert('RGBA')
        frames.append(img)

        if (i + 1) % 40 == 0:
            print(f"    Loaded {i + 1}/{len(frame_files)}")

    print(f"    Loaded {len(frame_files)}/{len(frame_files)}")

    # Calculate duration per frame in ms
    duration = int(1000 / fps)

    # Save as APNG
    print(f"  Saving APNG with {duration}ms per frame...")
    frames[0].save(
        output_file,
        save_all=True,
        append_images=frames[1:],
        duration=duration,
        loop=0,
        compress_level=9,  # Max PNG compression
    )

    file_size = os.path.getsize(output_file) / 1024
    print(f"Saved: {output_file} ({file_size:.1f} KB)")

    # Compare to GIF if it exists
    gif_path = Path(output_file).parent / "animation.gif"
    if gif_path.exists():
        gif_size = os.path.getsize(gif_path) / 1024
        print(f"  vs GIF: {gif_size:.1f} KB ({file_size/gif_size:.1f}x)")

    return True


if __name__ == "__main__":
    script_dir = Path(__file__).parent

    frames_dir = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "frames")
    output_file = sys.argv[2] if len(sys.argv) > 2 else str(script_dir / "animation.png")
    fps = float(sys.argv[3]) if len(sys.argv) > 3 else 0

    make_apng(frames_dir, output_file, fps)
