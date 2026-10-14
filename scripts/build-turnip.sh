#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/source.env"

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

if [[ "$BUILD_ID" != "J0F-A825-009-MAX" ]]; then
  echo "Atualize config/source.env para J0F-A825-009-MAX antes de compilar."
  exit 1
fi

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

WORK="$(mktemp -d "$ROOT/.work-turnip-XXXXXX")"
SOURCE="$WORK/mesa"
BUILD="$WORK/build"
OUT="$ROOT/out/$BUILD_ID"

mkdir -p "$OUT" "$WORK/empty-pkgconfig"

save_logs() {
  if [[ -f "$BUILD/meson-logs/meson-log.txt" ]]; then
    cp "$BUILD/meson-logs/meson-log.txt" "$OUT/meson-log.txt"
  fi
}
trap save_logs EXIT

git init "$SOURCE"
git -C "$SOURCE" remote add origin "$MESA_REPOSITORY"
git -C "$SOURCE" fetch --depth=1 origin "$MESA_COMMIT"
git -C "$SOURCE" checkout --detach FETCH_HEAD

ACTUAL_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
test "$ACTUAL_COMMIT" = "$MESA_COMMIT"

# 009-MAX: base 005, memoria 008 e correcoes de referencias/concorrencia.
PATCH_FILE="$WORK/0001-a825-dxvk-profiled-autotune.patch"

cat > "$PATCH_FILE" <<'J0F_PATCH'
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -108,6 +108,7 @@
    BIG_GMEM = BIT(1),         /* All RPs with >= 10 draws use GMEM. */
    TUNE_SMALL = BIT(2),       /* Try tuning all RPs with <= 5 draws, ignored by default. */
    PREEMPT_OPTIMIZE = BIT(3),  /* Attempts to minimize the preemption latency. */
+   J0F_SKIP_LOCKED = BIT(4),   /* Internal A825/DXVK optimization. */
 };
 
 /* Metric flags, for internal tracking of enabled metrics. */
@@ -216,6 +217,7 @@
       MODF_STR(BIG_GMEM);
       MODF_STR(TUNE_SMALL);
       MODF_STR(PREEMPT_OPTIMIZE);
+      MODF_STR(J0F_SKIP_LOCKED);
       str += ")";
 
       str += ", Metric Flags: 0x" + std::to_string(metric_flags) + " (";
@@ -326,10 +328,26 @@
       at_config = config_t(algo, (uint8_t) mod_flags);
    });
 
+   config_t device_config = at_config;
+
+   /* J0F-A825-009-MAX: experimental measured render-mode selection for DXVK.
+    * Apply per device, outside the process-wide cached environment config.
+    * Keep explicit user overrides and other GPU/engine policies intact.
+    */
+   const char *engine_name = device->instance->vk.app_info.engine_name;
+   if ((uint32_t) device->physical_device->dev_id.chip_id == 0x44030000u &&
+       engine_name && std::string_view(engine_name) == "DXVK" &&
+       !os_get_option("TU_AUTOTUNE_ALGO") &&
+       !os_get_option("TU_AUTOTUNE_FLAGS") &&
+       device_config.is_enabled(algorithm::PREFER_SYSMEM)) {
+      device_config = config_t(algorithm::PROFILED, (uint8_t) mod_flag::J0F_SKIP_LOCKED);
+      mesa_logi("J0F-A825-009-MAX: A825 DXVK profiled + compact metrics + lifetime/RNG guards (experimental MAX)");
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
@@ -473,9 +491,10 @@
       other.history = nullptr;
    }
 
-   constexpr rp_history_handle &operator=(rp_history_handle &&other)
+   rp_history_handle &operator=(rp_history_handle &&other)
    {
       if (this != &other) {
+         release();
          history = other.history;
          other.history = nullptr;
       }
@@ -504,6 +523,7 @@
       return history;
    }
 
+   void release();
    ~rp_history_handle();
 };
 
@@ -551,7 +571,16 @@
    {
       this->sysmem = sysmem;
       this->tile_count = tile_count;
-      size_t total_size = sizeof(rp_gpu_data) + (tile_count * sizeof(tile_gpu_data));
+      /* J0F-A825-009-MAX: the automatic A825/DXVK profile only needs per-RP
+       * timestamps. Reserve tile storage only when it can be used. Keep
+       * tile_count intact for rendering and the existing bounds checks.
+       * TS_TILE always retains the full layout, including preemption data.
+       */
+      const bool omit_unused_tile_data =
+         config.test(mod_flag::J0F_SKIP_LOCKED) && config.is_enabled(algorithm::PROFILED) &&
+         !config.test(metric_flag::TS_TILE);
+      size_t total_size = sizeof(rp_gpu_data) +
+                          (omit_unused_tile_data ? 0 : tile_count * sizeof(tile_gpu_data));
 
       std::scoped_lock lock(device->autotune->suballoc_mutex);
       VkResult result = tu_suballoc_bo_alloc(&bo, &device->autotune->suballoc, total_size, alignof(rp_gpu_data));
@@ -562,6 +591,11 @@
 
       map = (uint8_t *) tu_suballoc_bo_map(&bo);
       memset(map, 0, total_size);
+   }
+
+   bool has_data() const
+   {
+      return map != nullptr;
    }
 
    rp_gpu_data &get_gpu_data()
