#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Dependências
deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO ---
ndkver="android-ndk-r28"
target_sdk="36"

# 1. BASE: Mesa Oficial
base_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# 2. HACKS: Whitebelyash (Gen8 patches)
hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8"

# Commit que quebra o DXVK
bad_commit="2f0ea1c6"

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
	echo "Preparing Mesa source..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    # 1. Clona Mesa Oficial
    echo "Cloning Official Mesa..."
	git clone --depth 100 "$base_repo" mesa
	cd mesa
    
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 2. FETCH DA MR 39167 (Rob Clark - Elite Support)
    echo -e "${green}Fetching Rob Clark MR 39167 (Gen8 Support)...${nocolor}"
    git fetch "$base_repo" refs/merge-requests/39167/head:mr-39167
    git checkout mr-39167
    
    echo -e "${green}Base Commit (MR 39167):${nocolor}"
    git log -1 --format="%H - %cd - %s"

    # 3. MERGE DOS HACKS
    echo "Fetching Hacks from: $hacks_repo..."
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    
    echo "Attempting Merge Hacks..."
    if ! git merge --no-edit "hacks/$hacks_branch" --allow-unrelated-histories; then
        echo -e "${red}Merge Conflict detected! Resolving by accepting Hacks...${nocolor}"
        git checkout --theirs .
        git add .
        git commit -m "Auto-resolved conflicts by accepting Hacks over MR 39167"
        echo -e "${green}Conflicts resolved. Hacks applied successfully.${nocolor}"
    fi

    # --- CORREÇÕES DE SINTAXE E ERROS DE BUILD ---
    echo "Fixing freedreno_devices.py syntax..."
    perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py

    # CORREÇÃO DEFINITIVA: Remove TODAS as linhas com REG_A8XX_GRAS_UNKNOWN_
    # Isso evita erro no 8228, 8229, 822A, etc.
    echo "Removing ALL undefined registers (REG_A8XX_GRAS_UNKNOWN_*)..."
    sed -i '/REG_A8XX_GRAS_UNKNOWN_/d' src/freedreno/common/freedreno_devices.py


    # 4. APLICAÇÃO DO PATCH ASYNC (AGGRESSIVE POLLING)
    echo -e "${green}Injecting Aggressive Async (1us Polling)...${nocolor}"
    
