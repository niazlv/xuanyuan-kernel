#!/usr/bin/env bash
#
# Собрать пригодный к прошивке boot.img: своё ядро в заводском контейнере.
#
# ЗАЧЕМ
#
# Kleaf выдаёт boot.img по разметке GKI — 64 МиБ и свой заголовок. У xuanyuan
# раздел boot занимает 96 МиБ, и прошивка образа GKI приводит к bootloop.
# Рабочий образ получается заменой ядра внутри заводского контейнера: заголовок,
# размер раздела и структура AVB остаются такими же, как у стока.
#
# ЧТО ВАЖНО КРОМЕ САМОЙ ЗАМЕНЫ
#
# Ядро другого размера сдвигает блок vbmeta, поэтому в AVBf-footer (последние
# 64 байта раздела) обязательно правятся original_image_size и vbmeta_offset.
# Без этого загрузчик читает свойства не оттуда и не видит
# com.android.build.boot.security_patch — а от него зависит, откроется ли /data.
#
# Подписи AVB после замены ядра недействительны. При разблокированном
# загрузчике они не проверяются; на заблокированном такой образ не загрузится.
#
# Использование:
#   repack-boot.sh <контейнер|стоковый boot.img> <Image> <выход> [ГГГГ-ММ-ДД]
#
# Первым аргументом принимается каталог-контейнер (см. device/) либо стоковый
# boot.img — тогда контейнер снимается с него на лету.
#
# Четвёртый аргумент — уровень патча выходного образа. Не задан — остаётся тот,
# что в контейнере (то есть стоковый; обычно это и нужно).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC=${1:-}
KERNEL=${2:-}
OUT=${3:-}
PATCHLEVEL=${4:-}

if [[ -z "$SRC" || -z "$KERNEL" || -z "$OUT" ]]; then
    echo "Использование: $0 <контейнер|стоковый boot.img> <Image> <выход> [ГГГГ-ММ-ДД]" >&2
    exit 1
fi
[[ -f "$KERNEL" ]] || { echo "нет файла ядра: $KERNEL" >&2; exit 1; }

# Стоковый образ — снимаем контейнер во временный каталог.
TEMPLATE="$SRC"
TMP=""
if [[ -f "$SRC" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "==> снимаю контейнер со стокового образа"
    "$ROOT/extract-boot-template.sh" "$SRC" "$TMP" >/dev/null
    TEMPLATE="$TMP"
elif [[ ! -d "$SRC" ]]; then
    echo "нет ни файла, ни каталога: $SRC" >&2
    exit 1
fi

for f in boot-header.bin boot-signature.bin boot-vbmeta.bin boot-footer.bin boot-layout.env; do
    [[ -f "$TEMPLATE/$f" ]] || { echo "в контейнере нет $f" >&2; exit 1; }
done

TEMPLATE="$TEMPLATE" KERNEL="$KERNEL" OUT="$OUT" python3 - <<'PY'
import os, struct, sys, hashlib

tpl    = os.environ['TEMPLATE']
kernel = open(os.environ['KERNEL'], 'rb').read()
out    = os.environ['OUT']

cfg = {}
for line in open(os.path.join(tpl, 'boot-layout.env')):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        k, v = line.split('=', 1)
        cfg[k] = v

PART = int(cfg['PARTITION_SIZE'])
PAGE = int(cfg['PAGE_SIZE'])
RS   = int(cfg['RAMDISK_SIZE'])

def pad_to(n, p=PAGE):
    return (n + p - 1) // p * p

header = bytearray(open(os.path.join(tpl, 'boot-header.bin'), 'rb').read())
sig    = open(os.path.join(tpl, 'boot-signature.bin'), 'rb').read()
vbmeta = open(os.path.join(tpl, 'boot-vbmeta.bin'), 'rb').read()
footer = open(os.path.join(tpl, 'boot-footer.bin'), 'rb').read()

rd_path = os.path.join(tpl, 'boot-ramdisk.bin')
ramdisk = open(rd_path, 'rb').read() if os.path.exists(rd_path) else b''
if len(ramdisk) != RS:
    sys.exit(f"ramdisk в контейнере ({len(ramdisk)}) не совпал с RAMDISK_SIZE ({RS})")

print(f"ядро: {cfg.get('STOCK_KERNEL_SIZE','?')} -> {len(kernel)}")

struct.pack_into('<I', header, 8, len(kernel))

body  = bytes(header)
body += kernel  + b'\x00' * (pad_to(len(kernel)) - len(kernel))
body += ramdisk + b'\x00' * (pad_to(len(ramdisk)) - len(ramdisk))
body += sig

vbmeta_off = len(body)
if vbmeta_off + len(vbmeta) > PART:
    sys.exit(f"образ не влезает в раздел: нужно {vbmeta_off + len(vbmeta)}, есть {PART}")

image = bytearray(body + vbmeta + b'\x00' * (PART - vbmeta_off - len(vbmeta)))
image[PART - 64:PART] = footer
struct.pack_into('>QQQ', image, PART - 64 + 12, vbmeta_off, vbmeta_off, len(vbmeta))

open(out, 'wb').write(bytes(image))

# ── Проверки ────────────────────────────────────────────────────────────────
chk = open(out, 'rb').read()
errors = []

if len(chk) != PART:
    errors.append(f"размер {len(chk)} != раздела {PART}")
if chk[:8] != b'ANDROID!':
    errors.append("потеряна магия ANDROID!")
if struct.unpack_from('<I', chk, 8)[0] != len(kernel):
    errors.append("kernel_size в заголовке не совпал")
if chk[PAGE:PAGE + len(kernel)] != kernel:
    errors.append("ядро записано не побайтово")

o, vo, vs = struct.unpack_from('>QQQ', chk, PART - 64 + 12)
if (o, vo, vs) != (vbmeta_off, vbmeta_off, len(vbmeta)):
    errors.append("footer не обновился")
if chk[vo:vo + 4] != b'AVB0':
    errors.append("по новому vbmeta_offset нет магии AVB0")

KEY = b'com.android.build.boot.security_patch\x00'
i = chk.find(KEY)
if i < 0:
    errors.append("свойство boot.security_patch потерялось")
else:
    print(f"boot.security_patch: {chk[i+len(KEY):i+len(KEY)+10].decode(errors='replace')}")

if errors:
    sys.exit("ПРОВЕРКА НЕ ПРОШЛА:\n  - " + "\n  - ".join(errors))

print(f"готово: {out} ({len(chk)} байт), vbmeta на {vbmeta_off}")
PY

if [[ -n "$PATCHLEVEL" ]]; then
    echo
    "$ROOT/set-boot-patchlevel.sh" "$OUT" "$PATCHLEVEL"
fi
