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
    local patch_file="$1" label="$2" method=""

    if git -C "$COMMON" apply -v "$patch_file" 2>/dev/null; then
        method="точно"
    elif patch -d "$COMMON" -p1 --forward --fuzz=3 --silent < "$patch_file"; then
        method="С ФАЗЗОМ, контекст не совпал точно"
    else
        echo "!! не удалось применить: $label" >&2
        return 1
    fi

    # git apply -3 здесь намеренно НЕ используется. Без blob'ов исходного дерева
    # трёхстороннее слияние не отказывается, а вписывает в файлы маркеры
    # конфликта и отчитывается успехом. Ломается это только на компиляции,
    # причём далеко от места ошибки:
    #   clear_page.S:18: error: version control conflict marker in file
    # Поэтому после каждого наложения проверяем затронутые файлы.
    local f
    for f in $(sed -n 's|^+++ b/||p' "$patch_file"); do
        if [[ -f "$COMMON/$f" ]] && grep -qE '^(<<<<<<<|>>>>>>>) ' "$COMMON/$f"; then
            echo "!! $label: в $f остались маркеры конфликта" >&2
            return 1
        fi
    done

    echo "    [$method] $label"
    note "patch: $label ($method)"
}

echo "==> вариант: $VARIANT"
note "variant: $VARIANT"
note "gki_common: $(git -C "$COMMON" rev-parse HEAD)"
note "kernel_base: $KERNEL_BASE_VERSION"

# GKI android14+ из google-артефактов защищает часть экспортируемых символов
# файлами android/abi_gki_protected_exports_*. С ними вендорные модули (WiFi и
# др.) не находят нужные символы, не грузятся, и устройство уходит в bootloop на
# этапе загрузки модулей (лого -> откат на рабочий слот). susfs README требует
# удалять их; рабочий ksun33177 это и делал. Common сбрасывается перед prepare,
# так что удаление идемпотентно.
for f in abi_gki_protected_exports_aarch64 abi_gki_protected_exports_x86_64; do
    if [[ -f "$COMMON/android/$f" ]]; then
        # НЕ удаляем: BUILD.bazel объявляет файл как вход, удаление ломает анализ
        # ("missing input file"). Обнуляем — пустой список защищённых экспортов =
        # вендорные модули видят все символы и грузятся.
        : > "$COMMON/android/$f"
        echo "==> обнулил android/$f (иначе вендорные модули не грузятся)"
        note "emptied: android/$f"
    fi
done

# ── KernelSU-Next ────────────────────────────────────────────────────────────
# Повторяем то, что делает официальный kernel/setup.sh, но с закреплением на
# коммите: пайпить curl в bash в CI не хочется, да и воспроизводимость теряется.
if [[ "$VARIANT" != vanilla ]]; then
    # ksunext-susfs берёт форк pershoot (вшит susfs); ksunext — mainline KSU-Next.
    # Код pershoot требует <linux/susfs.h>, поэтому для ksunext он не годится.
    if [[ "$VARIANT" == ksunext-susfs ]]; then
        KSU_NEXT_REPO="$KSU_NEXT_SUSFS_REPO"
        KSU_NEXT_REF="$KSU_NEXT_SUSFS_REF"
        KSU_VERSION_FALLBACK="$KSU_SUSFS_VERSION_FALLBACK"
        KSU_VERSION_TAG_FALLBACK="$KSU_SUSFS_VERSION_TAG_FALLBACK"
    fi
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

    # KernelSU-Next версионируется из git (напр. pershoot: 30000 + rev-list count).
    # При shallow-клоне count = 1 -> мусорная версия. Убираем .git и полагаемся на
    # KSU_VERSION_*_FALLBACK ниже, чтобы версия была детерминированной.
    rm -rf "$SRC/KernelSU-Next/.git"

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

    # Патчи KSU-стороны для susfs-варианта: команды susfs, которых нет в форке
    # (напр. add_sus_map_target_uid). Форк pershoot dev-susfs уже несёт основную
    # интеграцию susfs, поэтому 10_enable_susfs_for_ksu.patch НЕ применяется.
    if [[ "$VARIANT" == ksunext-susfs && -d "$ROOT/patches/ksu" ]]; then
        shopt -s nullglob
        for kp in "$ROOT"/patches/ksu/*.patch; do
            echo "==> KSU susfs-патч: $(basename "$kp")"
            if patch -d "$SRC/KernelSU-Next" -p1 --forward --fuzz=3 --silent < "$kp"; then
                note "ksu_patch: ksu/$(basename "$kp")"
            else
                echo "!! не удалось применить KSU-патч $(basename "$kp")" >&2
                exit 1
            fi
        done
        shopt -u nullglob
    fi

    cat "$ROOT/config/fragments/ksu.config" >> "$COMMON/arch/arm64/configs/gki_defconfig"
fi

# ── susFS ────────────────────────────────────────────────────────────────────
if [[ "$VARIANT" == ksunext-susfs ]]; then
    # SUSFS_LOCAL позволяет собрать из локального дерева susfs4ksu (напр. с
    # незапушенными правками), не клонируя из SUSFS_REPO.
    if [[ -n "${SUSFS_LOCAL:-}" ]]; then
        echo "==> susFS из локального дерева: $SUSFS_LOCAL"
        [[ -d "$SUSFS_LOCAL/kernel_patches" ]] || { echo "нет $SUSFS_LOCAL/kernel_patches" >&2; exit 1; }
        SUSFS_DIR="$SUSFS_LOCAL"
        note "susfs4ksu: local:$SUSFS_LOCAL"
    else
        echo "==> подключаю susFS ($SUSFS_REF)"
        SUSFS_DIR="$SRC/susfs4ksu"
        if [[ ! -d "$SUSFS_DIR" ]]; then
            git clone --depth=1 -b "$SUSFS_REF" "$SUSFS_REPO" "$SUSFS_DIR" 2>/dev/null || {
                git clone "$SUSFS_REPO" "$SUSFS_DIR"
                git -C "$SUSFS_DIR" checkout --detach "$SUSFS_REF"
            }
        fi
        note "susfs4ksu: $(git -C "$SUSFS_DIR" rev-parse HEAD) ($SUSFS_REF)"
    fi

    KP="$SUSFS_DIR/kernel_patches"
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
# Манифест GKI кладёт проект kernel/build в build/kernel, но в старых
# манифестах путь был build/. Проверяем оба, иначе брендирование молча не
# применяется и сборка получает суффикс -maybe-dirty.
STAMP=""
for candidate in "$SRC/build/kernel/kleaf/impl/stamp.bzl" "$SRC/build/kleaf/impl/stamp.bzl"; do
    [[ -f "$candidate" ]] && { STAMP="$candidate"; break; }
done
SUFFIX="-${KERNEL_SUFFIX_BASE}-${VARIANT}"
if [[ -n "$STAMP" ]]; then
    sed -i.bak "s|echo '-maybe-dirty'|echo '${SUFFIX}'|" "$STAMP"
    echo "==> суффикс kernel release: $SUFFIX"
    note "kernel_suffix: $SUFFIX"
else
    echo "!! stamp.bzl не найден — суффикс не проставлен, сборка получит -maybe-dirty" >&2
fi

echo "==> подготовка завершена"
cat "$LOCK"