cat << 'EOF_ASYNC' > new_wait_many.c
static VkResult
vk_sync_timeline_wait_many(struct vk_device *device,
                           uint32_t count,
                           const struct vk_sync_wait *waits,
                           enum vk_sync_wait_flags wait_flags,
                           uint64_t abs_timeout_ns)
{
    struct timespec abs_timeout_ts;
    timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);

    /* Otimização: Se for apenas 1 timeline, usamos a espera nativa */
    if (count == 1) {
       struct vk_sync_timeline *timeline = to_vk_sync_timeline(waits[0].sync);
       return vk_sync_timeline_wait(device, &timeline->sync, waits[0].wait_value, wait_flags, abs_timeout_ns);
    }

    uint32_t i;
    while (true) {
        bool any_ready = false;
        
        /* 1. Check ALL timelines */
        for (i = 0; i < count; i++) {
            struct vk_sync_timeline *timeline = to_vk_sync_timeline(waits[i].sync);
            uint64_t wait_value = waits[i].wait_value;
            struct vk_sync_timeline_state *state = timeline->state;

            mtx_lock(&state->mutex);
            if (state->highest_past >= wait_value) {
                any_ready = true;
                mtx_unlock(&state->mutex);
                if (wait_flags & VK_SYNC_WAIT_ANY)
                    return VK_SUCCESS;
                continue;
            }

            struct vk_sync_timeline_point *point = NULL;
            list_for_each_entry(struct vk_sync_timeline_point, p,
                                &state->pending_points, link) {
                if (p->value >= wait_value) {
                    vk_sync_timeline_ref_point_locked(p);
                    point = p;
                    break;
                }
            }

            if (!point) {
                mtx_unlock(&state->mutex);
                continue;
            }

            /* Tenta esperar neste ponto específico sem bloquear */
            mtx_unlock(&state->mutex);
            VkResult r = vk_sync_wait(device, &point->sync, 0,
                                      VK_SYNC_WAIT_COMPLETE,
                                      0); /* Timeout 0 = Check instantâneo */
            
            mtx_lock(&state->mutex);
            vk_sync_timeline_unref_point_locked(device, state, point);
            
            if (r == VK_SUCCESS) {
                 vk_sync_timeline_complete_point_locked(device, state, point);
                 any_ready = true;
                 mtx_unlock(&state->mutex);
                 if (wait_flags & VK_SYNC_WAIT_ANY) return VK_SUCCESS;
                 continue;
            }
            mtx_unlock(&state->mutex);
        }

        /* 2. Verificação Final do Loop */
        if (!(wait_flags & VK_SYNC_WAIT_ANY)) {
            bool all_ready = true;
            for (i = 0; i < count; i++) {
                struct vk_sync_timeline *timeline = to_vk_sync_timeline(waits[i].sync);
                if (timeline->state->highest_past < waits[i].wait_value) {
                    all_ready = false;
                    break;
                }
            }
            if (all_ready) return VK_SUCCESS;
        }

        /* 3. Check Timeout Global */
        struct timespec now;
        timespec_get(&now, TIME_UTC);
        if (timespec_to_nsec(&now) >= abs_timeout_ns) {
            return VK_TIMEOUT;
        }

        /* 4. AGGRESSIVE POLLING: 1000ns (1us) de sono. */
        struct timespec poll_sleep = {0, 1000}; 
        thrd_sleep(&poll_sleep, NULL);
    }
}
EOF_ASYNC

    perl -i -0777 -e '
        my $filename = "src/vulkan/runtime/vk_sync_timeline.c";
        open(my $fh, "<", $filename) or die "Cannot open $filename";
        my $content = do { local $/; <$fh> };
        close($fh);

        open(my $nfh, "<", "new_wait_many.c") or die "Cannot read new function";
        my $new_func = do { local $/; <$nfh> };
        close($nfh);

        $content =~ s/static VkResult\s+vk_sync_timeline_wait_many.*?^}//ms;

        if ($content =~ s/(struct vk_sync_timeline_type\s+vk_sync_timeline_get_type)/$new_func\n\n$1/) {
             print "Function injected correctly.\n";
             if ($content =~ s/(\.wait\s*=\s*vk_sync_timeline_wait,)/$1\n         .wait_many = vk_sync_timeline_wait_many, /) {
                 print "Struct hook connected.\n";
             }
        } else {
             print "ERROR: Injection point not found.\n";
             exit 1;
        }

        open($fh, ">", $filename) or die "Cannot write back";
        print $fh $content;
        close($fh);
    '

    if grep -q "vk_sync_timeline_wait_many" src/vulkan/runtime/vk_sync_timeline.c; then
        echo -e "${green}SUCCESS: Aggressive Async Patch Applied!${nocolor}"
    else
        echo -e "${red}ERROR: Failed to inject Async Patch.${nocolor}"
        exit 1
    fi

    # 5. DXVK FIX (GS/Tessellation)
    echo -e "${green}Applying DXVK Fixes...${nocolor}"
    
    if git revert --no-edit "$bad_commit" 2>/dev/null; then
        echo -e "${green}SUCCESS: Reverted commit $bad_commit via Git.${nocolor}"
    else
        echo -e "${red}Git revert failed. Applying MANUAL patch...${nocolor}"
        git revert --abort || true
        # Fallback manual para reativar GS/Tess
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
        echo "Applied manual patch via SED to enable GS/Tess."
    fi

    # --- SPIRV Manual ---
    echo "Cloning SPIRV dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="Turnip-Aggressive-CPU"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    # Fallback compilador
    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    echo "Using compiler binary: $compiler_ver (Targeting API $target_sdk)"

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
	
	# CPU FEATURES (OTIMIZAÇÃO DE EXTENSÕES)
	CPU_FLAGS="-mcpu=cortex-a76+crypto+crc+aes+sha2 -O3 -flto"

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
	local meta_name="Turnip-Aggressive-CPU-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Aggressive: CPU Features Enabled + Async Polling. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-Aggressive-CPU-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-Aggressive-CPU-${date_tag}-${short_hash}" > tag
    echo "Turnip Aggressive (CPU Features + Async) - ${date_tag}" > release
    echo "Performance Build: Cortex-A76+Crypto Flags + Aggressive Async Polling." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
