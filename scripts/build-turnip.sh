#!/usr/bin/env bash
set -Eeuo pipefail

# Localiza o projeto independentemente da pasta de execução.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/source.env"

# Estas ferramentas serão preparadas pelo GitHub Actions.
: "${ANDROID_NDK_HOME:?O workflow deve definir ANDROID_NDK_HOME}"
: "${BUILD_ID:?BUILD_ID ausente}"
: "${MESA_REPOSITORY:?MESA_REPOSITORY ausente}"
: "${MESA_COMMIT:?MESA_COMMIT ausente}"

if [[ ! "$MESA_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Erro: MESA_COMMIT deve conter o identificador completo."
  exit 1
fi

if [[ ! "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Erro: BUILD_ID contém caracteres inválidos."
  exit 1
fi

# Esta receita roda no Linux x86_64 do GitHub Actions.
API=34
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"

for command in git meson ninja pkg-config python3; do
  command -v "$command" >/dev/null
done

test -x "$CC"
test -x "$CXX"
test -x "$TOOLCHAIN/bin/llvm-strip"

# Cada execução usa uma pasta de trabalho nova.
WORK="$(mktemp -d "$ROOT/.work-turnip-XXXXXX")"
SOURCE="$WORK/mesa"
BUILD="$WORK/build"
OUT="$ROOT/out/$BUILD_ID"

mkdir -p "$OUT" "$WORK/empty-pkgconfig"

# Preserva o diagnóstico do Meson, inclusive se houver erro.
save_logs() {
  if [[ -f "$BUILD/meson-logs/meson-log.txt" ]]; then
    cp "$BUILD/meson-logs/meson-log.txt" "$OUT/meson-log.txt"
  fi
}
trap save_logs EXIT

# Baixa o commit fixado, sem seguir atualizações da branch.
git init "$SOURCE"
git -C "$SOURCE" remote add origin "$MESA_REPOSITORY"
git -C "$SOURCE" fetch --depth=1 origin "$MESA_COMMIT"
git -C "$SOURCE" checkout --detach FETCH_HEAD

ACTUAL_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
test "$ACTUAL_COMMIT" = "$MESA_COMMIT"

# Patch do experimento 004; guardado no artifact para auditoria.
PATCH_FILE="$WORK/0001-a825-dxvk-profiled-autotune.patch"
cat > "$PATCH_FILE" <<'J0F_PATCH'
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -326,10 +326,26 @@
       at_config = config_t(algo, (uint8_t) mod_flags);
    });
 
+   config_t device_config = at_config;
+
+   /* J0F-A825-004: experimental measured render-mode selection for DXVK.
+    * Apply per device, outside the process-wide cached environment config.
+    * Keep explicit user overrides and other GPU/engine policies intact.
+    */
+   const char *engine_name = device->instance->vk.app_info.engine_name;
+   if ((uint32_t) device->physical_device->dev_id.chip_id == 0x44030000u &&
+       engine_name && std::string_view(engine_name) == "DXVK" &&
+       !os_get_option("TU_AUTOTUNE_ALGO") &&
+       !os_get_option("TU_AUTOTUNE_FLAGS") &&
+       device_config.is_enabled(algorithm::PREFER_SYSMEM)) {
+      device_config = config_t(algorithm::PROFILED, 0);
+      mesa_logi("J0F-A825-004: A825 DXVK autotune=profiled (experimental)");
+   }
+
    if (TU_DEBUG(STARTUP))
-      mesa_logi("TU_AUTOTUNE: %s", at_config.to_string().c_str());
-
-   return at_config;
+      mesa_logi("TU_AUTOTUNE: %s", device_config.to_string().c_str());
+
+   return device_config;
 }
 
 uint32_t
J0F_PATCH

git -C "$SOURCE" apply --check "$PATCH_FILE"
git -C "$SOURCE" apply "$PATCH_FILE"
cp "$PATCH_FILE" "$OUT/0001-a825-dxvk-profiled-autotune.patch"
git -C "$SOURCE" diff --check
git -C "$SOURCE" diff > "$OUT/applied-source.diff"
sha256sum "$PATCH_FILE" > "$OUT/patch-sha256.txt"

# Descreve o destino: Android ARM64.
cat > "$WORK/android-cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$TOOLCHAIN/bin/llvm-ar'
strip = '$TOOLCHAIN/bin/llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$WORK/empty-pkgconfig'

[built-in options]
cpp_link_args = ['-static-libstdc++']
EOF

# Guarda a identificação das ferramentas e do código.
cp "$ROOT/config/source.env" "$OUT/source.env"
cp "$WORK/android-cross.ini" "$OUT/android-cross.ini"
cp "$ANDROID_NDK_HOME/source.properties" "$OUT/ndk-source.properties"

{
  echo "BUILD_ID=$BUILD_ID"
  echo "MESA_COMMIT=$ACTUAL_COMMIT"
  echo "ANDROID_API=$API"
  echo "MESA_VERSION=$(cat "$SOURCE/VERSION")"
  echo "MESON_VERSION=$(meson --version)"
  echo "NINJA_VERSION=$(ninja --version)"
  "$CC" --version
} > "$OUT/build-info.txt"

# Compila somente o driver Vulkan Freedreno/Turnip.
# KGSL é a interface com o driver de kernel Qualcomm no Android.
meson setup "$BUILD" "$SOURCE" \
  --cross-file "$WORK/android-cross.ini" \
  --buildtype=release \
  -Dplatforms=android \
  -Dplatform-sdk-version=35 \
  -Dandroid-stub=true \
  -Dgallium-drivers= \
  -Dvulkan-drivers=freedreno \
  -Dfreedreno-kmds=kgsl \
  -Degl=disabled \
  -Dgbm=disabled \
  -Dglx=disabled \
  -Dopengl=false \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dllvm=disabled \
  -Dandroid-libbacktrace=disabled \
  -Dandroid-libperfetto=disabled \
  -Dlibunwind=disabled \
  -Dexpat=disabled \
  -Dzstd=disabled \
  -Dshader-cache=enabled

meson configure "$BUILD" > "$OUT/meson-options.txt"
meson introspect --buildoptions "$BUILD" > "$OUT/meson-buildoptions.json"

python3 - "$OUT/meson-buildoptions.json" <<'PY_CHECK'
import json
import sys

with open(sys.argv[1]) as f:
    options = {i['name']: i['value'] for i in json.load(f)}

expected = {
    'buildtype': 'release',
    'optimization': '3',
    'debug': False,
    'b_ndebug': 'if-release',
    'platform-sdk-version': 35,
}

for key, value in expected.items():
    if options.get(key) != value:
        raise SystemExit(
            f"Unexpected {key}: {options.get(key)!r}; expected {value!r}"
        )
PY_CHECK

meson compile -C "$BUILD" -j 2

# Prepara os arquivos para distribuição em uma pasta isolada.
STAGE="$WORK/install"
meson install -C "$BUILD" --no-rebuild --destdir "$STAGE"

# Localiza a biblioteca preparada pela etapa de instalação.
LIB="$(python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys

matches = list(Path(sys.argv[1]).rglob("libvulkan_freedreno.so"))
if len(matches) != 1:
    raise SystemExit(
        f"Esperava uma biblioteca instalada; encontrei {len(matches)}"
    )
print(matches[0])
PY
)"

test -s "$LIB"

cp "$LIB" "$OUT/libvulkan_freedreno.so"
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded \
  "$OUT/libvulkan_freedreno.so"

(
  cd "$OUT"
  sha256sum libvulkan_freedreno.so > SHA256SUMS
)

echo "Biblioteca gerada em: $OUT"
