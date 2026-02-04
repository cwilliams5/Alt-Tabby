"""
Create an animated WebP from PNG frames.
Usage: python make_webp.py [frames_dir] [output.webp] [fps]

WebP advantages:
- Full 32-bit RGBA (proper alpha transparency)
- Excellent compression (smaller than GIF)
- No 256 color limit
- Widely supported in browsers

Defaults:
  frames_dir: frames/
  output: animation.webp
  fps: read from meta.txt or 15
"""

import os
import sys
from pathlib import Path
from PIL import Image


def make_webp(frames_dir: str, output_file: str, fps: float = 0, quality: int = 90, target_size: tuple = None):
    """Create animated WebP from PNG frames.

    Args:
        target_size: Optional (width, height) tuple to resize frames. None = original size.
    """

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

    size_str = f" -> {target_size[0]}x{target_size[1]}" if target_size else ""
    print(f"Creating WebP from {len(frame_files)} frames at {fps:.1f} fps (quality={quality}){size_str}")

    # Load all frames
    print("  Loading frames...")
    frames = []
    for i, f in enumerate(frame_files):
        img = Image.open(f)
        # Ensure RGBA mode for proper alpha
        if img.mode != 'RGBA':
            img = img.convert('RGBA')
        # Resize if target size specified
        if target_size:
            img = img.resize(target_size, Image.LANCZOS)
        frames.append(img)

        if (i + 1) % 40 == 0:
            print(f"    Loaded {i + 1}/{len(frame_files)}")

    print(f"    Loaded {len(frame_files)}/{len(frame_files)}")

    # Calculate duration per frame in ms
    duration = int(1000 / fps)

    # Save as animated WebP
    print(f"  Saving WebP with {duration}ms per frame...")
    frames[0].save(
        output_file,
        save_all=True,
        append_images=frames[1:],
        duration=duration,
        loop=0,
        quality=quality,
        method=6,  # Slowest but best compression
    )

    file_size = os.path.getsize(output_file) / 1024
    print(f"Saved: {output_file} ({file_size:.1f} KB)")

    # Compare to other formats if they exist
    comparisons = [
        ("GIF", "animation.gif"),
        ("APNG", "animation.png"),
    ]
    for name, path in comparisons:
        full_path = Path(output_file).parent / path
        if full_path.exists():
            other_size = os.path.getsize(full_path) / 1024
            ratio = file_size / other_size
            print(f"  vs {name}: {other_size:.1f} KB (WebP is {ratio:.2f}x)")

    return True


if __name__ == "__main__":
    script_dir = Path(__file__).parent

    frames_dir = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "frames")
    output_file = sys.argv[2] if len(sys.argv) > 2 else str(script_dir / "animation.webp")
    fps = float(sys.argv[3]) if len(sys.argv) > 3 else 0
    # Optional: target size as "WIDTHxHEIGHT" (e.g., "707x548")
    target_size = None
    if len(sys.argv) > 4:
        w, h = sys.argv[4].lower().split('x')
        target_size = (int(w), int(h))

    make_webp(frames_dir, output_file, fps, target_size=target_size)
