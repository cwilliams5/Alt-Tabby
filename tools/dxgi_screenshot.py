#!/usr/bin/env python3
"""
DXGI Desktop Duplication Screenshot Tool

Takes a screenshot using DXGI Desktop Duplication API instead of GDI.
This should correctly capture windows with acrylic blur effects.

Usage:
    python dxgi_screenshot.py [output_path]

If no output path specified, saves to temp/screenshots/ directory.

Requirements:
    pip install dxcam pillow
"""

import sys
import os
from datetime import datetime

def main():
    # Determine output path
    if len(sys.argv) > 1:
        output_path = sys.argv[1]
    else:
        # Save to temp/screenshots in the repo
        script_dir = os.path.dirname(os.path.abspath(__file__))
        screenshots_dir = os.path.join(script_dir, "screenshots")
        os.makedirs(screenshots_dir, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = os.path.join(screenshots_dir, f"dxgi_screenshot_{timestamp}.png")

    try:
        import dxcam
    except ImportError:
        print("ERROR: dxcam not installed. Run:")
        print("  pip install dxcam pillow")
        sys.exit(1)

    try:
        from PIL import Image
    except ImportError:
        print("ERROR: pillow not installed. Run:")
        print("  pip install pillow")
        sys.exit(1)

    print("Initializing DXGI capture...")

    # Create camera (uses Desktop Duplication API)
    camera = dxcam.create()

    if camera is None:
        print("ERROR: Failed to create DXGI camera. Make sure you have a display connected.")
        sys.exit(1)

    print("Capturing frame via DXGI Desktop Duplication...")

    # Grab a single frame
    frame = camera.grab()

    if frame is None:
        # Sometimes needs a moment for the first frame
        import time
        time.sleep(0.1)
        frame = camera.grab()

    if frame is None:
        print("ERROR: Failed to capture frame. Screen may not have updated recently.")
        print("Try moving your mouse or triggering a screen update, then run again.")
        sys.exit(1)

    # Convert numpy array to PIL Image and save
    img = Image.fromarray(frame)
    img.save(output_path)

    print(f"Screenshot saved to: {output_path}")
    print(f"Size: {img.width}x{img.height}")

    # Cleanup
    del camera

if __name__ == "__main__":
    main()
