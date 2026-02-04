"""
Create an animated GIF from PNG frames.
Usage: python make_gif.py [frames_dir] [output.gif] [fps]

Defaults:
  frames_dir: frames/
  output: animation.gif
  fps: read from meta.txt or 15
"""

import os
import sys
from pathlib import Path
from PIL import Image
import numpy as np


def make_gif(frames_dir: str, output_file: str, fps: float = 15):
    """Create GIF from PNG frames with global palette for color consistency."""

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

    print(f"Creating GIF from {len(frame_files)} frames at {fps:.1f} fps")

    # Load all frames as RGBA first
    print("  Loading frames...")
    rgba_frames = []
    for i, f in enumerate(frame_files):
        img = Image.open(f)
        if img.mode != 'RGBA':
            img = img.convert('RGBA')
        rgba_frames.append(img)

        if (i + 1) % 40 == 0:
            print(f"    Loaded {i + 1}/{len(frame_files)}")

    print(f"    Loaded {len(frame_files)}/{len(frame_files)}")

    # Build a global palette from ALL frames
    # Sample pixels from every frame to capture all colors
    print("  Building global palette from ALL frames...")
    sampled_pixels = []
    pink_pixels = []  # Collect pink separately to ensure they're represented
    pixels_per_frame = 5000

    for i, img in enumerate(rgba_frames):
        arr = np.array(img)
        mask = arr[:, :, 3] > 128  # Non-transparent
        rgba = arr[mask]
        rgb = rgba[:, :3]

        if len(rgb) > 0:
            # Detect pink/red pixels (high R, medium-low G, low B)
            # This specifically captures the cat's pink tongue which only appears in
            # a few frames. Without boosting, the 256-color GIF palette would merge
            # these rare pink pixels with orange fur, turning the tongue gray.
            r, g, b = rgb[:, 0], rgb[:, 1], rgb[:, 2]
            pink_mask = (r > 150) & (r > g + 20) & (r > b + 20) & (g < 160)
            frame_pinks = rgb[pink_mask]
            if len(frame_pinks) > 0:
                pink_pixels.append(frame_pinks)

            # Random sample for general palette
            sample_size = min(pixels_per_frame, len(rgb))
            if len(rgb) > sample_size:
                indices = np.random.choice(len(rgb), sample_size, replace=False)
                rgb = rgb[indices]
            sampled_pixels.append(rgb)

    all_pixels = np.vstack(sampled_pixels)

    # Add extra weight to pink pixels by including them multiple times.
    # This forces the palette quantizer to allocate color slots for the cat's tongue,
    # which would otherwise be merged with similar orange hues and appear gray.
    if pink_pixels:
        all_pinks = np.vstack(pink_pixels)
        print(f"    Found {len(all_pinks)} pink pixels, boosting their representation...")
        if len(all_pinks) > 5000:
            indices = np.random.choice(len(all_pinks), 5000, replace=False)
            all_pinks = all_pinks[indices]
        # Repeat pink pixels 10x to force palette allocation
        boosted_pinks = np.tile(all_pinks, (10, 1))
        all_pixels = np.vstack([all_pixels, boosted_pinks])

    print(f"    Sampled {len(all_pixels)} total pixels for palette")

    # Create a palette image from sampled pixels
    # Use MAXCOVERAGE which tries to preserve minority colors better than MEDIANCUT
    palette_img = Image.new('RGB', (len(all_pixels), 1))
    palette_img.putdata([tuple(p) for p in all_pixels])
    palette_img = palette_img.quantize(colors=255, method=Image.MAXCOVERAGE)
    global_palette = palette_img.getpalette()

    print("  Converting frames to global palette...")
    frames = []
    for i, img in enumerate(rgba_frames):
        alpha = img.getchannel('A')
        rgb = img.convert('RGB')

        # Create palette reference
        pal_img = Image.new('P', (1, 1))
        pal_img.putpalette(global_palette)

        # Quantize RGB to this palette
        img_p = rgb.quantize(palette=pal_img, dither=Image.FLOYDSTEINBERG)

        # Set transparency
        mask = Image.eval(alpha, lambda a: 255 if a <= 128 else 0)
        img_p.paste(255, mask)
        img_p.info['transparency'] = 255

        frames.append(img_p)

        if (i + 1) % 40 == 0:
            print(f"    Converted {i + 1}/{len(rgba_frames)}")

    print(f"    Converted {len(rgba_frames)}/{len(rgba_frames)}")

    # Calculate duration per frame in ms
    duration = int(1000 / fps)

    # Save GIF
    print(f"  Saving GIF with {duration}ms per frame...")
    frames[0].save(
        output_file,
        save_all=True,
        append_images=frames[1:],
        duration=duration,
        loop=0,
        disposal=2,
        transparency=255,
        optimize=False
    )

    file_size = os.path.getsize(output_file) / 1024
    print(f"Saved: {output_file} ({file_size:.1f} KB)")
    return True


if __name__ == "__main__":
    script_dir = Path(__file__).parent

    frames_dir = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "frames")
    output_file = sys.argv[2] if len(sys.argv) > 2 else str(script_dir / "animation.gif")
    fps = float(sys.argv[3]) if len(sys.argv) > 3 else 0

    make_gif(frames_dir, output_file, fps)
