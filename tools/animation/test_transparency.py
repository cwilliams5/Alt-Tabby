"""
Test transparency quality by compositing a frame against multiple backgrounds.
Outputs a comparison image showing the frame on white, black, red, green, blue.

Usage: python test_transparency.py [frame_path] [output_path]
"""

import cv2
import numpy as np
import sys
from pathlib import Path


def composite_on_background(frame_bgra, bg_color):
    """Composite BGRA frame onto solid background color."""
    h, w = frame_bgra.shape[:2]

    # Create background
    bg = np.full((h, w, 3), bg_color, dtype=np.uint8)

    # Extract channels
    b, g, r, a = cv2.split(frame_bgra)
    alpha = a.astype(np.float32) / 255.0

    # Composite: result = fg * alpha + bg * (1 - alpha)
    result = np.zeros((h, w, 3), dtype=np.uint8)
    for i, (fg_ch, bg_ch) in enumerate(zip([b, g, r], cv2.split(bg))):
        result[:, :, i] = (fg_ch * alpha + bg_ch * (1 - alpha)).astype(np.uint8)

    return result


def create_test_composite(frame_path: str, output_path: str = None):
    """Create a side-by-side comparison on multiple backgrounds."""

    frame = cv2.imread(frame_path, cv2.IMREAD_UNCHANGED)
    if frame is None:
        print(f"Error: Could not read {frame_path}")
        return False

    if frame.shape[2] == 3:
        print("Warning: Frame has no alpha channel")
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2BGRA)

    h, w = frame.shape[:2]

    # Background colors (BGR)
    backgrounds = [
        ("White", (255, 255, 255)),
        ("Black", (0, 0, 0)),
        ("Red", (0, 0, 255)),
        ("Green", (0, 255, 0)),
        ("Blue", (255, 0, 0)),
    ]

    # Create composites
    composites = []
    for name, color in backgrounds:
        comp = composite_on_background(frame, color)
        # Add label
        cv2.putText(comp, name, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1,
                    (128, 128, 128) if name == "Black" else (0, 0, 0), 2)
        composites.append(comp)

    # Scale down for reasonable output size
    scale = 0.5 if w > 800 else 1.0
    if scale != 1.0:
        composites = [cv2.resize(c, None, fx=scale, fy=scale) for c in composites]
        h, w = composites[0].shape[:2]

    # Arrange: 3 on top, 2 on bottom centered
    row1 = np.hstack(composites[:3])

    # Center the bottom row
    padding = w // 2
    row2_content = np.hstack(composites[3:])
    row2 = np.full((h, w * 3, 3), 200, dtype=np.uint8)  # Gray padding
    row2[:, padding:padding + w * 2] = row2_content

    result = np.vstack([row1, row2])

    if output_path is None:
        output_path = str(Path(frame_path).parent / "test_composite.png")

    cv2.imwrite(output_path, result)
    print(f"Saved test composite to: {output_path}")

    # Also analyze edge quality
    analyze_edges(frame)

    return True


def analyze_edges(frame_bgra):
    """Analyze the edges of the transparent content for quality issues."""
    b, g, r, a = cv2.split(frame_bgra)

    # Find edge pixels (where alpha transitions)
    alpha_dilated = cv2.dilate(a, np.ones((3, 3), np.uint8))
    alpha_eroded = cv2.erode(a, np.ones((3, 3), np.uint8))
    edge_mask = (alpha_dilated > 0) & (alpha_eroded < 255)

    # Get brightness at edges
    brightness = np.maximum(np.maximum(r, g), b)
    edge_brightness = brightness[edge_mask]

    # Get alpha values at edges
    edge_alpha = a[edge_mask]

    # Find "problem" pixels: opaque but very dark (the black outline)
    opaque_edge_mask = edge_mask & (a > 200)
    dark_opaque_edges = brightness[opaque_edge_mask]

    print(f"\nEdge Analysis:")
    print(f"  Total edge pixels: {np.sum(edge_mask)}")
    print(f"  Edge brightness: min={edge_brightness.min()}, max={edge_brightness.max()}, mean={edge_brightness.mean():.1f}")
    print(f"  Opaque edge pixels (a>200): {np.sum(opaque_edge_mask)}")
    if len(dark_opaque_edges) > 0:
        dark_count = np.sum(dark_opaque_edges < 30)
        print(f"  Dark opaque edges (brightness<30): {dark_count} ({100*dark_count/len(dark_opaque_edges):.1f}%)")
        print(f"    -> These cause the visible black outline")


if __name__ == "__main__":
    script_dir = Path(__file__).parent

    frame_path = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "frames" / "frame_0072.png")
    output_path = sys.argv[2] if len(sys.argv) > 2 else None

    create_test_composite(frame_path, output_path)
