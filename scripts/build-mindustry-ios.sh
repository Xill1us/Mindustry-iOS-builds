#!/usr/bin/env bash
#
# Сборка неподписанного Mindustry.ipa из исходников Anuken/Mindustry (ветка master)
# для GitHub Actions (macOS runner).
#
# Рецепт (композитная сборка Arc + jnigen для iOS-натива) собран на основе
# публично задокументированного, реально работающего подхода стороннего
# автоматического билдера Mindustry->iOS (RoboVM 2.3.24, JDK 17, локальный
# composite-build Arc рядом с Mindustry). Это НЕофициальный путь сборки —
# Anuken не публикует официальную инструкцию по iOS-сборке для сторонних лиц,
# поэтому скрипт умышленно многословный в логах: если что-то отломится в
# будущем (Anuken поменяет структуру build.gradle, RoboVM обновится и т.д.),
# по логу будет видно, на каком именно шаге.
#
# Использование (вызывается из workflow, но можно и локально на macOS):
#   scripts/build-mindustry-ios.sh clone
#   scripts/build-mindustry-ios.sh detect_version
#   scripts/build-mindustry-ios.sh build
#   scripts/build-mindustry-ios.sh package
#   scripts/build-mindustry-ios.sh summary
#
set -uo pipefail

WORKSPACE_ROOT="$(pwd)"
LOG_FILE="$WORKSPACE_ROOT/build.log"
DIST_DIR="$WORKSPACE_ROOT/dist"
MINDUSTRY_REPO="https://github.com/Anuken/Mindustry.git"
ARC_REPO="https://github.com/Anuken/Arc.git"

touch "$LOG_FILE"
# Всё, что печатает скрипт (stdout+stderr), одновременно копится в build.log
# на протяжении ВСЕХ шагов джоба (append), чтобы при падении на любом шаге
# в артефакте с логом была полная картина, а не только последний шаг.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "----- [$(date -u +%H:%M:%S)] subcommand: ${1:-<none>} -----"

# ---------------------------------------------------------------------------
# clone: тянем master Mindustry и Arc как соседние директории.
# Mindustry/settings.gradle сам обнаруживает локальный ../Arc и использует
# его как composite build вместо ненадёжного jitpack-джара.
# ---------------------------------------------------------------------------
cmd_clone() {
  set -e
  echo "=== Клонирую Anuken/Mindustry (master) ==="
  git clone --depth 1 --branch master "$MINDUSTRY_REPO" Mindustry

  local arc_ref="${ARC_REF:-master}"
  echo "=== Клонирую Anuken/Arc (${arc_ref}) ==="
  git clone --depth 1 --branch "$arc_ref" "$ARC_REPO" Arc

  echo "Mindustry HEAD: $(git -C Mindustry rev-parse HEAD)"
  echo "Arc HEAD:       $(git -C Arc rev-parse HEAD)"
}

