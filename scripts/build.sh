#!/usr/bin/env bash
#
# Собрать ядро через Kleaf и разложить результат по dist/<вариант>/.
#
# Использование: build.sh <вариант> [каталог-исходников]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"

VARIANT="${1:-}"
SRC="${2:-$ROOT/src}"
[[ -n "$VARIANT" ]] || { echo "Использование: $0 <вариант> [каталог]" >&2; exit 1; }

OUT="$ROOT/dist/$VARIANT"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

mkdir -p "$OUT"
cd "$SRC"

echo "==> сборка $BAZEL_TARGET (потоков: $JOBS)"
tools/bazel run \
    --disk_cache="$SRC/.bazel-cache" \
    --jobs="$JOBS" \
    "$BAZEL_TARGET" -- --dist_dir="$SRC/out/dist"

echo "==> собираю артефакты"
for f in boot.img boot-gz.img boot-lz4.img Image Image.gz Image.lz4 \
         System.map vmlinux.symvers kernel_aarch64_Module.symvers gki-info.txt; do
    [[ -f "$SRC/out/dist/$f" ]] && cp -v "$SRC/out/dist/$f" "$OUT/"
done

# Модули, если вариант их собирает (mt7601u и спутники).
find "$SRC/out/dist" -maxdepth 1 -name '*.ko' -exec cp -v {} "$OUT/" \; 2>/dev/null || true

[[ -f "$SRC/versions.lock.txt" ]] && cp "$SRC/versions.lock.txt" "$OUT/"

# ── Уровень патча в boot-образах ─────────────────────────────────────────────
# Обязательный шаг, а не косметика: Kleaf проставляет сюда своё значение, и оно
# бывает датой из будущего. Прошивка такого образа необратимо загоняет ключи
# keystore в эту дату. Подробности — в scripts/set-boot-patchlevel.sh.
if [[ -n "${BOOT_SECURITY_PATCH:-}" ]]; then
    echo "==> проставляю boot.security_patch = $BOOT_SECURITY_PATCH"
    for img in "$OUT"/boot*.img; do
        [[ -f "$img" ]] || continue
        "$ROOT/scripts/set-boot-patchlevel.sh" "$img" "$BOOT_SECURITY_PATCH"
    done
else
    echo "!! BOOT_SECURITY_PATCH не задан — оставляю значение от Kleaf."
    echo "!! Проверьте его перед прошивкой: scripts/set-boot-patchlevel.sh <boot.img>"
    for img in "$OUT"/boot*.img; do
        [[ -f "$img" ]] && "$ROOT/scripts/set-boot-patchlevel.sh" "$img"
    done
fi

# ── Готовый к прошивке образ ─────────────────────────────────────────────────
# boot.img от Kleaf собран по разметке GKI и на устройстве уходит в bootloop:
# размер раздела и структура другие. Кладём рядом образ в заводском контейнере.
TPL="$ROOT/device/${DEVICE:-}"
if [[ -n "${DEVICE:-}" && -d "$TPL" && -f "$OUT/Image" ]]; then
    echo "==> собираю готовый к прошивке boot-${DEVICE}.img"
    "$ROOT/scripts/repack-boot.sh" "$TPL" "$OUT/Image" "$OUT/boot-${DEVICE}.img" \
        "${BOOT_SECURITY_PATCH:-}"
else
    echo "!! контейнера device/${DEVICE:-<не задан>} нет — готовый образ не собран"
fi

( cd "$OUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 shasum -a 256 > SHA256SUMS )

echo "==> готово: $OUT"
ls -la "$OUT"
