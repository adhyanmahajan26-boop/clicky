#!/bin/sh
# Checks exported whiteboard PDFs (no poppler needed): pages, sizes, text layer,
# vector vs raster (text/paint operators vs image XObjects), fonts embedded.
#   Tools/eval/pdf_check.sh                     # every PDF in ~/Library/Logs/Clicky/renders/pdf
#   Tools/eval/pdf_check.sh ~/Pictures/Clicky/whiteboard-*.pdf
# One JSON line per file; exit 0 when all are vector with every font embedded.
# The full matrix (pixel diff vs the board render, clipping, light/dark contrast)
# is `swift test --package-path Packages/ClickyCore --filter PDFExportTests`.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$#" -eq 0 ]; then
    set -- "$HOME"/Library/Logs/Clicky/renders/pdf/*.pdf
fi
swift build -q --package-path "$ROOT/Packages/ClickyCore" --product cwb-check
exec "$ROOT/Packages/ClickyCore/.build/debug/cwb-check" --pdf "$@"
