#!/bin/bash
# Эталонные картинки lil art: снять один раз до рефакторинга и потом сравнивать.
#
#   golden.sh record    нарисовать эталоны в golden/base в папке проекта (закрыв lil art!)
#   golden.sh check     нарисовать заново в golden/now и сравнить с эталонами
#
# Картинки рисует tools/lilart-gen: тот же движок, что и в приложении. Один и тот же сид движок
# повторяет не до последнего бита (отличие в среднем 0.001–0.03 из 255), поэтому сравнение
# идёт с допуском: pngdiff.swift считает среднее отличие, порог 0.5.
# Поэтому эталоны привязаны к версии движка: после его обновления снять заново.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GEN="$ROOT/tools/lilart-gen"
HERE="$ROOT/tools"
MODE="${1:-}"
case "$MODE" in
  record) OUT="$ROOT/golden/base" ;;
  check) OUT="$ROOT/golden/now" ;;
  *) echo "использование: golden.sh record|check"; exit 2 ;;
esac
if pgrep -f "/lil art.app/" >/dev/null; then
  echo "lil art открыта: закройте её, иначе движок и модель займут память дважды"; exit 1
fi
mkdir -p "$OUT"
rm -f "$OUT"/*.png

# маска для правки: белый квадрат в середине, всё остальное чёрное
python3 - "$OUT/mask.png" <<'PY'
import sys, zlib, struct
n = 1024
rows = b''.join(b'\x00' + bytes((255 if 320 <= x < 704 and 320 <= y < 704 else 0) for x in range(n))
                for y in range(n))
def chunk(t, d):
    c = struct.pack('>I', len(d)) + t + d
    return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 0, 0, 0, 0))
                              + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
PY

MODEL=flux_2_klein_4b_q8p.ckpt
"$GEN" --model $MODEL --seed 12345 --width 1024 --height 1024 \
  --prompt "a red apple on a wooden table, studio light" --out "$OUT/t2i_apple.png"
"$GEN" --model $MODEL --seed 777 --width 1024 --height 1024 \
  --prompt "a quiet street with a bicycle leaning on a blue wall, morning light" --out "$OUT/t2i_street.png"
"$GEN" --model $MODEL --seed 4242 --width 1024 --height 1024 \
  --image "$HERE/gen-test/apple_1024.png" --mask "$OUT/mask.png" \
  --prompt "replace the masked area with a ripe orange" --out "$OUT/edit_masked.png"

if [ "$MODE" = record ]; then echo "эталоны сняты: $OUT"; shasum -a 256 "$OUT"/*.png | sed "s#$OUT/##"; exit 0; fi

BASE="$ROOT/golden/base"
bad=0
for f in t2i_apple t2i_street edit_masked; do
  if cmp -s "$BASE/$f.png" "$OUT/$f.png"; then
    echo "совпало: $f"
  else
    printf '%s: ' "$f"
    [ -x "$ROOT/golden/pngdiff" ] && [ "$ROOT/golden/pngdiff" -nt "$HERE/pngdiff.swift" ] \
      || swiftc -O "$HERE/pngdiff.swift" -o "$ROOT/golden/pngdiff"
    "$ROOT/golden/pngdiff" "$BASE/$f.png" "$OUT/$f.png" || bad=1
  fi
done
exit $bad
