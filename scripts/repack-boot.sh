#!/usr/bin/env bash
#
# Вложить собранное ядро в стоковый boot.img устройства.
#
# ЗАЧЕМ
#
# Kleaf собирает boot.img по разметке GKI: размер 64 МиБ и свой заголовок.
# У xuanyuan раздел boot — 96 МиБ, и прошивка образа GKI даёт bootloop.
# Рабочий образ получается заменой ядра внутри СТОКОВОГО boot.img: заголовок,
# размер раздела и структура AVB при этом остаются заводскими.
#
# Стоковый boot.img — часть прошивки Xiaomi, поэтому в релизах его нет и быть
# не может. Возьмите его из fastboot-ROM своей версии (images/boot.img) или
# считайте с устройства.
#
# ЧТО ДЕЛАЕТ
#
# Заменяет ядро, пересобирает образ и корректирует смещения в структурах AVB:
# vbmeta переезжает вслед за изменившимся размером ядра, а AVBf-footer в конце
# раздела получает новые original_image_size и vbmeta_offset. Без этого
# загрузчик читал бы свойства не оттуда и не увидел бы boot.security_patch.
#
# Подписи AVB после замены ядра становятся недействительными. При
# разблокированном загрузчике (verifiedbootstate=orange) они не проверяются;
# на заблокированном такой образ не загрузится — это ожидаемо.
#
# Использование:
#   repack-boot.sh <стоковый boot.img> <Image> <выходной boot.img> [ГГГГ-ММ-ДД]
#
# Четвёртый аргумент — уровень патча для выходного образа. Если не задан,
# сохраняется значение из стокового образа (обычно это и нужно).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STOCK=${1:-}
KERNEL=${2:-}
OUT=${3:-}
PATCHLEVEL=${4:-}

if [[ -z "$STOCK" || -z "$KERNEL" || -z "$OUT" ]]; then
    echo "Использование: $0 <стоковый boot.img> <Image> <выходной boot.img> [ГГГГ-ММ-ДД]" >&2
    exit 1
fi
[[ -f "$STOCK"  ]] || { echo "нет файла: $STOCK" >&2; exit 1; }
[[ -f "$KERNEL" ]] || { echo "нет файла: $KERNEL" >&2; exit 1; }

STOCK="$STOCK" KERNEL="$KERNEL" OUT="$OUT" python3 - <<'PY'
import os, struct, sys

stock_path  = os.environ['STOCK']
kernel_path = os.environ['KERNEL']
out_path    = os.environ['OUT']

PAGE = 4096
def pad_to(n, p=PAGE):
    return (n + p - 1) // p * p

stock = open(stock_path, 'rb').read()
kernel = open(kernel_path, 'rb').read()

if stock[:8] != b'ANDROID!':
    sys.exit(f"{stock_path}: не boot-образ (нет магии ANDROID!)")

hdr_version = struct.unpack_from('<I', stock, 40)[0]
kernel_size, ramdisk_size = struct.unpack_from('<II', stock, 8)

print(f"стоковый образ: {len(stock)} байт, hdr_v{hdr_version}")
print(f"  ядро    {kernel_size} -> {len(kernel)}")
print(f"  ramdisk {ramdisk_size}")

# Раскладка стокового образа
k_off = PAGE
r_off = k_off + pad_to(kernel_size)
s_off = r_off + pad_to(ramdisk_size)          # подпись boot (v4)

ramdisk = stock[r_off:r_off + ramdisk_size]

# Размер подписи берём как расстояние до vbmeta, а не из поля заголовка:
# так надёжнее, поле в разных версиях лежит по-разному.
footer_off = len(stock) - 64
if stock[footer_off:footer_off + 4] != b'AVBf':
    sys.exit("AVBf-footer не найден в конце образа — структура неожиданная, не рискую")

orig_size, vbmeta_off, vbmeta_size = struct.unpack_from('>QQQ', stock, footer_off + 12)
print(f"  AVB: образ {orig_size}, vbmeta на {vbmeta_off} размером {vbmeta_size}")

sig = stock[s_off:vbmeta_off]
vbmeta = stock[vbmeta_off:vbmeta_off + vbmeta_size]
if vbmeta[:4] != b'AVB0':
    sys.exit("по vbmeta_offset нет магии AVB0 — структура неожиданная, не рискую")

# Сборка нового образа
header = bytearray(stock[:PAGE])
struct.pack_into('<I', header, 8, len(kernel))

body  = bytes(header)
body += kernel + b'\x00' * (pad_to(len(kernel)) - len(kernel))
body += ramdisk + b'\x00' * (pad_to(len(ramdisk)) - len(ramdisk))
body += sig

new_vbmeta_off = len(body)
new_image = body + vbmeta

if len(new_image) > len(stock):
    sys.exit(f"новый образ ({len(new_image)}) не влезает в раздел ({len(stock)})")

# Добиваем нулями до размера раздела и кладём footer с новыми смещениями.
new_image += b'\x00' * (len(stock) - len(new_image))
new_image = bytearray(new_image)
new_image[footer_off:footer_off + 64] = stock[footer_off:footer_off + 64]
struct.pack_into('>QQQ', new_image, footer_off + 12,
                 new_vbmeta_off, new_vbmeta_off, vbmeta_size)

open(out_path, 'wb').write(bytes(new_image))

# ── Проверки ────────────────────────────────────────────────────────────────
check = open(out_path, 'rb').read()
errors = []

if len(check) != len(stock):
    errors.append(f"размер {len(check)} != стокового {len(stock)}")
if check[:8] != b'ANDROID!':
    errors.append("потеряна магия ANDROID!")
if struct.unpack_from('<I', check, 8)[0] != len(kernel):
    errors.append("kernel_size в заголовке не совпал")
if check[PAGE:PAGE + len(kernel)] != kernel:
    errors.append("ядро записано не побайтово")

o, vo, vs = struct.unpack_from('>QQQ', check, footer_off + 12)
if (o, vo, vs) != (new_vbmeta_off, new_vbmeta_off, vbmeta_size):
    errors.append("footer не обновился")
if check[vo:vo + 4] != b'AVB0':
    errors.append("по новому vbmeta_offset нет магии AVB0")

KEY = b'com.android.build.boot.security_patch\x00'
i = check.find(KEY)
if i < 0:
    errors.append("свойство boot.security_patch потерялось")
else:
    print(f"  boot.security_patch: {check[i+len(KEY):i+len(KEY)+10].decode(errors='replace')}")

if errors:
    sys.exit("ПРОВЕРКА НЕ ПРОШЛА:\n  - " + "\n  - ".join(errors))

print(f"готово: {out_path} ({len(check)} байт), vbmeta переехал на {new_vbmeta_off}")
PY

if [[ -n "$PATCHLEVEL" ]]; then
    echo
    "$ROOT/set-boot-patchlevel.sh" "$OUT" "$PATCHLEVEL"
fi

echo
echo "Перед прошивкой сверьте уровень патча с тем, под которым выпущены ключи"
echo "устройства — понижение необратимо ломает расшифровку /data."
