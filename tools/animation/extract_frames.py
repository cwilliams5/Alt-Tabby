"""
Extract PNG frames from a video file with transparency support.
Usage: python extract_frames.py [input.mp4] [output_dir] [fps]

Defaults:
  input: boot1.mp4
  output_dir: frames/
  fps: 0 (use original video fps)
"""

# =============================================================================
# Configuration
# =============================================================================
SKIP_FIRST_X_FRAMES = 7   # Skip first N source frames (low quality intro from Veo)
MAX_VIDEO_FRAMES = 0      # 0 = no limit
FIXED_START_FRAME = ""    # Leave empty to disable
FIXED_END_FRAME = ""      # Leave empty to disable
# =============================================================================

import cv2
import os
import sys
import shutil
from pathlib import Path

def extract_frames(input_video: str, output_dir: str, target_fps: float = 0):
    """Extract frames from video to PNG files with fixed start/end frames."""

    script_dir = Path(__file__).parent
    output_path = Path(output_dir)

    # Check for fixed frames (empty string = disabled)
    fixed_start = None
    fixed_end = None
    if FIXED_START_FRAME:
        fixed_start = script_dir / FIXED_START_FRAME
        if not fixed_start.exists():
            print(f"Warning: {FIXED_START_FRAME} not found - will skip start frame insertion")
            fixed_start = None
    if FIXED_END_FRAME:
        fixed_end = script_dir / FIXED_END_FRAME
        if not fixed_end.exists():
            print(f"Warning: {FIXED_END_FRAME} not found - will skip end frame insertion")
            fixed_end = None

    # Create output directory (clear if exists)
    if output_path.exists():
        shutil.rmtree(output_path)
    os.makedirs(output_dir, exist_ok=True)

    # Open video
    cap = cv2.VideoCapture(input_video)
    if not cap.isOpened():
        print(f"Error: Could not open {input_video}")
        return False

    # Get video properties
    original_fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = total_frames / original_fps if original_fps > 0 else 0

    print(f"Input: {input_video}")
    print(f"  Resolution: {width}x{height}")
    print(f"  FPS: {original_fps:.2f}")
    print(f"  Total source frames: {total_frames}")
    print(f"  Duration: {duration:.2f}s")

    # Calculate frame skip for FPS adjustment
    if target_fps <= 0 or target_fps >= original_fps:
        frame_skip = 1
        actual_fps = original_fps
    else:
        frame_skip = int(original_fps / target_fps)
        actual_fps = original_fps / frame_skip

    print(f"  Output FPS: {actual_fps:.2f} (every {frame_skip} frame(s))")
    if SKIP_FIRST_X_FRAMES > 0:
        print(f"  Skipping first {SKIP_FIRST_X_FRAMES} source frames")
    if MAX_VIDEO_FRAMES > 0:
        print(f"  Max video frames: {MAX_VIDEO_FRAMES}")

    # Determine starting frame number (leave room for fixed start frames)
    start_frame_num = 2 if fixed_start else 0

    frame_idx = 0
    saved_count = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Skip first N frames entirely
        if frame_idx < SKIP_FIRST_X_FRAMES:
            frame_idx += 1
            continue

        # Stop if we've reached max frames (0 = no limit)
        if MAX_VIDEO_FRAMES > 0 and saved_count >= MAX_VIDEO_FRAMES:
            break

        if frame_idx % frame_skip == 0:
            # Save as PNG - number starts at start_frame_num
            out_num = start_frame_num + saved_count
            filename = os.path.join(output_dir, f"frame_{out_num:04d}.png")
            cv2.imwrite(filename, frame, [cv2.IMWRITE_PNG_COMPRESSION, 6])
            saved_count += 1

        frame_idx += 1

    cap.release()

    print(f"\nExtracted {saved_count} video frames")

    # Insert fixed start frames
    if fixed_start:
        shutil.copy(fixed_start, output_path / "frame_0000.png")
        shutil.copy(fixed_start, output_path / "frame_0001.png")
        print(f"  Inserted {FIXED_START_FRAME} as frame_0000.png and frame_0001.png")

    # Insert fixed end frame
    if fixed_end:
        end_frame_num = start_frame_num + saved_count
        shutil.copy(fixed_end, output_path / f"frame_{end_frame_num:04d}.png")
        print(f"  Inserted {FIXED_END_FRAME} as frame_{end_frame_num:04d}.png")

    # Calculate total frames
    total_output = saved_count
    if fixed_start:
        total_output += 2
    if fixed_end:
        total_output += 1

    # Write metadata file for AHK
    meta_file = os.path.join(output_dir, "meta.txt")
    with open(meta_file, "w") as f:
        f.write(f"fps={actual_fps:.2f}\n")
        f.write(f"frames={total_output}\n")
        f.write(f"width={width}\n")
        f.write(f"height={height}\n")
        f.write(f"duration={duration:.2f}\n")

    print(f"\nTotal output: {total_output} frames (0000-{total_output-1:04d})")
    if fixed_start:
        print(f"  - Fixed start: 2 frames (0000-0001)")
        print(f"  - Video: {saved_count} frames (0002-{start_frame_num + saved_count - 1:04d})")
    else:
        print(f"  - Video: {saved_count} frames (0000-{saved_count - 1:04d})")
    if fixed_end:
        print(f"  - Fixed end: 1 frame ({end_frame_num:04d})")
    print(f"Metadata written to {meta_file}")
    return True


if __name__ == "__main__":
    script_dir = Path(__file__).parent

    input_video = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "boot5.mp4")
    output_dir = sys.argv[2] if len(sys.argv) > 2 else str(script_dir / "frames")
    target_fps = float(sys.argv[3]) if len(sys.argv) > 3 else 0

    extract_frames(input_video, output_dir, target_fps)
