#!/usr/bin/env bash
#
# Снять «контейнер» со стокового boot.img: всё, кроме ядра.
#
# Kleaf собирает boot.img по разметке GKI, и на xuanyuan он не грузится:
# размер и структура другие. Рабочий образ получается вкладыванием своего ядра
# в заводской контейнер. Но целиком стоковый boot.img таскать в репозитории
# незачем — ядро оттуда всё равно выбрасывается. Достаточно ~23 КБ метаданных:
# заголовок, подпись boot v4, блок vbmeta и AVBf-footer.
#
# Так в репозитории не оказывается ни байта чужого кода, а собрать пригодный к
# прошивке образ можно без стоковой прошивки под рукой.
#
# Использование: extract-boot-template.sh <стоковый boot.img> <каталог>

set -euo pipefail

IMG=${1:-}
OUT=${2:-}

if [[ -z "$IMG" || -z "$OUT" ]]; then
    echo "Использование: $0 <стоковый boot.img> <каталог>" >&2
    exit 1
fi
[[ -f "$IMG" ]] || { echo "нет файла: $IMG" >&2; exit 1; }

mkdir -p "$OUT"

IMG="$IMG" OUT="$OUT" python3 - <<'PY'
import os, struct, sys, hashlib

img_path = os.environ['IMG']
out_dir  = os.environ['OUT']

PAGE = 4096
def pad_to(n, p=PAGE):
    return (n + p - 1) // p * p

d = open(img_path, 'rb').read()
if d[:8] != b'ANDROID!':
    sys.exit(f"{img_path}: не boot-образ (нет магии ANDROID!)")

kernel_size, ramdisk_size = struct.unpack_from('<II', d, 8)
hdr_version = struct.unpack_from('<I', d, 40)[0]

k_off = PAGE
r_off = k_off + pad_to(kernel_size)
s_off = r_off + pad_to(ramdisk_size)

footer_off = len(d) - 64
if d[footer_off:footer_off + 4] != b'AVBf':
    sys.exit("AVBf-footer не найден в конце образа")

orig_size, vbmeta_off, vbmeta_size = struct.unpack_from('>QQQ', d, footer_off + 12)
if d[vbmeta_off:vbmeta_off + 4] != b'AVB0':
    sys.exit("по vbmeta_offset нет магии AVB0")

parts = {
    'boot-header.bin':    d[:PAGE],
    'boot-signature.bin': d[s_off:vbmeta_off],
    'boot-vbmeta.bin':    d[vbmeta_off:vbmeta_off + vbmeta_size],
    'boot-footer.bin':    d[footer_off:footer_off + 64],
}
if ramdisk_size:
    parts['boot-ramdisk.bin'] = d[r_off:r_off + ramdisk_size]

for name, blob in parts.items():
    open(os.path.join(out_dir, name), 'wb').write(blob)
    print(f"  {name}: {len(blob)} байт")

with open(os.path.join(out_dir, 'boot-layout.env'), 'w') as f:
    f.write(f"""# Контейнер стокового boot.img. Ядра здесь НЕТ — только структура образа,
# в которую вкладывается своё ядро (scripts/repack-boot.sh).
PARTITION_SIZE={len(d)}
PAGE_SIZE={PAGE}
RAMDISK_SIZE={ramdisk_size}
HEADER_VERSION={hdr_version}
STOCK_KERNEL_SIZE={kernel_size}
STOCK_KERNEL_SHA256={hashlib.sha256(d[k_off:k_off+kernel_size]).hexdigest()}
STOCK_IMAGE_SHA256={hashlib.sha256(d).hexdigest()}
""")

total = sum(len(b) for b in parts.values())
print(f"итого {total} байт в {out_dir}, раздел {len(d)}")
PY
