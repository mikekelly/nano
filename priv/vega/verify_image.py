#!/usr/bin/python3
"""Bounded first-frame decoder. Output is fixed status/metadata, never input bytes/errors."""
import io
import json
import os
import resource
import sys
import warnings

# OS bounds also apply to native codecs. A parent timeout independently kills this process.
resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024, 256 * 1024 * 1024))
resource.setrlimit(resource.RLIMIT_CPU, (3, 3))
resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

# Consume and unlink the private raw file immediately; pixel decoding uses bounded RAM.
# This also removes it if the BEAM caller disappears while the decoder keeps running.
try:
    path = sys.argv[1]
    if os.path.basename(path) != "input" or not os.path.basename(os.path.dirname(path)).startswith(".validate-"):
        raise ValueError("private_path")
    with open(path, "rb") as raw:
        input_bytes = raw.read(3_750_001)
    os.unlink(path)
    os.rmdir(os.path.dirname(path))
    if len(input_bytes) > 3_750_000:
        raise ValueError("size")
except Exception:
    print(json.dumps({"error": "invalid_image"}))
    sys.exit(1)

try:
    from PIL import Image, ImageFile

except ImportError:
    print(json.dumps({"error": "decoder_unavailable"}))
    sys.exit(2)

Image.MAX_IMAGE_PIXELS = 4_000_000
ImageFile.LOAD_TRUNCATED_IMAGES = False
warnings.simplefilter("error")
formats = {"PNG": "image/png", "JPEG": "image/jpeg", "GIF": "image/gif", "WEBP": "image/webp"}

try:
    with Image.open(io.BytesIO(input_bytes)) as image:
        mime = formats[image.format]
        width, height = image.size
        if not (0 < width <= 2000 and 0 < height <= 2000):
            raise ValueError("dimensions")
        # Only inspect the existence of a second frame, never iterate/decode all frames.
        # Pillow's is_animated for GIF looks ahead one frame, not n_frames scanning.
        # Reject animation rather than pass later unverified frames to providers.
        if getattr(image, "is_animated", False):
            print(json.dumps({"error": "animated_image"}))
            sys.exit(1)
        image.verify()
    with Image.open(io.BytesIO(input_bytes)) as image:
        image.load()  # first frame only; rejects truncated/invalid compressed pixels
        if image.format not in formats or image.size != (width, height):
            raise ValueError("metadata")
    print(json.dumps({"mime": mime, "width": width, "height": height}))
except Exception:
    print(json.dumps({"error": "invalid_image"}))
    sys.exit(1)
