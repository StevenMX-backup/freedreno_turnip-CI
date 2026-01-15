#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator patch"
workdir="$(pwd)/turnip_workdir"

ndkver="android-ndk-r28"
target_sdk="36"
# Mesa Main Limpa
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

    # === SMART HYBRID TIMELINE WAIT ===
    # Lógica: 
    # 1. Encontra o ponto exato na lista (Tua lógica)
    # 2. Faz Spin-Loop (5000x) para evitar latência do Kernel
    # 3. Fallback para Kernel Wait se necessário
    echo -e "${green}Applying Smart Hybrid Timeline Patch...${nocolor}"
    
cat << 'EOF_PATCH' > timeline_smart.patch
--- a/src/vulkan/runtime/vk_sync_timeline.c
+++ b/src/vulkan/runtime/vk_sync_timeline.c
@@ -436,13 +436,44 @@ static VkResult
 vk_sync_timeline_wait_locked(struct vk_device *device,
                              struct vk_sync_timeline_state *state,
                              uint64_t wait_value,
                              enum vk_sync_wait_flags wait_flags,
                              uint64_t abs_timeout_ns)
 {
    struct timespec abs_timeout_ts;
    timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);
 
-   /* Wait on the queue_submit condition variable until the timeline has a
-    * time point pending that's at least as high as wait_value.
-    */
-   while (state->highest_pending < wait_value) {
-      int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex,
-                                          &abs_timeout_ts);
-      if (ret == thrd_timedout)
-         return VK_TIMEOUT;
-
-      if (ret != thrd_success)
-         return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
-   }
+   /* SMART HYBRID WAIT */
+   while (state->highest_past < wait_value) {
+        struct vk_sync_timeline_point *point = NULL;
+
+        /* 1. Busca o ponto exato na lista (Correct Logic) */
+        list_for_each_entry(struct vk_sync_timeline_point, p,
+                            &state->pending_points, link) {
+            if (p->value >= wait_value) {
+                vk_sync_timeline_ref_point_locked(p);
+                point = p;
+                break;
+            }
+        }
+
+        /* Se não achar ponto, fallback pro wait genérico */
+        if (!point) {
+            int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex, &abs_timeout_ts);
+            if (ret == thrd_timedout) return VK_TIMEOUT;
+            if (ret != thrd_success) return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
+            continue;
+        }
+
+        mtx_unlock(&state->mutex);
+        
+        /* 2. SPIN LOOP (Turbo): Tenta 5000x sem dormir */
+        VkResult r = VK_NOT_READY;
+        for (int i = 0; i < 5000; i++) {
+             r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, 0);
+             if (r == VK_SUCCESS) break;
+             /* asm("yield"); // Opcional */
+        }
+
+        /* 3. KERNEL WAIT (Fallback): Se o spin falhar, dorme */
+        if (r != VK_SUCCESS) {
+             r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, abs_timeout_ns);
+        }
+
+        mtx_lock(&state->mutex);
+        vk_sync_timeline_unref_point_locked(device, state, point);
+        
+        if (r != VK_SUCCESS) return r;
+        vk_sync_timeline_complete_point_locked(device, state, point);
+   }
 
    if (wait_flags & VK_SYNC_WAIT_PENDING)
       return VK_SUCCESS;
 
    VkResult result = vk_sync_timeline_gc_locked(device, state, false);
EOF_PATCH

    if patch -p1 < timeline_smart.patch; then
        echo -e "${green}SUCCESS: Smart Hybrid Patch applied!${nocolor}"
    else
        echo -e "${red}ERROR: Failed to apply Smart Hybrid Patch.${nocolor}"
        patch -p1 --ignore-whitespace < timeline_smart.patch || exit 1
    fi

    echo "Cloning SPIRV dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="MesaMain-SmartHybrid-NoHacks"
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

	cd "$source_dir"
	
	# Mantendo O3 para garantir que o Spin-Loop seja rápido
	export CFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"
	export CXXFLAGS="-D__ANDROID__ -Wno-error -O3 -flto"

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
	local meta_name="MesaMain-SmartHybrid-NoHacks-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main + Smart Hybrid Wait (No A6xx Fix/Hacks). Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="MesaMain-SmartHybrid-NoHacks-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "MesaMain-SmartHybrid-NoHacks-${date_tag}-${short_hash}" > tag
    echo "Mesa Main (Smart Hybrid Only) - ${date_tag}" > release
    echo "Pure Main Build + Smart Hybrid Wait. No stability hacks." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
