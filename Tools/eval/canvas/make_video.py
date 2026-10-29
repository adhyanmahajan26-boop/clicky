#!/usr/bin/env python3
"""Generates Tools/eval/canvas/video/dots.mp4 for the P6.11 video rows.

Offline, with a local ffmpeg (nothing is downloaded): a white 1280x720
clip whose coloured squares hold still for each 4 s segment listed under
pages.video.segments in manifest.json (the page reads the same manifest for
its truth). Usage: python3 -I Tools/eval/canvas/make_video.py [--ffmpeg PATH]
Python 3.9, standard library only.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

CANVAS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))


def drawbox_filters(video_spec):
    filters = []
    for segment in video_spec["segments"]:
        for square in segment["squares"]:
            x, y, width, height = square["rect"]
            filters.append("drawbox=x=%d:y=%d:w=%d:h=%d:color=%s:t=fill:enable='between(t,%g,%g)'" % (
                x, y, width, height, square["color"], segment["start"], segment["end"] - 0.001))
    return ",".join(filters)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    arguments = parser.parse_args()
    if not arguments.ffmpeg:
        sys.exit("ffmpeg not found; install it yourself (this script never downloads anything)")
    with open(os.path.join(CANVAS_DIRECTORY, "manifest.json"), encoding="utf-8") as manifest_file:
        video_spec = json.load(manifest_file)["pages"]["video"]
    output_path = os.path.join(CANVAS_DIRECTORY, video_spec["src"])
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    command = [arguments.ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi",
               "-i", "color=c=white:s=%dx%d:d=%d:r=10" % (video_spec["width"], video_spec["height"], video_spec["duration"]),
               "-vf", drawbox_filters(video_spec), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10", "-crf", "28",
               "-movflags", "+faststart", output_path]
    subprocess.run(command, check=True)
    print("wrote %s (%d bytes)" % (output_path, os.path.getsize(output_path)))


if __name__ == "__main__":
    main()
