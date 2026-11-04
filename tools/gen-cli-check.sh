#!/bin/bash
# Снимок поведения командной строки lilart-gen без видеокарты: справка, ошибки неверных флагов,
# сухой прогон (--dry-run), пересборка листа. Снять до правки кода, сравнить после:
#
#   gen-cli-check.sh record    записать ~/lil-art/golden/cli-base.txt
#   gen-cli-check.sh check     прогнать снова и показать расхождения с записанным
#
# Движок не запускается и модели не грузятся; каждый --dry-run ждёт ответа движка до 5 секунд.
set -uo pipefail
ROOT="$HOME/lil-art"
GEN="${GEN:-$ROOT/tools/lilart-gen}"
MODE="${1:-}"
case "$MODE" in record|check) ;; *) echo "использование: gen-cli-check.sh record|check"; exit 2 ;; esac
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$ROOT/golden"

printf '[{"id":"hero","prompt":"a hero","count":3,"seed":10,"width":512,"height":768},{"id":"bg","prompt":"a wall","count":4}]' > "$W/jobs.json"
printf '[{"id":"../x","prompt":"p"}]' > "$W/bad.json"
printf '  a prompt from a file\n' > "$W/p.txt"
mkdir -p "$W/sheet/hero"
python3 - "$W/sheet" <<'PY'
import sys, zlib, struct
def png(path, c):
    n = 64
    rows = b''.join(b'\x00' + bytes(c) * n for _ in range(n))
    def chunk(t, d):
        x = struct.pack('>I', len(d)) + t + d
        return x + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
d = sys.argv[1] + '/hero'
png(d + '/hero_1_5.png', (200, 30, 30)); png(d + '/hero_2_6.png', (30, 200, 30))
PY
cp "$W/sheet/hero/hero_1_5.png" "$W/in.png"
cd "$W"

run() {
  echo "=== $*"
  local out
  out="$("$GEN" "$@" 2>&1)"
  echo "exit $?"
  # paths of the scratch folder differ between runs
  echo "$out" | sed "s#$W#<W>#g"
}

{
  run
  run --help
  run -h --prompt x
  run --bogus 1
  run --prompt
  run --prompt a --prompt b
  run --prompt a --seed 1 --width 1000
  run --prompt a --seed 1 --height 99999
  run --prompt a --seed 1 --steps 0
  run --prompt a --seed 1 --cfg 99
  run --prompt a --seed 1 --timeout 1
  run --prompt a --seed 1 --limit 0
  run --prompt a --seed 1 --count 9
  run --prompt a --seed 1 --out x.jpg
  run --prompt a --seed 1 --model nope.ckpt
  run --prompt a --seed 1 --sampler nonsense
  run --prompt a --seed 1 --port 70000
  run --seed 1
  run --prompt a --prompt-file "$W/p.txt"
  run --prompt-file "$W/nope.txt"
  run --prompt a --out-dir "$W/o"
  run --jobs "$W/jobs.json" --limit 5
  run --jobs "$W/jobs.json" --out-dir "$W/o"
  run --jobs "$W/jobs.json" --out-dir "$W/o" --limit 5 --prompt a
  run --jobs "$W/bad.json" --out-dir "$W/o" --limit 5
  run --jobs "$W/nope.json" --out-dir "$W/o" --limit 5
  run --prompt a --seed 1 --mask "$W/in.png"
  run --prompt a --seed 1 --image "$W/nope.png"
  run --prompt a --seed 1 --image "$W/in.png" --strength 2
  run --prompt a --seed 1 --mask-blur 100
  run --prompt a --seed 1 --lora nope.ckpt
  run --prompt a --seed 1 --upscaler nope.ckpt
  run --check-part "$W/in.png" --seed 1
  run --squeeze nothing.ckpt
  run --squeeze nothing.ckpt --out "$W/c.ckpt"
  run --sheet "$W/sheet/hero" --seed 1
  run --sheet "$W/nowhere/hero"
  run --sheet "$W/sheet/hero"
  ls "$W/sheet/hero" | sed 's/^/  файл: /'
  run --prompt "a cat" --seed 42 --port 7861 --model flux_3_klein_q8p.ckpt --dry-run
  run --prompt-file "$W/p.txt" --seed 7 --count 3 --out "$W/o/pic.png" --port 7861 --model flux_3_klein_q8p.ckpt --dry-run
  run --jobs "$W/jobs.json" --out-dir "$W/o" --limit 5 --port 7861 --model flux_3_klein_q8p.ckpt --dry-run
  run --jobs "$W/jobs.json" --out-dir "$W/o" --limit 100 --port 7861 --model flux_3_klein_q8p.ckpt --dry-run
} > "$W/result.txt" 2>&1
# every run of the sheet tool writes the same bytes except the timing-free png; keep only text
sed -i '' -E -e "s#$W#<W>#g" -e 's/[0-9]+\.[0-9]+ ?с\b/N с/g' "$W/result.txt"

if [ "$MODE" = record ]; then
  cp "$W/result.txt" "$ROOT/golden/cli-base.txt"
  echo "записано $(grep -c '^===' "$W/result.txt") случаев → golden/cli-base.txt"
else
  cp "$W/result.txt" "$ROOT/golden/cli-now.txt"
  if diff -u "$ROOT/golden/cli-base.txt" "$W/result.txt"; then
    echo "командная строка ведёт себя как раньше: $(grep -c '^===' "$W/result.txt") случаев совпали"
  else
    echo "ЕСТЬ РАСХОЖДЕНИЯ (см. выше)"; exit 1
  fi
fi
