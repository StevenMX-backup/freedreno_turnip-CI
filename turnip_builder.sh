#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"
workdir="$(pwd)/turnip_workdir"

ndkver="android-ndk-r28"
target_sdk="36"
base_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_hash=""
version_str=""

check_deps(){
	echo "Checking system dependencies ..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then
			echo -e "$red Missing dependency binary: $dep$nocolor"
			missing=1
		else
			echo -e "$green Found: $dep$nocolor"
		fi
	done
	if [ "$missing" == "1" ]; then
		echo "Please install missing dependencies." && exit 1
	fi
    
	echo "Updating Meson via pip..."
	pip install meson mako --break-system-packages &> /dev/null || pip install meson mako &> /dev/null || true
}

prepare_ndk(){
	echo "Preparing NDK r28..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		echo "Downloading Android NDK $ndkver..."
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		echo "Extracting NDK..."
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

prepare_source(){
	echo "Preparing Mesa source (Main)..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    # Configurações do Git para evitar erro HTTP 503 / RPC Failed
    git config --global http.postBuffer 1048576000
    git config --global http.lowSpeedLimit 0
    git config --global http.lowSpeedTime 999999

    echo "Cloning Official Mesa Main (Robust Mode)..."
    
    # Tentativa de clone com retry e otimização de tamanho (Blobless clone)
    # --filter=blob:none reduz drasticamente o tamanho do download
    count=0
    until [ "$count" -ge 5 ]; do
        if git clone --depth 1 --filter=blob:none "$base_repo" mesa; then
            break
        fi
        echo -e "${red}Clone failed (HTTP 503). Retrying in 5 seconds... ($((count+1))/5)${nocolor}"
        count=$((count+1))
        rm -rf mesa
        sleep 5
    done

    if [ ! -d "mesa" ]; then
        echo -e "${red}CRITICAL: Failed to clone Mesa after 5 attempts.${nocolor}"
        exit 1
    fi

	cd mesa
    
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # === INJEÇÃO PYTHON SEGURA (FIXED REGEX + 50k SPIN) ===
    echo -e "${green}Injecting Smart Spin Logic (Safe Replacement)...${nocolor}"
    
cat << 'EOF_PYTHON' > inject_smart_wait.py
import re
import sys

# Função substituta completa.
# Inclui:
# 1. Busca eficiente (Fast Path)
# 2. Spin Loop de 50k iterações com yield (Performance Path)
# 3. Fallback seguro

NEW_FUNCTION = r'''
static VkResult
vk_sync_timeline_wait_locked(struct vk_device *device,
                             struct vk_sync_timeline_state *state,
                             uint64_t wait_value,
                             enum vk_sync_wait_flags wait_flags,
                             uint64_t abs_timeout_ns)
{
   struct timespec abs_timeout_ts;
   timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);

   /* 1. FAST PATH: Busca direta do ponto na lista */
   while (state->highest_past < wait_value) {
      struct vk_sync_timeline_point *point = NULL;

      list_for_each_entry(struct vk_sync_timeline_point, p,
                          &state->pending_points, link) {
         if (p->value >= wait_value) {
            vk_sync_timeline_ref_point_locked(p);
            point = p;
            break;
         }
      }

      /* Se point == NULL, o sinal ainda não foi submetido. Wait passivo. */
      if (!point) {
         int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex,
                                             &abs_timeout_ts);
         if (ret == thrd_timedout)
            return VK_TIMEOUT;

         if (ret != thrd_success)
            return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
         
         continue;
      }

      /* 2. SPIN WAIT: Solta o mutex e gira na CPU (0.5ms) */
      mtx_unlock(&state->mutex);

      VkResult result = VK_NOT_READY;

      /* 50.000 iterações com yield para não travar o OS */
      for (int i = 0; i < 50000; i++) {
          result = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, 0);
          if (result == VK_SUCCESS) break;
          
          #if defined(__aarch64__)
          __asm__ volatile("yield");
          #endif
      }

      /* 3. FALLBACK: Se demorar demais, dorme */
      if (result != VK_SUCCESS) {
          result = vk_sync_wait(device, &point->sync, 0,
                                VK_SYNC_WAIT_COMPLETE,
                                abs_timeout_ns);
      }

      /* Retoma o lock */
      mtx_lock(&state->mutex);
      vk_sync_timeline_unref_point_locked(device, state, point);

      if (result != VK_SUCCESS)
         return result;

      vk_sync_timeline_complete_point_locked(device, state, point);
   }

   if (wait_flags & VK_SYNC_WAIT_PENDING)
      return VK_SUCCESS;

   return vk_sync_timeline_gc_locked(device, state, false);
}
'''

file_path = 'src/vulkan/runtime/vk_sync_timeline.c'

try:
    with open(file_path, 'r') as f:
        content = f.read()

    # Regex preciso:
    # Captura a função vk_sync_timeline_wait_locked até o início da próxima função.
    # Isso evita deletar código vizinho.
    
    pattern = re.compile(
        r'(static VkResult\s+vk_sync_timeline_wait_locked\s*\(.*?\).*?)(static VkResult\s+vk_sync_timeline_wait)', 
        re.DOTALL
    )

    if pattern.search(content):
        # Substitui o grupo 1 (função antiga) pelo NEW_FUNCTION, mantendo o grupo 2
        new_content = pattern.sub(NEW_FUNCTION + r'\n\n\2', content)
        with open(file_path, 'w') as f:
            f.write(new_content)
        print("SUCCESS: Function replaced safely via Python.")
    else:
        print("ERROR: Could not find function boundaries.")
        # Debug:
        print(content[:300])
        sys.exit(1)

except Exception as e:
    print(f"PYTHON ERROR: {e}")
    sys.exit(1)
EOF_PYTHON

    if python3 inject_smart_wait.py; then
        echo -e "${green}Patch applied.${nocolor}"
    else
        echo -e "${red}Patch failed.${nocolor}"
        exit 1
    fi

    # Dependências SPIRV (Com retry também)
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    
    echo "Cloning SPIRV Tools..."
    count=0
    until [ "$count" -ge 5 ]; do
        if git clone --depth 1 --filter=blob:none https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools; then break; fi
        echo "Retrying SPIRV-Tools..."
        rm -rf spirv-tools
        count=$((count+1))
        sleep 3
    done

    echo "Cloning SPIRV Headers..."
    count=0
    until [ "$count" -ge 5 ]; do
        if git clone --depth 1 --filter=blob:none https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers; then break; fi
        echo "Retrying SPIRV-Headers..."
        rm -rf spirv-headers
        count=$((count+1))
        sleep 3
    done
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="Turnip-SmartSpin-50k-GitFixed"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa Main for SDK $target_sdk...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    echo "Using compiler: Clang $compiler_ver"

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	# O3 + LTO
	export CFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"
	export CXXFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"

    cd "$source_dir"
    rm -rf "$build_dir"
    
	meson setup "$build_dir" . --cross-file "$cross_file" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$target_sdk \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglx=disabled \
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers \
		2>&1 | tee "$workdir/meson_log"

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"

	if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi

	rm -rf "$package_temp"
	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad07XX.so"

	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-SmartSpin-50k-GitFixed-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Fixed: 50k Spin Wait + Robust Clone. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-SmartSpin-50k-GitFixed-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-SmartSpin-50k-GitFixed-${date_tag}-${short_hash}" > tag
    echo "Turnip (SmartSpin 50k + Git Fix) - ${date_tag}" > release
    echo "Includes 50k Spin logic and fixes for HTTP 503 clone errors." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
