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
	
    echo "Cloning Official Mesa Main..."
	git clone --depth 100 "$base_repo" mesa
	cd mesa
    
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # === INJEÇÃO PYTHON: DEVS INSIGHT OPTIMIZATION ===
    # Substitui toda a lógica lenta de vk_sync_timeline_wait_locked
    # pela lógica unificada com Spin-Wait.
    echo -e "${green}Injecting LeeGao/Werman Optimized Wait Logic (Unified Spin)...${nocolor}"
    
cat << 'EOF_PYTHON' > inject_smart_wait.py
import re
import sys

# Esta lógica substitui os DOIS loops while originais por um único loop inteligente.
# Baseado na estrutura do vk_sync_timeline.c fornecido.

NEW_CODE = r'''
   /* LEEGAO/WERMAN UNIFIED SPIN WAIT */
   /* Loop único que trata tanto a espera por submissão quanto por execução */
   while (state->highest_past < wait_value) {
      struct vk_sync_timeline_point *point = NULL;

      /* 1. Busca o ponto exato na lista de pendentes */
      list_for_each_entry(struct vk_sync_timeline_point, p,
                          &state->pending_points, link) {
         if (p->value >= wait_value) {
            vk_sync_timeline_ref_point_locked(p);
            point = p;
            break;
         }
      }

      /* 2. Se o ponto não existe, ele ainda não foi submetido (CPU-side wait) */
      /* Aqui não podemos fazer spin, pois não há objeto para esperar. Dormimos. */
      if (!point) {
         int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex,
                                             &abs_timeout_ts);
         if (ret == thrd_timedout)
            return VK_TIMEOUT;

         if (ret != thrd_success)
            return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
         
         continue; /* Tenta buscar de novo */
      }

      /* 3. Ponto encontrado! Soltamos o Mutex global para não travar o driver */
      mtx_unlock(&state->mutex);

      VkResult result = VK_NOT_READY;

      /* 4. SPINNING AGRESSIVO (50.000 ciclos) */
      /* Otimizado para DXVK: A maioria dos frames termina em < 2ms. */
      /* Girar na CPU é mais barato que o context switch do Kernel. */
      for (int i = 0; i < 50000; i++) {
          result = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, 0);
          if (result == VK_SUCCESS) break;
          
          #if defined(__aarch64__)
          __asm__ volatile("yield");
          #endif
      }

      /* 5. FALLBACK: Se o spin falhar (GPU lenta/travada), dorme de verdade */
      if (result != VK_SUCCESS) {
          result = vk_sync_wait(device, &point->sync, 0,
                                VK_SYNC_WAIT_COMPLETE,
                                abs_timeout_ns);
      }

      /* Retoma o Mutex global */
      mtx_lock(&state->mutex);
      vk_sync_timeline_unref_point_locked(device, state, point);

      if (result != VK_SUCCESS)
         return result;

      vk_sync_timeline_complete_point_locked(device, state, point);
   }

   return VK_SUCCESS;
'''

file_path = 'src/vulkan/runtime/vk_sync_timeline.c'

try:
    with open(file_path, 'r') as f:
        content = f.read()

    # Regex para capturar TODO o corpo da função de wait, pegando desde o primeiro while
    # até o final do segundo while.
    # Baseado no arquivo enviado: começa em "while (state->highest_pending" e vai até o fim do segundo loop.
    
    # Padrão: Procure o primeiro while, pegue tudo até o "return VK_SUCCESS;" final da função
    pattern = re.compile(r'while\s*\(state->highest_pending\s*<\s*wait_value\)\s*\{.*return VK_SUCCESS;', re.DOTALL)

    if pattern.search(content):
        # Substitui tudo pelo nosso NEW_CODE
        new_content = pattern.sub(NEW_CODE, content)
        with open(file_path, 'w') as f:
            f.write(new_content)
        print("SUCCESS: Unified Spin Logic injected.")
    else:
        print("ERROR: Could not match the function body structure.")
        # Fallback debug
        print("Start of file content:", content[:200])
        sys.exit(1)

except Exception as e:
    print(f"PYTHON ERROR: {e}")
    sys.exit(1)
EOF_PYTHON

    if python3 inject_smart_wait.py; then
        echo -e "${green}Patch applied successfully.${nocolor}"
    else
        echo -e "${red}Patch failed.${nocolor}"
        exit 1
    fi

    # Dependências SPIRV
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="Turnip-TimelineFix-50kSpin"
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

	# O3 + LTO para maximizar a velocidade do loop de spin
	export CFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"
	export CXXFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"

    # === MESON FIX (Garante que acha o source) ===
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
	local meta_name="Turnip-TimelineFix-50kSpin-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Optimized: Unified Timeline Wait + 50k Spin Loop. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-TimelineFix-50kSpin-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-TimelineFix-50kSpin-${date_tag}-${short_hash}" > tag
    echo "Turnip (Unified Spin Fix) - ${date_tag}" > release
    echo "Optimized logic: Replaces generic Wait with Unified 50k Spin Wait." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
