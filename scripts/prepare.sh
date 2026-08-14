#!/usr/bin/env bash
#
# Подготовить дерево исходников под конкретный вариант сборки:
# подключить KernelSU-Next и susFS из апстрима, наложить патчи из patches/,
# добавить конфиг-фрагменты и проставить брендирование.
#
# Использование: prepare.sh <вариант> [каталог-исходников]
#   вариант: vanilla | ksunext | ksunext-susfs

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"

VARIANT="${1:-}"
SRC="${2:-$ROOT/src}"

case "$VARIANT" in
    vanilla|ksunext|ksunext-susfs) ;;
    *) echo "Использование: $0 <vanilla|ksunext|ksunext-susfs> [каталог]" >&2; exit 1 ;;
esac

SERIES="$ROOT/series/$VARIANT"
[[ -f "$SERIES" ]] || { echo "нет файла series: $SERIES" >&2; exit 1; }

COMMON="$SRC/common"
[[ -d "$COMMON" ]] || { echo "нет дерева исходников: $COMMON (сначала setup-source.sh)" >&2; exit 1; }

LOCK="$SRC/versions.lock.txt"
: > "$LOCK"

note() { echo "$*" >> "$LOCK"; }

# Патчи пишутся под конкретную базу GKI, а база двигается: между 6.6.77 и 6.6.118
# контекст вокруг однострочных правок успевает разъехаться. Поэтому применяем
# лесенкой, от строгого к терпимому, и запоминаем, каким способом легло —
# чтобы нечистое применение было видно в versions.lock.txt, а не молча прошло.
apply_patch() {
    local patch_file="$1" label="$2"

    if git -C "$COMMON" apply -v "$patch_file" 2>/dev/null; then
        echo "    [точно]   $label"
        note "patch: $label (точно)"
        return 0
    fi

    if git -C "$COMMON" apply -3 -v "$patch_file" 2>/dev/null; then
        echo "    [3-way]   $label"
        note "patch: $label (трёхсторонним слиянием)"
        return 0
    fi

    if patch -d "$COMMON" -p1 --forward --fuzz=3 --silent < "$patch_file"; then
        echo "    [с фаззом] $label  <- контекст разъехался, проверьте результат"
        note "patch: $label (С ФАЗЗОМ, контекст не совпал точно)"
        return 0
    fi

    echo "!! не удалось применить: $label" >&2
    return 1
}

echo "==> вариант: $VARIANT"
note "variant: $VARIANT"
note "gki_common: $(git -C "$COMMON" rev-parse HEAD)"
note "kernel_base: $KERNEL_BASE_VERSION"

# ── KernelSU-Next ────────────────────────────────────────────────────────────
# Повторяем то, что делает официальный kernel/setup.sh, но с закреплением на
# коммите: пайпить curl в bash в CI не хочется, да и воспроизводимость теряется.
if [[ "$VARIANT" != vanilla ]]; then
    echo "==> подключаю KernelSU-Next ($KSU_NEXT_REF)"
    if [[ ! -d "$SRC/KernelSU-Next" ]]; then
        # -b понимает ветку и тег, но не голый SHA, а его можно передать входным
        # параметром workflow. Поэтому при неудаче клонируем целиком и отцепляемся.
        git clone --depth=1 -b "$KSU_NEXT_REF" "$KSU_NEXT_REPO" "$SRC/KernelSU-Next" 2>/dev/null || {
            git clone "$KSU_NEXT_REPO" "$SRC/KernelSU-Next"
            git -C "$SRC/KernelSU-Next" checkout --detach "$KSU_NEXT_REF"
        }
    fi
    KSU_SHA="$(git -C "$SRC/KernelSU-Next" rev-parse HEAD)"
    note "kernelsu_next: $KSU_SHA ($KSU_NEXT_REF)"

    ln -sfn ../../KernelSU-Next/kernel "$COMMON/drivers/kernelsu"

    grep -q 'kernelsu' "$COMMON/drivers/Makefile" \
        || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$COMMON/drivers/Makefile"
    grep -q 'drivers/kernelsu/Kconfig' "$COMMON/drivers/Kconfig" \
        || sed -i.bak '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$COMMON/drivers/Kconfig"

    # Без .git внутри дерева KSU определяет версию как 1, а тег как v0.0.1.
    KBUILD="$SRC/KernelSU-Next/kernel/Kbuild"
    if [[ -f "$KBUILD" ]]; then
        sed -i.bak \
            -e "s/^KSU_VERSION_FALLBACK := .*/KSU_VERSION_FALLBACK := ${KSU_VERSION_FALLBACK}/" \
            -e "s/^KSU_VERSION_TAG_FALLBACK := .*/KSU_VERSION_TAG_FALLBACK := ${KSU_VERSION_TAG_FALLBACK}/" \
            "$KBUILD"
        echo "    версия-заглушка: $KSU_VERSION_FALLBACK / $KSU_VERSION_TAG_FALLBACK"
    fi

    cat "$ROOT/config/fragments/ksu.config" >> "$COMMON/arch/arm64/configs/gki_defconfig"
