#!/usr/bin/env python3
"""
Convert PNG to multi-size ICO for Windows icons.

Usage: python convert-ico.py [input.png] [output.ico]

Defaults:
  input:  img/icon.png
  output: img/icon.ico

Creates ICO with 16x16, 32x32, 48x48, and 256x256 sizes embedded.
Requires: pip install Pillow
"""

from PIL import Image
import struct
import io
import sys
import os

def create_ico(input_path, output_path, sizes=[16, 32, 48, 256]):
    """Create a multi-size ICO file from a PNG."""

    # Load source image
    src = Image.open(input_path).convert('RGBA')
    print(f'Source: {input_path} ({src.size[0]}x{src.size[1]})')

    # Generate PNG data for each size
    png_data_list = []
    for size in sizes:
        resized = src.resize((size, size), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        resized.save(buf, format='PNG')
        png_data_list.append(buf.getvalue())
        print(f'  Created {size}x{size}: {len(buf.getvalue())} bytes')

    # Build ICO file manually
    # ICO Header: reserved (2), type=1 (2), count (2)
    ico_header = struct.pack('<HHH', 0, 1, len(sizes))

    # Calculate offsets - header is 6 bytes, each entry is 16 bytes
    data_offset = 6 + (16 * len(sizes))

    entries = []
    for i, size in enumerate(sizes):
        png_bytes = png_data_list[i]
        w = size if size < 256 else 0  # 0 means 256 in ICO format
        h = size if size < 256 else 0
        # ICONDIRENTRY: width, height, colors=0, reserved=0, planes=1, bpp=32, size, offset
        entry = struct.pack('<BBBBHHII', w, h, 0, 0, 1, 32, len(png_bytes), data_offset)
        entries.append(entry)
        data_offset += len(png_bytes)

    # Write ICO file
    with open(output_path, 'wb') as f:
        f.write(ico_header)
        for entry in entries:
            f.write(entry)
        for png_bytes in png_data_list:
            f.write(png_bytes)

    print(f'\nCreated: {output_path}')
    print(f'  {len(sizes)} sizes embedded: {", ".join(f"{s}x{s}" for s in sizes)}')

def main():
    # Default paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_input = os.path.join(script_dir, 'img', 'icon.png')
    default_output = os.path.join(script_dir, 'img', 'icon.ico')

    # Parse args
    input_path = sys.argv[1] if len(sys.argv) > 1 else default_input
    output_path = sys.argv[2] if len(sys.argv) > 2 else default_output

    if not os.path.exists(input_path):
        print(f'Error: Input file not found: {input_path}')
        sys.exit(1)

    create_ico(input_path, output_path)

if __name__ == '__main__':
    main()
