#!/usr/bin/env bash
#
# Выкачать дерево GKI под сборку Kleaf.
#
# Исходники в репозитории не хранятся — они тянутся из AOSP по манифесту и
# закрепляются на коммите из config/versions.env. Это и есть смысл разделения:
# здесь лежат только патчи и рецепт, а ядро приезжает из апстрима.
#
# Использование: setup-source.sh [каталог]   (по умолчанию ./src)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"

SRC="${1:-$ROOT/src}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

mkdir -p "$SRC"
cd "$SRC"

if ! command -v repo >/dev/null 2>&1; then
    echo "==> ставлю repo"
    mkdir -p "$HOME/.bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.bin/repo"
    chmod +x "$HOME/.bin/repo"
    export PATH="$HOME/.bin:$PATH"
fi

echo "==> repo init: $GKI_MANIFEST_BRANCH"
repo init --depth=1 -u "$GKI_MANIFEST_URL" -b "$GKI_MANIFEST_BRANCH"

echo "==> repo sync (потоков: $JOBS)"
repo sync -c -j"$JOBS" --no-tags --no-clone-bundle --fail-fast

# Манифест указывает на голову ветки, а нам нужен коммит целевой прошивки.
if [[ -n "${GKI_COMMON_REF:-}" ]]; then
    echo "==> закрепляю common/ на $GKI_COMMON_REF"
    git -C common fetch --depth=1 origin "$GKI_COMMON_REF"
    git -C common checkout --detach FETCH_HEAD
fi

echo "==> common/ на коммите: $(git -C common rev-parse HEAD)"
echo "==> версия из Makefile: $(make -s -C common kernelversion 2>/dev/null || echo '?')"