@@ -976,6 +1010,8 @@
       /* Use fast if it's close to slow (normal variation).
        * Use slow if fast deviates too much (likely a spike).
        */
+      if (s == 0.0)
+         return static_cast<T>(f);
       double deviation = std::abs(f - s) / s;
       return (deviation < deviationThreshold) ? f : s + (f - s) * deviationThreshold;
    }
@@ -1091,15 +1127,14 @@
       std::atomic<uint32_t> sysmem_probability = PROBABILITY_MID;
       bool should_reset = false; /* If true, will reset sysmem_probability before next update. */
       bool locked = false;       /* If true, the probability will no longer be updated. */
-      uint64_t seed[2] { 0x3bffb83978e24f88, 0x9238d5d56c71cd35 };
+      std::atomic<uint64_t> selection_counter;
 
       bool is_sysmem_winning = false;
       uint64_t winning_since_ts = 0;
 
     public:
-      profiled_algo(uint64_t hash)
+      profiled_algo(uint64_t hash): selection_counter(hash)
       {
-         seed[1] = hash;
       }
 
       void update(rp_history &history, bool immediate)
@@ -1177,7 +1212,7 @@
                   sysmem_ema.count >= MIN_LOCK_DURATION_COUNT && gmem_ema.count >= MIN_LOCK_DURATION_COUNT;
                uint64_t min_avg = MIN2(avg_sysmem, avg_gmem);
                uint64_t max_avg = MAX2(avg_sysmem, avg_gmem);
-               uint64_t percent_diff = (100 * (max_avg - min_avg)) / min_avg;
+               uint64_t percent_diff = min_avg ? (100 * (max_avg - min_avg)) / min_avg : 0;
 
                if (has_resolved && enough_samples && max_avg >= MIN_LOCK_THRESHOLD &&
                    percent_diff >= LOCK_PERCENT_DIFF && (now - winning_since_ts) >= LOCK_TIME_WINDOW_NS) {
@@ -1199,10 +1234,37 @@
       }
 
     public:
