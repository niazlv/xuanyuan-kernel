#!/usr/bin/env bash
#
# Показать или изменить уровень патча безопасности, объявленный в boot-образе.
#
# ЗАЧЕМ ЭТО ВООБЩЕ НУЖНО
#
# Загрузчик берёт BOOT_PATCHLEVEL из AVB-свойства
# com.android.build.boot.security_patch, лежащего ВНУТРИ boot.img, и передаёт
# его в TEE. Ключи keystore привязываются к этому значению, а KeyMint двигает
# его ТОЛЬКО ВВЕРХ.
#
# Отсюда следствие, которое стоит запомнить: если прошить boot-образ с
# ЗНАЧЕНИЕМ МЕНЬШИМ, чем то, под которым были выпущены ключи, то ключи станут
# непригодны и /data перестанет расшифровываться — TEE ответит
# INVALID_ARGUMENT (-38) на upgradeKey. Понижение необратимо: вернуть ключи на
# меньший уровень нельзя ничем, кроме сброса к заводским настройкам.
#
# Обратная сторона того же правила: ЗАВЫШАТЬ дату тоже нельзя. Образ прошьётся
# и заработает, но ключи привяжутся к завышенному уровню, и после этого любой
# стоковый образ станет для них понижением — сломаются и OTA, и откат на другую
# версию прошивки. Правильное значение — то, что объявляет стоковый boot.img
# вашей прошивки (scripts/stock-kernel-string.sh).
#
# Kleaf проставляет сюда собственное значение, и там встречаются даты вроде
# 2099-12-31. Один такой образ отрезает вообще всё. Поэтому значение задаётся
# явно, а не берётся по умолчанию.
#
# Замена побайтовая: даты всегда 10 символов, смещения не едут. Подпись AVB при
# этом становится неверной, но при разблокированном загрузчике
# (verifiedbootstate=orange) она не проверяется, а свойство всё равно читается.
#
# Использование:
#   set-boot-patchlevel.sh <boot.img>                 показать текущее
#   set-boot-patchlevel.sh <boot.img> ГГГГ-ММ-ДД      записать на месте

set -euo pipefail

IMG=${1:-}
NEW=${2:-}

if [[ -z "$IMG" || ! -f "$IMG" ]]; then
    echo "Использование: $0 <boot.img> [ГГГГ-ММ-ДД]" >&2
    exit 1
fi

if [[ -n "$NEW" && ! "$NEW" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Дата должна быть строго в формате ГГГГ-ММ-ДД (10 символов), получено: '$NEW'" >&2
    exit 1
fi

IMG="$IMG" NEW="$NEW" python3 - <<'PY'
import os, sys

img = os.environ['IMG']
new = os.environ['NEW']
KEY = b'com.android.build.boot.security_patch\x00'

data = bytearray(open(img, 'rb').read())

if bytes(data[:8]) != b'ANDROID!':
    sys.exit(f"{img}: не boot-образ (нет магии ANDROID!)")

pos = data.find(KEY)
if pos < 0:
    sys.exit(f"{img}: AVB-дескриптор com.android.build.boot.security_patch не найден")

at = pos + len(KEY)
cur = bytes(data[at:at + 10]).decode(errors='replace')

print(f"образ:   {img}")
print(f"текущий: {cur}")

if not new:
    sys.exit(0)

if cur == new:
    print("уже требуемое значение, правка не нужна")
    sys.exit(0)

data[at:at + 10] = new.encode()
open(img, 'wb').write(data)

check = open(img, 'rb').read()
got = check[check.find(KEY) + len(KEY):][:10].decode(errors='replace')
if got != new:
    sys.exit(f"ПРОВЕРКА НЕ ПРОШЛА: в файле {got}, ожидалось {new}")

print(f"новый:   {got}")

if new < cur:
    print()
    print("!! ВНИМАНИЕ: значение ПОНИЖЕНО.")
    print("!! Если ключи устройства выпущены под более высоким уровнем,")
    print("!! этот образ заблокирует доступ к /data без возможности отката.")
PY