fi

# ── susFS ────────────────────────────────────────────────────────────────────
if [[ "$VARIANT" == ksunext-susfs ]]; then
    echo "==> подключаю susFS ($SUSFS_REF)"
    if [[ ! -d "$SRC/susfs4ksu" ]]; then
        git clone --depth=1 -b "$SUSFS_REF" "$SUSFS_REPO" "$SRC/susfs4ksu" 2>/dev/null || {
            git clone "$SUSFS_REPO" "$SRC/susfs4ksu"
            git -C "$SRC/susfs4ksu" checkout --detach "$SUSFS_REF"
        }
    fi
    note "susfs4ksu: $(git -C "$SRC/susfs4ksu" rev-parse HEAD) ($SUSFS_REF)"

    KP="$SRC/susfs4ksu/kernel_patches"
    cp -v "$KP"/fs/* "$COMMON/fs/"
    cp -v "$KP"/include/linux/* "$COMMON/include/linux/"

    # Имя патча зависит от ветки susfs, поэтому ищем, а не хардкодим.
    SUSFS_PATCH="$(find "$KP" -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -1)"
    [[ -n "$SUSFS_PATCH" ]] || { echo "не нашёл 50_add_susfs_in_*.patch в $KP" >&2; exit 1; }
    apply_patch "$SUSFS_PATCH" "susfs/$(basename "$SUSFS_PATCH")"

    cat "$ROOT/config/fragments/susfs.config" >> "$COMMON/arch/arm64/configs/gki_defconfig"
fi

# ── Патчи репозитория ────────────────────────────────────────────────────────
echo "==> накладываю патчи по series/$VARIANT"
while read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    patch_file="$ROOT/$line"
    [[ -f "$patch_file" ]] || { echo "нет патча: $patch_file" >&2; exit 1; }
    apply_patch "$patch_file" "$line"
done < "$SERIES"

# ── Брендирование kernel release ─────────────────────────────────────────────
# Kleaf без git-стампа подставляет "-maybe-dirty". Меняем на осмысленный суффикс,
# чтобы по uname было видно, что за сборка.
STAMP="$SRC/build/kleaf/impl/stamp.bzl"
SUFFIX="-${KERNEL_SUFFIX_BASE}-${VARIANT}"
if [[ -f "$STAMP" ]]; then
    sed -i.bak "s|echo '-maybe-dirty'|echo '${SUFFIX}'|" "$STAMP"
    echo "==> суффикс kernel release: $SUFFIX"
    note "kernel_suffix: $SUFFIX"
else
    echo "!! не найден $STAMP — суффикс не проставлен, сборка получит -maybe-dirty" >&2
fi

echo "==> подготовка завершена"
cat "$LOCK"
