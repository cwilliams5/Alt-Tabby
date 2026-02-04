"""
Remove black background from frames and add transparency.
Usage: python add_transparency.py [frames_dir] [threshold] [--smooth|--flood]

The threshold (0-255) determines how dark a pixel must be to become transparent.
Default threshold: 12 (catches near-black pixels and noise)

Options:
  --hard      Hard cutoff, all black pixels (default)
  --smooth    Gradient alpha (softer edges but may affect dark content)
  --flood     Only remove black connected to image edges (preserves internal black like eyes)
"""

# =============================================================================
# Configuration: Targeted trapped background removal
# =============================================================================
# These coordinates specify trapped bg pockets that flood fill can't reach
# (e.g., between arm and whiskers). Format: {frame_number: [(x, y), ...]}
# Set to empty dict {} to disable targeted removal.
#
# Trap Pocket 1: Between arm/face/whisker area (~500, 300 region)
# Trap Pocket 2: Right side area (~830, 370 region)
#
TRAPPED_BG_COORDS = {
    # Pocket 2 only (frames 87-90)
    87: [(834, 360)],
    88: [(830, 365)],
    89: [(830, 365)],
    90: [(828, 367)],
    # Both pockets (frames 91-94) - Pocket 1 can be non-contiguous
    91: [(505, 306), (464, 227), (826, 369)],
    92: [(505, 306), (464, 227), (826, 369)],
    93: [(490, 290), (464, 227), (826, 369)],
    94: [(482, 276), (452, 225), (826, 369)],  # Pocket 1 drifts
    # Pocket 2 only (frames 95-100)
    95: [(827, 370)],
    96: [(827, 370)],
    97: [(827, 370)],
    98: [(827, 370)],
    99: [(827, 370)],
    100: [(827, 370)],
    # Both pockets (frame 101)
    101: [(502, 310), (827, 370)],
    # Pocket 2 only (frames 102-103)
    102: [(827, 370)],
    103: [(827, 370)],
    # Both pockets (frames 104-108)
    104: [(501, 311), (827, 370)],
    105: [(501, 311), (827, 370)],
    106: [(501, 311), (827, 370)],
    107: [(501, 311), (827, 370)],
    108: [(501, 311), (827, 370)],
    # Pocket 2 only (frames 109-114)
    109: [(827, 370)],
    110: [(827, 370)],
    111: [(827, 370)],
    112: [(827, 370)],
    113: [(827, 370)],
    114: [(827, 370)],
    # Both pockets - Pocket 1 splits into 2 (frame 115)
    115: [(498, 316), (456, 247), (827, 371)],
}
TRAPPED_BG_RADIUS = 150  # Search radius around each coordinate

# Frames to skip (already have correct transparency from Photoshop)
SKIP_FRAMES = []  # Empty = process all frames
# =============================================================================

import cv2
import numpy as np
import sys
from pathlib import Path


def add_transparency_hard(frames_dir: str, threshold: int = 12):
    """
    Convert black background to transparent using hard cutoff.
    """
    frames_path = Path(frames_dir)
    frame_files = sorted(frames_path.glob("frame_*.png"))

    if not frame_files:
        print(f"Error: No frame_*.png files in {frames_dir}")
        return False

    print(f"Processing {len(frame_files)} frames (hard cutoff, threshold={threshold})")

    for i, f in enumerate(frame_files):
        img = cv2.imread(str(f), cv2.IMREAD_UNCHANGED)
        if img is None:
            continue

        if img.shape[2] == 3:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2BGRA)

        b, g, r, a = cv2.split(img)
        brightness = np.maximum(np.maximum(r, g), b)
        a = np.where(brightness <= threshold, 0, 255).astype(np.uint8)

        img = cv2.merge([b, g, r, a])
        cv2.imwrite(str(f), img, [cv2.IMWRITE_PNG_COMPRESSION, 6])

        if (i + 1) % 20 == 0 or i == len(frame_files) - 1:
            print(f"  Processed {i + 1}/{len(frame_files)}")

    print("Done!")
    return True


