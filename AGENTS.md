# User-provided photos

When the user attaches or references HEIC/HEIF photos, convert them to PNG before viewing with `convert_heic_to_png.py`. For attachments outside this repository, use `--output-dir photo` to keep generated previews in the local ignored photo directory. Never modify the originals. View the resulting PNG files before describing their contents.

The same script supports `--watch` to convert new HEIC/HEIF files dropped into this project (including subfolders). Existing PNG files are preserved.