# ---------------------------------------------------------------------------
# detect_version: у master нет официального версионного тега, поэтому:
#  - смотрим последний официальный release-тег Anuken/Mindustry (например v160)
#  - если текущий HEAD master ровно совпадает с коммитом этого тега —
#    считаем сборку "релизной" и называем файл Mindustry_v8.<num>.ipa
#  - если master уже ушёл вперёд (есть неизданные коммиты) — по вашему
#    указанию откатываемся на простое имя Mindustry.ipa, без номера версии,
#    т.к. в таком состоянии официального номера ещё не существует
#  - любая ошибка сети/API тоже трактуется как "не смогли" -> Mindustry.ipa
# ---------------------------------------------------------------------------
cmd_detect_version() {
  # тут НЕ используем set -e жёстко — сетевые сбои должны мягко
  # деградировать до запасного имени файла, а не валить весь job
  local upstream_tag="" upstream_num="" tag_sha="" head_sha="" short_sha=""
  local is_exact="false" version_display="" ipa_name="" app_build_num="0"
  local api_json

  head_sha="$(git -C Mindustry rev-parse HEAD)"
  short_sha="$(git -C Mindustry rev-parse --short HEAD)"

  echo "=== Запрашиваю последний официальный релиз Anuken/Mindustry ==="
  api_json="$(curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/Anuken/Mindustry/releases/latest" 2>>"$LOG_FILE")" || api_json=""

  if [ -n "$api_json" ]; then
    upstream_tag="$(echo "$api_json" | jq -r '.tag_name // empty' 2>>"$LOG_FILE" || true)"
  fi

  if [ -n "$upstream_tag" ]; then
    upstream_num="${upstream_tag#v}"
    echo "Последний upstream-релиз: ${upstream_tag} (build ${upstream_num})"

    tag_sha="$(git ls-remote "$MINDUSTRY_REPO" "refs/tags/${upstream_tag}^{}" 2>>"$LOG_FILE" | cut -f1)"
    if [ -z "$tag_sha" ]; then
      tag_sha="$(git ls-remote "$MINDUSTRY_REPO" "refs/tags/${upstream_tag}" 2>>"$LOG_FILE" | cut -f1)"
    fi

    if [ -n "$tag_sha" ] && [ "$tag_sha" = "$head_sha" ]; then
      is_exact="true"
    fi
  else
    echo "!!! Не удалось получить последний релиз через GitHub API — использую запасное имя файла."
  fi

  if [ "$is_exact" = "true" ]; then
    if [[ "$upstream_num" == *.* ]]; then
      version_display="v8.${upstream_num}"
    else
      version_display="v8.${upstream_num}.0"
    fi
    ipa_name="Mindustry_${version_display}.ipa"
    app_build_num="${upstream_num%%.*}"
  else
    version_display="master@${short_sha}"
    ipa_name="Mindustry.ipa"
    if [ -n "$upstream_num" ]; then
      app_build_num="${upstream_num%%.*}"
    fi
  fi

  echo "=== Итог определения версии ==="
  echo "master HEAD:            ${head_sha}"
  echo "Совпадает с релиз-тегом: ${is_exact}"
  echo "Отображаемая версия:     ${version_display}"
  echo "Имя файла:               ${ipa_name}"

  {
    echo "upstream_tag=${upstream_tag}"
    echo "head_sha=${head_sha}"
    echo "short_sha=${short_sha}"
    echo "is_exact=${is_exact}"
    echo "version_display=${version_display}"
    echo "ipa_name=${ipa_name}"
    echo "app_build_num=${app_build_num}"
  } >> "$GITHUB_OUTPUT"
}

# ---------------------------------------------------------------------------
# build: собственно сборка неподписанного .ipa
# ---------------------------------------------------------------------------
cmd_build() {
  set -e
  cd Mindustry
  chmod +x gradlew

  echo "=== Java / Gradle окружение ==="
  java -version
  ./gradlew --version

  echo "=== Патчу ios/build.gradle: принудительно iosSkipSigning=true ==="
  # На отсутствие сертификатов/профиля нам подписывать не нужно — ipa
  # ставится через LiveContainer, который сам переподписывает на устройстве.
  sed -i '' 's/iosSkipSigning = false/iosSkipSigning = true/' ios/build.gradle
  if ! grep -q "iosSkipSigning = true" ios/build.gradle; then
    echo "!!! Не удалось найти/заменить строку iosSkipSigning в ios/build.gradle."
    echo "!!! Похоже, Anuken изменил формат файла. Сборку продолжать нет смысла."
    exit 1
  fi
  grep -n "iosSkipSigning" ios/build.gradle

  local build_num="${APP_BUILD_NUM:-0}"
  echo "Внутренний (косметический) номер версии приложения: ${build_num}"

  echo "=== Собираю iOS-натив движка Arc (jnigen + MetalANGLEKit) ==="
  # Два независимых, но одинаково обязательных шага:
  #  1) jnigenBuildAllIOS/jnigenPackageAllIOS компилирует Arc/arc-core/csrc/iosgl/*.cpp
  #     в arc.xcframework и пакует его для composite-сборки — без этого
  #     линковщик не находит `-framework arc`.
  #  2) extractMetalANGLEKit скачивает и распаковывает готовый набор
  #     фреймворков MetalANGLEKit/libGLESv2/libEGL/libfeature_support
  #     (эмуляция OpenGL ES поверх Metal) в
  #     Arc/backends/backend-robovm/res/META-INF/robovm/ios/libs —
  #     без этого шага backend-robovm.jar не содержит этих фреймворков
  #     вообще, и линковщик падает с "framework 'MetalANGLEKit' not found".
  #     (Именно это и сломалось в предыдущем прогоне.)
  ./gradlew --no-daemon --stacktrace \
    :Arc:backends:backend-robovm:extractMetalANGLEKit \
    :Arc:arc-core:jnigenBuildAllIOS \
    :Arc:arc-core:jnigenPackageAllIOS

  echo "=== Диагностика: что получилось после jnigen/extract ==="
  find ../Arc -iname "*.xcframework" -o -iname "*arc-natives*" 2>/dev/null || true
  echo "--- Содержимое res/META-INF/robovm/ios/libs у backend-robovm ---"
  find ../Arc/backends/backend-robovm -path "*META-INF/robovm/ios*" 2>/dev/null || true

  echo "=== Собираю неподписанный .ipa (:ios:incrementConfig :ios:deploy) ==="
  ./gradlew --no-daemon --stacktrace \
    -Pbuildversion="${build_num}" \
    :ios:incrementConfig :ios:deploy

  echo "=== Ищу получившийся .ipa ==="
  local ipa_found
  ipa_found="$(find ios/build -iname "*.ipa" 2>/dev/null | head -n1)"
  if [ -z "$ipa_found" ]; then
    echo "!!! .ipa не найден после сборки — задача :ios:deploy завершилась, но файла нет."
    echo "!!! Содержимое ios/build для диагностики:"
    find ios/build -maxdepth 4 2>/dev/null || true
    exit 1
  fi
  echo "Найден .ipa: ${ipa_found}"

  mkdir -p "$DIST_DIR"
  cp "$ipa_found" "$DIST_DIR/_raw_output.ipa"
  echo "=== Сборка успешна ==="
}

