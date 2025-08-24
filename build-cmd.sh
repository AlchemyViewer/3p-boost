#!/usr/bin/env bash

cd "$(dirname "$0")"

set -eux

top="$(pwd)"
stage="$top"/stage

BOOST_SOURCE_DIR="boost"
VERSION_HEADER_FILE="$stage/include/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

# load autobuild provided shell functions and variables
case "$AUTOBUILD_PLATFORM" in
    windows*)
        autobuild="$(cygpath -u "$AUTOBUILD")"
    ;;
    *)
        autobuild="$AUTOBUILD"
    ;;
esac

source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd apply_patch
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

apply_patch "patches/libs/config/0001-Define-BOOST_ALL_NO_LIB.patch" "$BOOST_SOURCE_DIR/libs/config"
apply_patch "patches/libs/context/0001-Fix-MASM-ARM64.patch" "$BOOST_SOURCE_DIR/libs/context"

if [ ! -d "boost/libs/accumulators/include" ]; then
    echo "Submodules not present. Initializing..."
    git submodule update --init --recursive
fi

stage_lib="${stage}"/lib
stage_debug="${stage_lib}"/debug
stage_release="${stage_lib}"/release
mkdir -p "${stage_debug}"
mkdir -p "${stage_release}"

pushd "stage"