def soft_defringe(a, brightness):
    """
    Soft defringe - creates graduated alpha at edges based on brightness.

    Instead of hard removal of edge pixels, this makes them semi-transparent
    based on how dark they are. This:
    - Blends better on light backgrounds (no harsh black outline)
    - Preserves content edges like buttons and whiskers
    - Creates a natural anti-aliased look

    Brightness to alpha mapping for edge pixels:
    - 0-15: fully transparent (anti-aliasing from pure black)
    - 15-40: graduated transparency (the fringe zone)
    - 40+: fully opaque (real content)
    """
    kernel = np.ones((3, 3), np.uint8)
    a_out = a.astype(np.float32)

    # Process 4 rings of edge pixels to handle thick anti-aliasing fringes
    for ring in range(4):
        # Find current edge (opaque pixels adjacent to transparent)
        transparent_mask = (a_out < 128).astype(np.uint8)
        transparent_dilated = cv2.dilate(transparent_mask, kernel, iterations=1)
        edge_mask = (transparent_dilated == 1) & (a_out >= 128)

        # Calculate alpha based on brightness
        # brightness 15 -> alpha 0, brightness 40 -> alpha 255
        edge_alpha = np.clip((brightness.astype(np.float32) - 15) * (255.0 / 25), 0, 255)

        # Apply to edge pixels (take minimum to not increase existing alpha)
        a_out = np.where(edge_mask, np.minimum(a_out, edge_alpha), a_out)

    return a_out.astype(np.uint8)


def remove_trapped_at_coordinates(a, brightness, target_coords, threshold=15, radius=150):
    """
    Remove trapped background pockets at specific coordinates.

    Instead of trying to automatically detect trapped bg (which risks removing
    facial features like nose/lips), this allows surgical removal at known
    problem coordinates.

    Args:
        a: Alpha channel
        brightness: Brightness channel
        target_coords: List of (x, y) centers where trapped bg pockets exist
        threshold: Brightness threshold for "dark" pixels
        radius: Search radius around each coordinate

    Returns:
        Modified alpha channel and count of regions removed
    """
    if not target_coords:
        return a, 0

    h, w = a.shape

    # Find dark opaque pixels
    dark_mask = ((brightness <= threshold) & (a > 200)).astype(np.uint8)

    # Find connected components
    num_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(dark_mask)

    removed_count = 0
    for tx, ty in target_coords:
        # Find the dark region closest to this target coordinate
        best_label = None
        best_dist = float('inf')

        for label in range(1, num_labels):
            cx, cy = centroids[label]
            dist = np.sqrt((cx - tx)**2 + (cy - ty)**2)

            if dist < radius and dist < best_dist:
                best_dist = dist
                best_label = label

        if best_label is not None:
            # Remove this region
            a[labels == best_label] = 0
            removed_count += 1

    return a, removed_count


