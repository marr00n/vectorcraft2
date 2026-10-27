#!/usr/bin/env bash
# Have Quick Look make a 512-pixel thumbnail of each document make-test-files.sh wrote, with the
# installed VectorCraft.app's extension (.github/workflows/quicklook-macos.yml).
#
# Usage: packaging/macos/quicklook/check-thumbnails.sh DOCS_DIR OUT_DIR
#
# Fails when a good document gets no thumbnail (or one without the document's colours), or when
# Quick Look takes longer than $QL_TIMEOUT seconds (default 60) on any document. Thumbnails go to
# OUT_DIR/thumbnails, qlmanage's output to OUT_DIR/qlmanage.txt; a summary is printed (and added to
# the job summary on GitHub Actions). Space-bar previews are tried too (qlmanage -p -o), for the
# record only: what qlmanage writes for a data-based preview isn't documented.
set -uo pipefail
DOCS="$1"
OUT="$2"
TIMEOUT="${QL_TIMEOUT:-60}"
THUMBS="$OUT/thumbnails"
mkdir -p "$THUMBS" "$OUT/previews"
LOG="$OUT/qlmanage.txt"
: >"$LOG"

GOOD=(with-preview.vectorcraft compressed.vectorcraft legacy.drawcraft large.vectorcraft)
BAD=(no-preview.vectorcraft too-new.vectorcraft corrupt.vectorcraft garbage.vectorcraft bomb.vectorcraft)

# Run "$@" for at most $1 seconds; 124 when it had to be killed.
within() {
  local secs="$1" pid ticks=0
  shift
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((ticks >= secs * 10)); then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# Does the PNG $1 have pixels near each "#rrggbb" colour after it? (No colour: "is it a PNG?")
# Python's standard library only; an unusual PNG layout prints a note and passes.
has_colours() {
  python3 - "$@" <<'PY'
import struct, sys, zlib
path, colours = sys.argv[1], [tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in sys.argv[2:]]
data = open(path, "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG")
pos, idat, ihdr = 8, b"", None
while pos < len(data):
    n, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    if kind == b"IHDR":
        ihdr = struct.unpack(">IIBBBBB", body)
    elif kind == b"IDAT":
        idat += body
    pos += 12 + n
w, h, depth, ctype, _, _, interlace = ihdr
channels = {2: 3, 6: 4}.get(ctype)
if depth != 8 or channels is None or interlace:
    print(f"note: {path}: depth {depth}, colour type {ctype}, interlace {interlace}: colours not checked")
    sys.exit(0)
raw, stride, prev, rows = zlib.decompress(idat), w * channels, bytearray(w * channels), []
for y in range(h):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a = line[i - channels] if i >= channels else 0
        b, c = prev[i], prev[i - channels] if i >= channels else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line)
    prev = line
seen = {px for row in rows for px in (tuple(row[i:i + 3]) for i in range(0, stride, channels))}
missing = [c for c in colours if not any(sum(abs(p - q) for p, q in zip(c, s)) <= 24 for s in seen)]
if missing:
    sys.exit(f"{path}: no pixels near {['#%02x%02x%02x' % c for c in missing]} ({w}×{h}, {len(seen)} colours)")
print(f"{path}: {w}×{h}, colours found")
PY
}

failed=0
summary="| document | kind | result | seconds |\n|---|---|---|---|\n"
check() {
  local kind="$1" name="$2" doc="$DOCS/$2" png="$THUMBS/$2.png" start status result
  start=$(date +%s)
  echo "== qlmanage -t -s 512 $name" >>"$LOG"
  within "$TIMEOUT" qlmanage -t -s 512 -o "$THUMBS" "$doc"
  status=$?
  local took=$(($(date +%s) - start))
  if [[ "$status" = 124 ]]; then
    result="HUNG (killed after ${TIMEOUT}s)"
    failed=1
  elif [[ -s "$png" ]]; then
    result="thumbnail $(sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}')"
    if [[ "$kind" = good && "$name" = with-preview.vectorcraft ]] && ! has_colours "$png" "#d0402c" "#2c74d0" >>"$LOG" 2>&1; then
      result="$result, WITHOUT the document's colours"
      failed=1
    fi
  elif [[ "$kind" = good ]]; then
    result="NO THUMBNAIL"
    failed=1
  else
    result="no thumbnail (the icon shows)"
  fi
  echo "$name ($kind): $result in ${took}s (qlmanage exit $status)"
  summary+="| $name | $kind | $result | $took |\n"
  # The Space-bar preview, for the record.
  echo "== qlmanage -p -o $name" >>"$LOG"
  within "$TIMEOUT" qlmanage -p -o "$OUT/previews" "$doc"
  if [[ $? = 124 ]]; then
    echo "$name: the preview HUNG (killed after ${TIMEOUT}s)"
    summary+="| $name | preview | HUNG | |\n"
    failed=1
  fi
}

for f in "${GOOD[@]}"; do check good "$f"; done
for f in "${BAD[@]}"; do check bad "$f"; done
ls -lR "$OUT/previews" >>"$LOG" 2>&1
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf "%b" "$summary" >>"$GITHUB_STEP_SUMMARY"; fi
printf "%b" "$summary"
cat "$LOG"
exit "$failed"
