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

# Versão base
BASE_VERSION="25.0.0-MX"

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
    
    # === APLICAÇÕES COMUNS (Timeline Fix + HUD Base) ===
    
    # 1. Timeline Semaphore Optimization (Fast Wait)
    echo -e "${green}Injecting Optimized Timeline Wait Logic (Common)...${nocolor}"
cat << 'EOF_PYTHON' > inject_timeline.py
import re
import sys

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

    while (state->highest_past < wait_value) {
        struct vk_sync_timeline_point *point = NULL;
        list_for_each_entry(struct vk_sync_timeline_point, p, &state->pending_points, link) {
            if (p->value >= wait_value) {
                vk_sync_timeline_ref_point_locked(p);
                point = p;
                break;
            }
        }
        if (!point) {
            int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex, &abs_timeout_ts);
            if (ret == thrd_timedout) return VK_TIMEOUT;
            if (ret != thrd_success) return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
            continue;
        }
        mtx_unlock(&state->mutex);
        VkResult r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, abs_timeout_ns);
        mtx_lock(&state->mutex);
        vk_sync_timeline_unref_point_locked(device, state, point);
        if (r != VK_SUCCESS) return r;
        vk_sync_timeline_complete_point_locked(device, state, point);
    }
    return VK_SUCCESS;
}
'''
file_path = 'src/vulkan/runtime/vk_sync_timeline.c'
try:
    with open(file_path, 'r') as f: content = f.read()
    pattern = re.compile(r'(static VkResult\s+vk_sync_timeline_wait_locked\s*\(.*?\).*?)(static VkResult\s+vk_sync_timeline_wait)', re.DOTALL)
    if pattern.search(content):
        new_content = pattern.sub(NEW_FUNCTION + r'\n\n\2', content)
        with open(file_path, 'w') as f: f.write(new_content)
        print("SUCCESS")
    else: sys.exit(1)
except Exception as e: sys.exit(1)
EOF_PYTHON
    python3 inject_timeline.py || exit 1

    # 2. HUD Injection Base (Estrutura)
    echo -e "${green}Injecting HUD Structure (Common)...${nocolor}"
cat << 'EOF_PYTHON' > inject_hud.py
import sys
import re
file_path = 'src/freedreno/vulkan/tu_device.cc'
try:
    with open(file_path, 'r') as f: content = f.read()
    
    # Injeta Includes
    includes = []
    if '#include "git_sha1.h"' not in content: includes.append('#include "git_sha1.h"')
    if '#include "tu_version.h"' not in content: includes.append('#include "tu_version.h"')
    if includes:
        content = re.sub(r'(#include ".*"\n)(?!#include)', r'\1' + '\n'.join(includes) + '\n', content, count=1)

    # Injeta Lógica de Nome
    new_logic = r'''
   /* Custom HUD Injection (MX) */
   char devname[128];
   strcpy(devname, pdevice->name);
   strcat(devname, " (" MESA_GIT_SHA1 "/" TUGEN8_DRV_VERSION ")");
   strcpy(props->deviceName, devname);
'''
    pattern = re.compile(r'\s*strcpy\(props->deviceName, pdevice->name\);')
    if pattern.search(content):
        new_content = pattern.sub(new_logic, content)
        with open(file_path, 'w') as f: f.write(new_content)
        print("SUCCESS")
    else:
        # Fallback
        fb_pattern = re.compile(r'(\s*)memcpy\(props->pipelineCacheUUID,')
        if fb_pattern.search(content):
             new_content = fb_pattern.sub(new_logic + r'\n\1memcpy(props->pipelineCacheUUID,', content)
             with open(file_path, 'w') as f: f.write(new_content)
             print("SUCCESS")
        else: sys.exit(1)
except Exception as e: sys.exit(1)
EOF_PYTHON
    python3 inject_hud.py || exit 1

    echo "Cloning SPIRV dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	cd "$workdir"
}

compile_variant(){
    local variant_name=$1
    local variant_suffix=$2
    local build_folder="build-$variant_name"
    
    echo -e "${green}=== Building Variant: $variant_name ===${nocolor}"
    
    cd "$workdir/mesa"
    
    # Atualiza a versão no HUD para esta variante
    local short_hash=$(git rev-parse --short HEAD)
    local full_version="v${BASE_VERSION}-${short_hash}-${variant_suffix}"
    echo "#define TUGEN8_DRV_VERSION \"$full_version\"" > src/freedreno/vulkan/tu_version.h
    
    # Prepara cross-file
	local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    
	local cross_file="$workdir/android-crossfile.txt"
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

    # Configuração Meson
    export CFLAGS="-D__ANDROID__ -Wno-error"
    export CXXFLAGS="-D__ANDROID__ -Wno-error"
    
    rm -rf "$build_folder"
    
	meson setup "$build_folder" --cross-file "$cross_file" \
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
		2>&1 | tee "$workdir/meson_${variant_name}.log"

	ninja -C "$build_folder" 2>&1 | tee "$workdir/ninja_${variant_name}.log"
    
    # Empacota
    local lib_path="$build_folder/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build $variant_name failed!${nocolor}"
		exit 1
	fi
    
    local package_temp="$workdir/package_temp_$variant_name"
    rm -rf "$package_temp"
    mkdir -p "$package_temp"
    cp "$lib_path" "$package_temp/libvulkan_freedreno.so"
    cd "$package_temp"
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so "vulkan.ad07XX.so"
    
    local zip_name="MesaMain-${BASE_VERSION}-${short_hash}-${variant_name}.zip"
    
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "MesaMain-${BASE_VERSION}-${variant_name}",
  "description": "Variant: $variant_name. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "Mesa Main",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
    echo -e "${green}Package Ready: $zip_name${nocolor}"
}

run_builds(){
    # 1. BUILD STANDARD (Sem patch A6xx)
    compile_variant "Standard" "Std"
    
    # 2. APLICA FIX A6xx
    echo -e "${green}Applying A6xx Stability Patch for second build...${nocolor}"
    cd "$workdir/mesa"
    
    if [ -f src/freedreno/vulkan/tu_query.cc ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
    fi
    if [ -f src/freedreno/vulkan/tu_device.cc ]; then
        sed -i 's/physical_device->has_cached_coherent_memory = .*/physical_device->has_cached_coherent_memory = false;/' src/freedreno/vulkan/tu_device.cc || true
    fi
    grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read file; do
        sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
        sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
    done
    
    # 3. BUILD A6XX FIXED
    compile_variant "A6xxFix" "A6xx"
}

generate_release_info() {
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    echo "Turnip-MX-DualBuild-${date_tag}" > tag
    echo "Turnip MX Dual (Standard + A6xx) - ${date_tag}" > release
    echo "Contains two drivers: Standard (High Perf) and A6xxFix (Stability)." > description
}

check_deps
prepare_ndk
prepare_source
run_builds
generate_release_info