def add_transparency_flood(frames_dir: str, threshold: int = 12):
    """
    Convert black background to transparent, but ONLY black pixels connected to image edges.
    This preserves internal black areas (like cat eyes, nose, lips) that are surrounded by
    non-black pixels.

    Also applies:
    - Despeckle: removes small isolated noise clusters
    - Targeted trapped pocket removal: removes specific dark regions at coordinates
      defined in TRAPPED_BG_COORDS (preserves facial features by being surgical)
    - Soft defringe: creates graduated alpha at edges based on brightness,
      which blends nicely on light backgrounds while preserving content
    """
    frames_path = Path(frames_dir)
    frame_files = sorted(frames_path.glob("frame_*.png"))

    if not frame_files:
        print(f"Error: No frame_*.png files in {frames_dir}")
        return False

    print(f"Processing {len(frame_files)} frames (flood fill + soft defringe, threshold={threshold})")

    for i, f in enumerate(frame_files):
        # Skip frames that already have correct transparency (e.g., from Photoshop)
        if i in SKIP_FRAMES:
            continue

        img = cv2.imread(str(f), cv2.IMREAD_UNCHANGED)
        if img is None:
            continue

        if img.shape[2] == 3:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2BGRA)

        b, g, r, a = cv2.split(img)
        h, w = img.shape[:2]

        brightness = np.maximum(np.maximum(r, g), b)

        # Create mask of "black" pixels
        black_mask = (brightness <= threshold).astype(np.uint8)

        # Despeckle: morphological opening removes tiny isolated noise
        kernel = np.ones((3, 3), np.uint8)
        black_mask_clean = cv2.morphologyEx(black_mask, cv2.MORPH_OPEN, kernel)

        # Flood fill from all edges to find exterior black
        fillable = (black_mask_clean * 255).astype(np.uint8)
        flood_mask = np.zeros((h + 2, w + 2), dtype=np.uint8)
        fill_value = 128

        for x in range(w):
            if fillable[0, x] == 255:
                cv2.floodFill(fillable, flood_mask, (x, 0), fill_value)
            if fillable[h-1, x] == 255:
                cv2.floodFill(fillable, flood_mask, (x, h-1), fill_value)

        for y in range(h):
            if fillable[y, 0] == 255:
                cv2.floodFill(fillable, flood_mask, (0, y), fill_value)
            if fillable[y, w-1] == 255:
                cv2.floodFill(fillable, flood_mask, (w-1, y), fill_value)

        # Create alpha: 0 for exterior black, 255 for everything else
        a = np.where(fillable == fill_value, 0, 255).astype(np.uint8)

        # Targeted removal of trapped background pockets at specific coordinates
        # Extract frame number from filename (frame_0081.png -> 81)
        frame_num = int(f.stem.split('_')[1])
        if frame_num in TRAPPED_BG_COORDS:
            coords = TRAPPED_BG_COORDS[frame_num]
            a, _ = remove_trapped_at_coordinates(a, brightness, coords, threshold=15, radius=TRAPPED_BG_RADIUS)

        # Soft defringe - graduated alpha at edges
        a = soft_defringe(a, brightness)

        img = cv2.merge([b, g, r, a])
        cv2.imwrite(str(f), img, [cv2.IMWRITE_PNG_COMPRESSION, 6])

        if (i + 1) % 20 == 0 or i == len(frame_files) - 1:
            print(f"  Processed {i + 1}/{len(frame_files)}")

    print("Done! Frames have transparent backgrounds with soft edge blending.")
    return True


def add_transparency_smooth(frames_dir: str, dark_threshold: int = 12, edge_feather: int = 2):
    """
    Remove black background with smooth edge feathering.
    """
    frames_path = Path(frames_dir)
    frame_files = sorted(frames_path.glob("frame_*.png"))

    if not frame_files:
        print(f"Error: No frame_*.png files in {frames_dir}")
        return False

    print(f"Processing {len(frame_files)} frames (smooth mode, threshold={dark_threshold}, feather={edge_feather})")

    for i, f in enumerate(frame_files):
        img = cv2.imread(str(f), cv2.IMREAD_UNCHANGED)
        if img is None:
            continue

        if img.shape[2] == 3:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2BGRA)

        b, g, r, a = cv2.split(img)
        brightness = np.maximum(np.maximum(r, g), b).astype(np.float32)

        transition = 10
        alpha = np.clip((brightness - dark_threshold) * (255.0 / transition), 0, 255)

        if edge_feather > 0:
            alpha = cv2.GaussianBlur(alpha, (edge_feather * 2 + 1, edge_feather * 2 + 1), 0)

        a = alpha.astype(np.uint8)

        img = cv2.merge([b, g, r, a])
        cv2.imwrite(str(f), img, [cv2.IMWRITE_PNG_COMPRESSION, 6])

        if (i + 1) % 20 == 0 or i == len(frame_files) - 1:
            print(f"  Processed {i + 1}/{len(frame_files)}")

    print("Done!")
    return True


if __name__ == "__main__":
    script_dir = Path(__file__).parent
    frames_dir = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "frames")

    smooth = "--smooth" in sys.argv
    flood = "--flood" in sys.argv

    threshold = 12
    for arg in sys.argv[1:]:
        if arg.isdigit():
            threshold = int(arg)
            break

    if flood:
        add_transparency_flood(frames_dir, threshold)
    elif smooth:
        add_transparency_smooth(frames_dir, threshold)
    else:
        add_transparency_hard(frames_dir, threshold)
