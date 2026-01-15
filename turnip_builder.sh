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

    # === INJEÇÃO DE CÓDIGO VIA PYTHON ===
    echo -e "${green}Injecting Smart Hybrid Wait Logic (via Python)...${nocolor}"
    
cat << 'EOF_PYTHON' > inject_smart_wait.py
import re
import sys

# O novo código híbrido (Busca Precisa + Spin Loop 5000x)
NEW_CODE = r'''
   /* SMART HYBRID WAIT INJECTED */
   while (state->highest_past < wait_value) {
        struct vk_sync_timeline_point *point = NULL;

        /* 1. Busca o ponto exato na lista (Lógica correta) */
        list_for_each_entry(struct vk_sync_timeline_point, p,
                            &state->pending_points, link) {
            if (p->value >= wait_value) {
                vk_sync_timeline_ref_point_locked(p);
                point = p;
                break;
            }
        }

        /* Se não achar ponto, fallback pro wait genérico (segurança) */
        if (!point) {
            int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex, &abs_timeout_ts);
            if (ret == thrd_timedout) return VK_TIMEOUT;
            if (ret != thrd_success) return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
            continue;
        }

        mtx_unlock(&state->mutex);
        
        /* 2. SPIN LOOP (Turbo): Tenta 5000x sem dormir no Kernel */
        VkResult r = VK_NOT_READY;
        for (int i = 0; i < 5000; i++) {
             r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, 0);
             if (r == VK_SUCCESS) break;
        }

        /* 3. KERNEL WAIT (Fallback): Se o spin falhar, dorme de verdade */
        if (r != VK_SUCCESS) {
             r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, abs_timeout_ns);
        }

        mtx_lock(&state->mutex);
        vk_sync_timeline_unref_point_locked(device, state, point);
        
        if (r != VK_SUCCESS) return r;
        vk_sync_timeline_complete_point_locked(device, state, point);
   }
'''

file_path = 'src/vulkan/runtime/vk_sync_timeline.c'

try:
    with open(file_path, 'r') as f:
        content = f.read()

    # Regex para encontrar o loop while original.
    pattern = re.compile(r'while\s*\(state->highest_pending\s*<\s*wait_value\)\s*\{.*?cnd_timedwait failed"\);\s*\}', re.DOTALL)

    if pattern.search(content):
        new_content = pattern.sub(NEW_CODE, content)
        with open(file_path, 'w') as f:
            f.write(new_content)
        print("SUCCESS: Code replaced successfully via Python.")
    else:
        print("ERROR: Could not find the target code block to replace.")
        sys.exit(1)
except Exception as e:
    print(f"PYTHON ERROR: {e}")
    sys.exit(1)
EOF_PYTHON

    # Executa o script Python
    if python3 inject_smart_wait.py; then
        echo -e "${green}Smart Hybrid Logic injected.${nocolor}"
    else
        echo -e "${red}Failed to inject logic. Check python script.${nocolor}"
        exit 1
    fi

    # Dependências do SPIRV
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="MesaMain-SmartHybrid-Fixed"
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

	export CFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"
	export CXXFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"

    # === FIX MESON SETUP ===
    cd "$source_dir"
    
    # Verifica se estamos no lugar certo
    if [ ! -f "meson.build" ]; then
        echo -e "${red}CRITICAL ERROR: meson.build not found in $(pwd)!${nocolor}"
        ls -la
        exit 1
    fi

    # Limpa build anterior para evitar confusão
    rm -rf "$build_dir"

    echo "Running Meson Setup..."
    # SINTAXE CORRIGIDA: meson setup <build_dir> <source_dir>
    # Explicitamos "." como source dir para evitar o erro "Neither source directory..."
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
	local meta_name="MesaMain-SmartHybrid-Fixed-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main + Smart Hybrid Wait (Python Injected + Meson Fix). Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="MesaMain-SmartHybrid-Fixed-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "MesaMain-SmartHybrid-Fixed-${date_tag}-${short_hash}" > tag
    echo "Mesa Main (Smart Hybrid) - ${date_tag}" > release
    echo "Corrected Meson setup command. Includes Smart Hybrid Wait logic." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
