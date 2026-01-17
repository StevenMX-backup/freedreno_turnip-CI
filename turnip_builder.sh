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

# Ajustei o nome da versão
BUILD_VERSION="25.0.0-MX-HighPerf"

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
    
    local short_hash=$(git rev-parse --short HEAD)
    FULL_VERSION="${BUILD_VERSION}-${short_hash}"

    # === CUSTOM VERSIONING (MX HUD) ===
    echo -e "${green}Applying Custom Versioning ($FULL_VERSION)...${nocolor}"
    
    echo "#define TUGEN8_DRV_VERSION \"$FULL_VERSION\"" > src/freedreno/vulkan/tu_version.h

cat << 'EOF_PYTHON' > inject_version.py
import sys

file_path = 'src/freedreno/vulkan/tu_device.cc'
try:
    with open(file_path, 'r') as f:
        lines = f.readlines()
    
    new_lines = []
    include_added = False
    
    for line in lines:
        new_lines.append(line)
        if not include_added and '#include "tu_device.h"' in line:
            new_lines.append('#include "tu_version.h"\n')
            include_added = True

    with open(file_path, 'w') as f:
        f.writelines(new_lines)
        
except Exception as e:
    print(f"Error injecting include: {e}")
    sys.exit(1)
EOF_PYTHON
    python3 inject_version.py

    sed -i 's/snprintf(properties->driverInfo, sizeof(properties->driverInfo),.*/snprintf(properties->driverInfo, sizeof(properties->driverInfo), "Turnip Mesa %s (MX)", TUGEN8_DRV_VERSION);/' src/freedreno/vulkan/tu_device.cc || true

    echo "Cloning SPIRV dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="MesaMain-MX-HighPerf"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

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

	cd "$source_dir"
	
    # === FLAGS DE COMPATIBILIDADE E PERFORMANCE ===
    # Removi -mcpu=cortex-x4 (que causa crash em Adreno 6xx/7xx antigos)
    # Usei -march=armv8.2-a+crypto: Compatível com Snapdragon 845 em diante e muito rápido.
    # -O3 e -flto garantem a velocidade máxima.
    
    CPU_FLAGS="-march=armv8.2-a+crypto -O3 -flto -DNDEBUG"
    
	export CFLAGS="-D__ANDROID__ -Wno-error $CPU_FLAGS"
	export CXXFLAGS="-D__ANDROID__ -Wno-error $CPU_FLAGS"

	meson setup "$build_dir" --cross-file "$cross_file" \
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
	local meta_name="MesaMain-MX-HighPerf-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main + MX HUD + High Perf (Compatible). Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="MesaMain-MX-HighPerf-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "MesaMain-MX-HighPerf-${date_tag}-${short_hash}" > tag
    echo "Mesa Main (MX HighPerf) - ${date_tag}" > release
    echo "High Performance Build (O3/LTO) compatible with most Snapdragons." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