case "$AUTOBUILD_PLATFORM" in

    windows*)
        for arch in sse avx2 arm64 ; do
            # Setup boost context arch flags
            if [[ "$arch" == "sse" || "$arch" == "avx2" ]]; then
                platform_target="x64"
                BOOST_CONTEXT_ARCH="x86_64"
                BOOST_CONTEXT_ABI="ms"
            elif [[ "$arch" == "arm64" ]]; then
                platform_target="ARM64"
                BOOST_CONTEXT_ARCH="arm64"
                BOOST_CONTEXT_ABI="aapcs"
            fi

            mkdir -p "build_debug_$arch"
            pushd "build_debug_$arch"
                opts="$(replace_switch /Zi /Z7 $LL_BUILD_DEBUG)"
                if [[ "$arch" == "avx2" ]]; then
                    opts="$(replace_switch /arch:SSE4.2 /arch:AVX2 $opts)"
                elif [[ "$arch" == "arm64" ]]; then
                    opts="$(remove_switch /arch:SSE4.2 $opts)"
                fi
                plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$platform_target" $(cygpath -m "$top/$BOOST_SOURCE_DIR") -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
                        -DCMAKE_CONFIGURATION_TYPES="Debug" \
                        -DCMAKE_C_FLAGS_DEBUG="$plainopts" \
                        -DCMAKE_CXX_FLAGS_DEBUG="$opts /EHsc" \
                        -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                        -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                        -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/$arch/debug")" \
                        -DCMAKE_INSTALL_INCLUDEDIR="$(cygpath -m "$stage/include")" \
                        -DBOOST_INSTALL_LAYOUT="system" \
                        -DBOOST_ENABLE_MPI=OFF \
                        -DBOOST_ENABLE_PYTHON=OFF \
                        -DBOOST_CONTEXT_ARCHITECTURE=$BOOST_CONTEXT_ARCH \
                        -DBOOST_CONTEXT_ABI="$BOOST_CONTEXT_ABI" \
                        -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                        -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                        -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                        -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                        -DBOOST_LOCALE_ENABLE_ICU=OFF

                cmake --build . --config Debug --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Debug

                # conditionally run unit tests
                # if [[ "${DISABLE_UNIT_TESTS:-0}" == "0" && "$arch" != "arm64" ]]; then
                #     ctest -C Debug --parallel $AUTOBUILD_CPU_COUNT
                # fi
            popd

            mkdir -p "build_release_$arch"
            pushd "build_release_$arch"
                opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
                if [[ "$arch" == "avx2" ]]; then
                    opts="$(replace_switch /arch:SSE4.2 /arch:AVX2 $opts)"
                elif [[ "$arch" == "arm64" ]]; then
                    opts="$(remove_switch /arch:SSE4.2 $opts)"
                fi
                plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$platform_target" $(cygpath -m "$top/$BOOST_SOURCE_DIR") -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
                        -DCMAKE_CONFIGURATION_TYPES="Release" \
                        -DCMAKE_C_FLAGS="$plainopts" \
                        -DCMAKE_CXX_FLAGS="$opts /EHsc" \
                        -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                        -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                        -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/$arch/release")" \
                        -DCMAKE_INSTALL_INCLUDEDIR="$(cygpath -m "$stage/include")" \
                        -DBOOST_INSTALL_LAYOUT="system" \
                        -DBOOST_ENABLE_MPI=OFF \
                        -DBOOST_ENABLE_PYTHON=OFF \
                        -DBOOST_CONTEXT_ARCHITECTURE=$BOOST_CONTEXT_ARCH \
                        -DBOOST_CONTEXT_ABI="$BOOST_CONTEXT_ABI" \
                        -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                        -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                        -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                        -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                        -DBOOST_LOCALE_ENABLE_ICU=OFF

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                # conditionally run unit tests
                # if [[ "${DISABLE_UNIT_TESTS:-0}" == "0" && "$arch" != "arm64" ]]; then
                #     ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                # fi
            popd
        done

        # bjam doesn't need vsvars, but our hand compilation does
        load_vsvars

        # populate version_file
        cl -DVERSION_HEADER_FILE="\"$(cygpath -w $VERSION_HEADER_FILE)\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -Fo"$(cygpath -w "$stage/version.obj")" \
           -Fe"$(cygpath -w "$stage/version.exe")" \
           "$(cygpath -w "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version.exe" | tr '_' '.' > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    darwin*)
        # deploy target
        export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_DEPLOY_TARGET}

        for arch in x86_64 arm64 ; do
            ARCH_ARGS="-arch $arch"
            cxx_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
            cc_opts="$(remove_cxxstd $cxx_opts)"
            ld_opts="$ARCH_ARGS"

            # Setup boost context arch flags
            if [[ "$arch" == "x86_64" ]]; then
                BOOST_CONTEXT_ARCH="x86_64"
                BOOST_CONTEXT_ABI="sysv"
            elif [[ "$arch" == "arm64" ]]; then
                BOOST_CONTEXT_ARCH="arm64"
                BOOST_CONTEXT_ABI="aapcs"
            fi

            mkdir -p "build_$arch"
            pushd "build_$arch"
                CFLAGS="$cc_opts" \
                CXXFLAGS="$cxx_opts" \
                LDFLAGS="$ld_opts" \
                cmake $top/$BOOST_SOURCE_DIR -G "Xcode" -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=OFF \
                    -DCMAKE_CONFIGURATION_TYPES="Release" \
                    -DCMAKE_C_FLAGS="$cc_opts" \
                    -DCMAKE_CXX_FLAGS="$cxx_opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$stage/include" \
                    -DCMAKE_OSX_ARCHITECTURES="$arch" \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DBOOST_INSTALL_LAYOUT="system" \
                    -DBOOST_ENABLE_MPI=OFF \
                    -DBOOST_ENABLE_PYTHON=OFF \
                    -DBOOST_CONTEXT_ARCHITECTURE=$BOOST_CONTEXT_ARCH \
                    -DBOOST_CONTEXT_ABI="$BOOST_CONTEXT_ABI" \
                    -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                    -DBOOST_LOCALE_ENABLE_ICU=OFF

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                # conditionally run unit tests
                # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #     ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                # fi
            popd
        done

        # create release universal libs
        lipo -create -output ${stage_release}/libboost_atomic.a ${stage_release}/x86_64/libboost_atomic.a ${stage_release}/arm64/libboost_atomic.a
        lipo -create -output ${stage_release}/libboost_charconv.a ${stage_release}/x86_64/libboost_charconv.a ${stage_release}/arm64/libboost_charconv.a
        lipo -create -output ${stage_release}/libboost_chrono.a ${stage_release}/x86_64/libboost_chrono.a ${stage_release}/arm64/libboost_chrono.a
        lipo -create -output ${stage_release}/libboost_cobalt.a ${stage_release}/x86_64/libboost_cobalt.a ${stage_release}/arm64/libboost_cobalt.a
        lipo -create -output ${stage_release}/libboost_container.a ${stage_release}/x86_64/libboost_container.a ${stage_release}/arm64/libboost_container.a
        lipo -create -output ${stage_release}/libboost_context.a ${stage_release}/x86_64/libboost_context.a ${stage_release}/arm64/libboost_context.a
        lipo -create -output ${stage_release}/libboost_contract.a ${stage_release}/x86_64/libboost_contract.a ${stage_release}/arm64/libboost_contract.a
        lipo -create -output ${stage_release}/libboost_coroutine.a ${stage_release}/x86_64/libboost_coroutine.a ${stage_release}/arm64/libboost_coroutine.a
        lipo -create -output ${stage_release}/libboost_date_time.a ${stage_release}/x86_64/libboost_date_time.a ${stage_release}/arm64/libboost_date_time.a
        lipo -create -output ${stage_release}/libboost_fiber_numa.a ${stage_release}/x86_64/libboost_fiber_numa.a ${stage_release}/arm64/libboost_fiber_numa.a
        lipo -create -output ${stage_release}/libboost_fiber.a ${stage_release}/x86_64/libboost_fiber.a ${stage_release}/arm64/libboost_fiber.a
        lipo -create -output ${stage_release}/libboost_filesystem.a ${stage_release}/x86_64/libboost_filesystem.a ${stage_release}/arm64/libboost_filesystem.a
        lipo -create -output ${stage_release}/libboost_graph.a ${stage_release}/x86_64/libboost_graph.a ${stage_release}/arm64/libboost_graph.a
        lipo -create -output ${stage_release}/libboost_iostreams.a ${stage_release}/x86_64/libboost_iostreams.a ${stage_release}/arm64/libboost_iostreams.a
        lipo -create -output ${stage_release}/libboost_json.a ${stage_release}/x86_64/libboost_json.a ${stage_release}/arm64/libboost_json.a
        lipo -create -output ${stage_release}/libboost_locale.a ${stage_release}/x86_64/libboost_locale.a ${stage_release}/arm64/libboost_locale.a
        lipo -create -output ${stage_release}/libboost_log_setup.a ${stage_release}/x86_64/libboost_log_setup.a ${stage_release}/arm64/libboost_log_setup.a
        lipo -create -output ${stage_release}/libboost_log.a ${stage_release}/x86_64/libboost_log.a ${stage_release}/arm64/libboost_log.a
        lipo -create -output ${stage_release}/libboost_nowide.a ${stage_release}/x86_64/libboost_nowide.a ${stage_release}/arm64/libboost_nowide.a
        lipo -create -output ${stage_release}/libboost_prg_exec_monitor.a ${stage_release}/x86_64/libboost_prg_exec_monitor.a ${stage_release}/arm64/libboost_prg_exec_monitor.a
        lipo -create -output ${stage_release}/libboost_process.a ${stage_release}/x86_64/libboost_process.a ${stage_release}/arm64/libboost_process.a
        lipo -create -output ${stage_release}/libboost_program_options.a ${stage_release}/x86_64/libboost_program_options.a ${stage_release}/arm64/libboost_program_options.a
        lipo -create -output ${stage_release}/libboost_random.a ${stage_release}/x86_64/libboost_random.a ${stage_release}/arm64/libboost_random.a
        lipo -create -output ${stage_release}/libboost_serialization.a ${stage_release}/x86_64/libboost_serialization.a ${stage_release}/arm64/libboost_serialization.a
        lipo -create -output ${stage_release}/libboost_stacktrace_addr2line.a ${stage_release}/x86_64/libboost_stacktrace_addr2line.a ${stage_release}/arm64/libboost_stacktrace_addr2line.a
        lipo -create -output ${stage_release}/libboost_stacktrace_basic.a ${stage_release}/x86_64/libboost_stacktrace_basic.a ${stage_release}/arm64/libboost_stacktrace_basic.a
        lipo -create -output ${stage_release}/libboost_stacktrace_noop.a ${stage_release}/x86_64/libboost_stacktrace_noop.a ${stage_release}/arm64/libboost_stacktrace_noop.a
        lipo -create -output ${stage_release}/libboost_test_exec_monitor.a ${stage_release}/x86_64/libboost_test_exec_monitor.a ${stage_release}/arm64/libboost_test_exec_monitor.a
        lipo -create -output ${stage_release}/libboost_thread.a ${stage_release}/x86_64/libboost_thread.a ${stage_release}/arm64/libboost_thread.a
        lipo -create -output ${stage_release}/libboost_timer.a ${stage_release}/x86_64/libboost_timer.a ${stage_release}/arm64/libboost_timer.a
        lipo -create -output ${stage_release}/libboost_type_erasure.a ${stage_release}/x86_64/libboost_type_erasure.a ${stage_release}/arm64/libboost_type_erasure.a
        lipo -create -output ${stage_release}/libboost_unit_test_framework.a ${stage_release}/x86_64/libboost_unit_test_framework.a ${stage_release}/arm64/libboost_unit_test_framework.a
        lipo -create -output ${stage_release}/libboost_url.a ${stage_release}/x86_64/libboost_url.a ${stage_release}/arm64/libboost_url.a
        lipo -create -output ${stage_release}/libboost_wave.a ${stage_release}/x86_64/libboost_wave.a ${stage_release}/arm64/libboost_wave.a
        lipo -create -output ${stage_release}/libboost_wserialization.a ${stage_release}/x86_64/libboost_wserialization.a ${stage_release}/arm64/libboost_wserialization.a

        # populate version_file
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;

    linux*)
        cxx_opts="$LL_BUILD_RELEASE"
        cc_opts="$(remove_cxxstd $cxx_opts)"

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$cc_opts" \
            CXXFLAGS="$cxx_opts" \
            cmake $top/$BOOST_SOURCE_DIR -G "Ninja" -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=OFF \
                -DCMAKE_BUILD_TYPE="Release" \
                -DCMAKE_C_FLAGS="$cc_opts" \
                -DCMAKE_CXX_FLAGS="$cxx_opts" \
                -DCMAKE_INSTALL_PREFIX="$stage" \
                -DCMAKE_INSTALL_LIBDIR="$stage/lib/release" \
                -DCMAKE_INSTALL_INCLUDEDIR="$stage/include" \
                -DBOOST_INSTALL_LAYOUT="system" \
                -DBOOST_ENABLE_MPI=OFF \
                -DBOOST_ENABLE_PYTHON=OFF \
                -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                -DBOOST_LOCALE_ENABLE_ICU=OFF

            cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
            # fi
        popd

        # populate version_file
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;
esac

popd

mkdir -p "${stage}"/LICENSES
cp -a "$BOOST_SOURCE_DIR/LICENSE_1_0.txt" "${stage}"/LICENSES/boost.txt