#!/bin/zsh
cd -- "${0:A:h}" || exit 1
exec python3 ./convert_heic_to_png.py --watch