+      /* Only PROFILED callers may use this: its learning probabilities stay
+       * in [1, 99]; endpoints are published only after a permanent lock.
+       * Read the atomic probability, not the queue-thread-only locked bool.
+       */
+      std::optional<render_mode> get_locked_mode() const
+      {
+         const uint32_t probability = sysmem_probability.load(std::memory_order_relaxed);
+         if (probability == 0)
+            return render_mode::GMEM;
+         if (probability == PROBABILITY_MAX)
+            return render_mode::SYSMEM;
+         return std::nullopt;
+      }
+
       render_mode get_optimal_mode(rp_history &history)
       {
          uint32_t l_sysmem_probability = sysmem_probability.load(std::memory_order_relaxed);
-         bool select_sysmem = (rand_xorshift128plus(seed) % PROBABILITY_MAX) < l_sysmem_probability;
+         if (l_sysmem_probability == 0)
+            return render_mode::GMEM;
+         if (l_sysmem_probability == PROBABILITY_MAX)
+            return render_mode::SYSMEM;
+
+         /* SplitMix64: one relaxed atomic ticket per decision, no shared
+          * non-atomic RNG state and no extra mutex in command recording.
+          */
+         constexpr uint64_t step = 0x9e3779b97f4a7c15ull;
+         uint64_t random = selection_counter.fetch_add(step, std::memory_order_relaxed) + step;
+         random = (random ^ (random >> 30)) * 0xbf58476d1ce4e5b9ull;
+         random = (random ^ (random >> 27)) * 0x94d049bb133111ebull;
+         random ^= random >> 31;
+         bool select_sysmem = (random % PROBABILITY_MAX) < l_sysmem_probability;
          render_mode mode = select_sysmem ? render_mode::SYSMEM : render_mode::GMEM;
 
          at_log_profiled_h("%" PRIu32 "%% sysmem chance, using %s", history.hash, l_sysmem_probability,
@@ -1333,6 +1395,8 @@
 
    void process(rp_entry &entry, tu_autotune &at)
    {
+      if (!entry.has_data())
+         return;
       /* We use entry config to know what metrics it has, autotune config to know what algorithms are enabled. */
       config_t entry_config = entry.config;
       config_t at_config = at.active_config.load();
@@ -1340,12 +1404,13 @@
       if (entry_config.test(metric_flag::SAMPLES) && at_config.is_enabled(algorithm::BANDWIDTH))
          bandwidth.update(entry.get_samples_passed());
       if (entry_config.test(metric_flag::TS)) {
+         uint64_t rp_duration = entry.get_rp_duration();
+         if (rp_duration == 0)
+            return;
          if (entry.sysmem) {
-            uint64_t rp_duration = entry.get_rp_duration();
-
             sysmem_rp_average.add(rp_duration);
          } else {
-            gmem_rp_average.add(entry.get_rp_duration());
+            gmem_rp_average.add(rp_duration);
 
             if (entry_config.test(metric_flag::TS_TILE) && at_config.test(mod_flag::PREEMPT_OPTIMIZE))
                preempt_optimize.update_gmem(*this, entry.get_max_tile_duration());
@@ -1358,7 +1423,8 @@
    }
 };
 
-tu_autotune::rp_history_handle::~rp_history_handle()
+void
+tu_autotune::rp_history_handle::release()
 {
    if (!history)
       return;
@@ -1366,6 +1432,12 @@
    history->last_use_ts.store(os_time_get_nano(), std::memory_order_relaxed);
    ASSERTED uint32_t old_refcount = history->refcount.fetch_sub(1, std::memory_order_relaxed);
    assert(old_refcount != 0); /* Underflow check. */
+   history = nullptr;
+}
+
+tu_autotune::rp_history_handle::~rp_history_handle()
+{
+   release();
 }
 
 tu_autotune::rp_history_handle::rp_history_handle(rp_history &history): history(&history)
@@ -1388,9 +1460,9 @@
 tu_autotune::rp_history_handle
 tu_autotune::find_or_create_rp_history(const rp_key &key)
 {
-   rp_history *existing = find_rp_history(key);
+   auto existing = find_rp_history(key);
    if (existing)
-      return *existing;
+      return existing;
 
    /* If we reach here, we have to create a new history. */
    std::unique_lock lock(rp_mutex);
@@ -1769,14 +1841,17 @@
     * unique hash for each instance to distinguish them. While this approach doesn't address identical renderpasses
     * across different command buffers, it is good enough in most cases.
     */
-   auto it = this->batch->all_renderpasses.find(key.hash);
-   if (it != this->batch->all_renderpasses.end()) {
-      key = rp_key(key, it->second);
-      if (record_instance)
+   auto &instances = this->batch->all_renderpasses;
+   if (record_instance) {
+      auto [it, inserted] = instances.try_emplace(key.hash, 1);
+      if (!inserted) {
+         key = rp_key(key, it->second);
          it->second++;
+      }
    } else {
-      if (record_instance)
-         this->batch->all_renderpasses[key.hash] = 1;
+      auto it = instances.find(key.hash);
+      if (it != instances.end())
+         key = rp_key(key, it->second);
    }
 
    return key;
@@ -1897,7 +1972,21 @@
    else
       key = cb_ctx.generate_rp_key(pass, framebuffer, cmd_buffer);
 
-   rp_history &history = *find_or_create_rp_history(key);
+   auto history_handle = find_or_create_rp_history(key);
+   rp_history &history = *history_handle;
+
+   /* J0F-A825-009-MAX: keep all earlier safety/mode overrides. Once PROFILED
+    * has permanently locked, fresh metrics cannot change its decision.
+    * Leave rp_ctx null: the existing emission hooks already handle that.
+    * Never skip latency tracking or explicit mode overrides.
+    */
+   if (config.test(mod_flag::J0F_SKIP_LOCKED) &&
+       config.is_enabled(algorithm::PROFILED) &&
+       !config.test(mod_flag::PREEMPT_OPTIMIZE) && !early_return_mode) {
+      if (auto mode = history.profiled.get_locked_mode())
+         return *mode;
+   }
+
    if (config.test(mod_flag::PREEMPT_OPTIMIZE)) {
       if (!latency_info && !key_opt)
          latency_info = get_rp_latency_info(key.hash, true);
@@ -1917,7 +2006,7 @@
          history.preempt_optimize.mark_as_latency_sensitive();
       }
    }
-   *rp_ctx = cb_ctx.attach_rp_entry(device, history, config, rp_state->drawcall_count);
+   *rp_ctx = cb_ctx.attach_rp_entry(device, std::move(history_handle), config, rp_state->drawcall_count);
 
    if (config.test(mod_flag::PREEMPT_OPTIMIZE) && history.preempt_optimize.is_latency_sensitive()) {
       /* Try to mitigate the risk of high preemption latency by always using GMEM, which should break up any larger
@@ -2035,7 +2124,7 @@
 void
 tu_autotune::begin_renderpass(struct tu_cmd_buffer *cmd, struct tu_cs *cs, rp_ctx_t rp_ctx)
 {
-   if (!rp_ctx)
+   if (!rp_ctx || !rp_ctx->has_data())
       return;
 
    rp_ctx->emit_rp_start(cmd, cs);
@@ -2044,7 +2133,7 @@
 void
 tu_autotune::begin_binning(struct tu_cs *cs, rp_ctx_t rp_ctx)
 {
-   if (!rp_ctx)
+   if (!rp_ctx || !rp_ctx->has_data())
       return;
 
    assert(!rp_ctx->sysmem);
@@ -2055,7 +2144,7 @@
 void
 tu_autotune::end_binning(struct tu_cs *cs, rp_ctx_t rp_ctx)
 {
-   if (!rp_ctx)
+   if (!rp_ctx || !rp_ctx->has_data())
       return;
 
    assert(!rp_ctx->sysmem);
@@ -2066,7 +2155,7 @@
 void
 tu_autotune::end_renderpass(struct tu_cmd_buffer *cmd, struct tu_cs *cs, rp_ctx_t rp_ctx)
 {
-   if (!rp_ctx)
+   if (!rp_ctx || !rp_ctx->has_data())
       return;
 
    rp_ctx->emit_rp_end(cmd, cs);
@@ -2077,7 +2166,7 @@
 void
 tu_autotune::begin_tile(struct tu_cmd_buffer *cmd, struct tu_cs *cs, rp_ctx_t rp_ctx, uint32_t tile_idx)
 {
-   if (!rp_ctx)
+   if (!rp_ctx || !rp_ctx->has_data())
       return;
 
    rp_ctx->emit_tile_start(cmd, cs, tile_idx);
@@ -2086,7 +2175,7 @@
 void
 tu_autotune::end_tile(struct tu_cmd_buffer *cmd, struct tu_cs *cs, rp_ctx_t rp_ctx, uint32_t tile_idx)
 {
-   if (!rp_ctx)
+   if (!rp_ctx || !rp_ctx->has_data())
       return;
 
    rp_ctx->emit_tile_end(cmd, cs, tile_idx);
J0F_PATCH

git -C "$SOURCE" apply --check "$PATCH_FILE"
git -C "$SOURCE" apply "$PATCH_FILE"
cp "$PATCH_FILE" "$OUT/0001-a825-dxvk-profiled-autotune.patch"

git -C "$SOURCE" diff --check
git -C "$SOURCE" diff > "$OUT/applied-source.diff"
sha256sum "$PATCH_FILE" > "$OUT/patch-sha256.txt"

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
c_args = ['-march=armv8.2-a', '-mtune=cortex-a720', '-mno-outline-atomics', '-fno-fast-math']
cpp_args = ['-march=armv8.2-a', '-mtune=cortex-a720', '-mno-outline-atomics', '-fno-fast-math']
c_link_args = ['-Wl,--icf=safe', '-Wl,-O2']
cpp_link_args = ['-static-libstdc++', '-Wl,--icf=safe', '-Wl,-O2']
EOF

cp "$ROOT/config/source.env" "$OUT/source.env"
cp "$WORK/android-cross.ini" "$OUT/android-cross.ini"
cp "$ANDROID_NDK_HOME/source.properties" "$OUT/ndk-source.properties"

{
  echo "BUILD_ID=$BUILD_ID"
  echo "MESA_COMMIT=$ACTUAL_COMMIT"
  echo "ANDROID_API=$API"
  echo "PERFORMANCE_PROFILE=009-MAX-armv8.2-a-cortex-a720"
  echo "LTO=disabled-by-Mesa-policy"
  echo "FAST_MATH=disabled"
  echo "MESA_VERSION=$(cat "$SOURCE/VERSION")"
  echo "MESON_VERSION=$(meson --version)"
  echo "NINJA_VERSION=$(ninja --version)"
  "$CC" --version
} > "$OUT/build-info.txt"

# Confere suporte do compilador e LSE direto antes da compilacao longa.
CPU_FLAGS=(-march=armv8.2-a -mtune=cortex-a720 -mno-outline-atomics -fno-fast-math)
cat > "$WORK/target-probe.cc" <<'J0F_PROBE'
#if !defined(__aarch64__) || !defined(__ARM_FEATURE_ATOMICS)
#error Esperava AArch64 com LSE
#endif
#if defined(__FAST_MATH__) || (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__)
#error O autotuner precisa preservar NaN
#endif
extern "C" unsigned long long j0f_atomic(unsigned long long *value) {
   return __atomic_fetch_add(value, 1ull, __ATOMIC_RELAXED);
}
extern "C" bool j0f_nan(double value) { return __builtin_isnan(value); }
J0F_PROBE
"$CXX" -std=c++17 -O3 "${CPU_FLAGS[@]}" -S "$WORK/target-probe.cc" -o "$OUT/target-probe.s"
python3 - "$OUT/target-probe.s" <<'J0F_PROBE_CHECK'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r"\bldadd\b", text), "LSE direto ausente"
assert "__aarch64_ldadd" not in text, "Atomico ainda usa helper outline"
assert re.search(r"\bfcmp\b", text), "Comparacao NaN removida"
J0F_PROBE_CHECK

# O3 + ARMv8.2/LSE + Cortex-A720. Mesa desta base rejeita LTO.
meson setup "$BUILD" "$SOURCE" \
  --cross-file "$WORK/android-cross.ini" \
  --buildtype=release \
  -Db_lto=false \
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
    options = {i["name"]: i["value"] for i in json.load(f)}

expected = {
    "buildtype": "release",
    "optimization": "3",
    "b_lto": False,
    "debug": False,
    "b_ndebug": "if-release",
    "platform-sdk-version": 35,
}

for key, value in expected.items():
    if options.get(key) != value:
        raise SystemExit(
            f"Unexpected {key}: {options.get(key)!r}; expected {value!r}"
        )
PY_CHECK

# Audita os argumentos efetivos do autotuner, nao apenas a receita solicitada.
cp "$BUILD/compile_commands.json" "$OUT/compile_commands.json"
python3 - "$OUT/compile_commands.json" <<'J0F_FLAGS_CHECK'
import json, shlex, sys
entries = json.load(open(sys.argv[1]))
found = []
required = {'-march=armv8.2-a', '-mtune=cortex-a720', '-mno-outline-atomics', '-fno-fast-math'}
for entry in entries:
    if not entry['file'].endswith('/tu_autotune.cc'):
        continue
    args = entry.get('arguments') or shlex.split(entry['command'])
    assert required.issubset(args), 'Flags da 009-MAX ausentes'
    opts = [x for x in args if x in ('-O0', '-O1', '-O2', '-O3', '-Os', '-Oz', '-Og', '-Ofast')]
    assert opts and opts[-1] == '-O3', opts
    assert not any(x.startswith('-flto') or x in ('-ffast-math', '-Ofast', '-ffinite-math-only') for x in args)
    found.append(entry['file'])
assert found, 'Compilacao do autotuner nao encontrada'
print('Flags 009-MAX verificadas:', len(found), 'unidade(s).')
J0F_FLAGS_CHECK

meson compile -C "$BUILD" -j 2

STAGE="$WORK/install"
meson install -C "$BUILD" --no-rebuild --destdir "$STAGE"

LIB="$(python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys

matches = list(Path(sys.argv[1]).rglob("libvulkan_freedreno.so"))
if len(matches) != 1:
    raise SystemExit(
        f"Esperava uma biblioteca instalada encontrei {len(matches)}"
        )
print(matches[0])
PY
)"

test -s "$LIB"

cp "$LIB" "$OUT/libvulkan_freedreno.so"
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded \
  "$OUT/libvulkan_freedreno.so"

  # A biblioteca instalada precisa preservar a ABI do carregador Vulkan.
"$TOOLCHAIN/bin/llvm-readelf" --wide --file-header --dynamic --dyn-syms \
  "$OUT/libvulkan_freedreno.so" > "$OUT/elf-validation.txt"
python3 - "$OUT/elf-validation.txt" <<'J0F_ELF_CHECK'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r'Machine:\s+AArch64', text), 'ELF nao e AArch64'
assert '(RPATH)' not in text and '(RUNPATH)' not in text, 'Caminho de build vazou no ELF'
for symbol in ('vk_icdGetInstanceProcAddr', 'vk_icdNegotiateLoaderICDInterfaceVersion'):
    assert re.search(r'\b' + symbol + r'\b', text), 'Export Vulkan ausente: ' + symbol
J0F_ELF_CHECK

(
  cd "$OUT"
  sha256sum libvulkan_freedreno.so > SHA256SUMS
)

echo "Biblioteca gerada em: $OUT"