# ---------------------------------------------------------------------------
# package: переименование в целевое имя, sha256, release notes
# ---------------------------------------------------------------------------
cmd_package() {
  set -e
  local ipa_name="${IPA_NAME:?переменная IPA_NAME не задана}"
  local raw="$DIST_DIR/_raw_output.ipa"

  if [ ! -f "$raw" ]; then
    echo "!!! Не найден собранный файл $raw"
    exit 1
  fi

  local final="$DIST_DIR/$ipa_name"
  mv "$raw" "$final"

  local sha size_bytes size_mb
  sha="$(shasum -a 256 "$final" | awk '{print $1}')"
  size_bytes="$(stat -f%z "$final")"
  size_mb="$((size_bytes / 1024 / 1024))"

  echo "$sha  $ipa_name" > "$final.sha256"

  {
    echo "sha256=${sha}"
    echo "size_bytes=${size_bytes}"
  } >> "$GITHUB_OUTPUT"

  cat > "$WORKSPACE_ROOT/release-notes.md" <<EOF
### Mindustry для iOS — неподписанная тестовая сборка

Собрано автоматически из [Anuken/Mindustry](${MINDUSTRY_REPO}), ветка \`master\`.

| Параметр | Значение |
|---|---|
| Файл | \`${ipa_name}\` |
| Размер | ~${size_mb} МБ |
| SHA256 | \`${sha}\` |
| Коммит Mindustry | [\`${VERSION_HEAD_SHA:-unknown}\`](https://github.com/Anuken/Mindustry/commit/${VERSION_HEAD_SHA:-}) |
| Отображаемая версия | \`${VERSION_DISPLAY:-unknown}\` |
| Дата сборки | $(date -u +"%Y-%m-%d %H:%M UTC") |
| Подпись | отсутствует (для LiveContainer / аналогичных инструментов) |

Это тестовый (prerelease) релиз — публикуется при каждом успешном ручном запуске
воркфлоу. При желании можно вручную превратить его в обычный релиз.
EOF

  echo "=== release-notes.md ==="
  cat "$WORKSPACE_ROOT/release-notes.md"
}

# ---------------------------------------------------------------------------
# summary: краткий отчёт в GitHub Actions Step Summary. Никогда не должен
# валить джоб — это просто удобство, а не часть логики успеха/провала.
# ---------------------------------------------------------------------------
cmd_summary() {
  {
    if [ "${JOB_STATUS:-}" = "success" ]; then
      echo "## ✅ Mindustry iOS — сборка успешна"
      echo
      echo "- Версия: \`${VERSION_DISPLAY:-?}\`"
      echo "- Файл: \`${IPA_NAME:-?}\`"
      if [ -f "$DIST_DIR/${IPA_NAME:-}.sha256" ]; then
        echo "- SHA256: \`$(awk '{print $1}' "$DIST_DIR/${IPA_NAME}.sha256")\`"
      fi
      echo
      echo "IPA опубликован как pre-release (testing) в Releases этого репозитория."
    else
      echo "## ❌ Mindustry iOS — сборка упала"
      echo
      echo "Ничего не опубликовано. Полный лог — в артефакте \`failure-diagnostics-*\`."
      echo
      echo "Последние строки лога:"
      echo '```'
      tail -n 150 "$LOG_FILE" 2>/dev/null || true
      echo '```'
    fi
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

case "${1:-}" in
  clone) cmd_clone ;;
  detect_version) cmd_detect_version ;;
  build) cmd_build ;;
  package) cmd_package ;;
  summary)
    set +e
    cmd_summary
    exit 0
    ;;
  *)
    echo "Неизвестная подкоманда: ${1:-<пусто>}" >&2
    echo "Доступно: clone | detect_version | build | package | summary" >&2
    exit 2
    ;;
esac
