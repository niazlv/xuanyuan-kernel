#!/usr/bin/env bash
#
# Достать строку версии ядра из стокового boot.img.
#
# Нужно для двух вещей:
#   1. GKI_COMMON_REF в config/versions.env — коммит зашит в саму строку:
#        6.6.118-android15-8-ge56cf6b09cca-ab15511674-4k
#                            ^^^^^^^^^^^^ -> e56cf6b09cca
#   2. Настройка подмены uname в susFS, если ядро выдаёт себя за стоковое:
#        uname -r  = release (второе слово строки)
#        uname -v  = хвост "#1 SMP PREEMPT <дата>"
#
# Заодно печатает объявленный уровень патча — полезно свериться перед прошивкой.
#
# Использование: stock-kernel-string.sh <boot.img>

set -euo pipefail

IMG=${1:-}
if [[ -z "$IMG" || ! -f "$IMG" ]]; then
    echo "Использование: $0 <boot.img>" >&2
    exit 1
fi

IMG="$IMG" python3 - <<'PY'
import os, re, sys

img = os.environ['IMG']
data = open(img, 'rb').read()

m = re.search(rb'Linux version [0-9][^\x00\n]{0,500}', data)
if not m:
    sys.exit(f"{img}: строка 'Linux version ...' не найдена")

s = m.group().decode(errors='replace')
release = s.split()[2]

print("полная строка:")
print(f"  {s}")
print()
print(f"uname -r (release):  {release}")

v = re.search(r'(#\d+\s+SMP\s+PREEMPT\s+.+)$', s)
if v:
    print(f"uname -v (version):  {v.group(1)}")

g = re.search(r'-g([0-9a-f]{7,40})-', release)
if g:
    print(f"GKI_COMMON_REF:      {g.group(1)}")

base = release.split('-')[0]
print(f"KERNEL_BASE_VERSION: {base}")

KEY = b'com.android.build.boot.security_patch\x00'
p = data.find(KEY)
if p >= 0:
    at = p + len(KEY)
    print(f"boot.security_patch: {data[at:at+10].decode(errors='replace')}")
PY
