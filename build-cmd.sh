#!/bin/bash

cd "$(dirname "$0")"
top="$(pwd)"

# turn on verbose debugging output for parabuild logs.
set -x
# make errors fatal
set -e

BOOST_SOURCE_DIR="boost"
VERSION_HEADER_FILE="$BOOST_SOURCE_DIR/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

if [ -z "$AUTOBUILD" ] ; then 
    fail
fi

# Libraries on which we depend - please keep alphabetized for maintenance
BOOST_LIBS=(context coroutine date_time filesystem iostreams program_options \
            regex signals system thread)

# Explicitly request each of the libraries named in BOOST_LIBS.
# Use magic bash syntax to prefix each entry in BOOST_LIBS with "--with-".
BOOST_BJAM_OPTIONS="address-model=32 architecture=x86 --layout=tagged -sNO_BZIP2=1
                    ${BOOST_LIBS[*]/#/--with-}"

# Optionally use this function in a platform build to SUPPRESS running unit
# tests on one or more specific libraries: sadly, it happens that some
# libraries we care about might fail their unit tests on a particular platform
# for a particular Boost release.
# Usage: suppress_tests date_time regex
function suppress_tests {
  set +x
  for lib
  do for ((i=0; i<${#BOOST_LIBS[@]}; ++i))
     do if [[ "${BOOST_LIBS[$i]}" == "$lib" ]]
        then unset BOOST_LIBS[$i]
             break
        fi
     done
  done
  echo "BOOST_LIBS=${BOOST_LIBS[*]}"
  set -x
}

BOOST_BUILD_SPAM="-d2 -d+4"             # -d0 is quiet, "-d2 -d+4" allows compilation to be examined

top="$(pwd)"
cd "$BOOST_SOURCE_DIR"
bjam="$(pwd)/bjam"
stage="$(pwd)/stage"

[ -f "$stage"/packages/include/zlib/zlib.h ] || fail "You haven't installed the zlib package yet."
                                                     
if [ "$OSTYPE" = "cygwin" ] ; then
    export AUTOBUILD="$(cygpath -u $AUTOBUILD)"
    # Bjam doesn't know about cygwin paths, so convert them!
fi

# load autobuild provided shell functions and variables
set +x
eval "$("$AUTOBUILD" source_environment)"
set -x

stage_lib="${stage}"/lib
stage_release="${stage_lib}"/release
stage_debug="${stage_lib}"/debug
mkdir -p "${stage_release}"
mkdir -p "${stage_debug}"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/debug/libz.so*.disable "${stage}"/packages/lib/release/libz.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}

# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# bjam doesn't support a -sICU_LIBPATH to point to the location
# of the icu libraries like it does for zlib. Instead, it expects
# the library files to be immediately in the ./lib directory
# and the headers to be in the ./include directory and doesn't
# provide a way to work around this. Because of this, we break
# the standard packaging layout, with the debug library files
# in ./lib/debug and the release in ./lib/release and instead
# only package the release build of icu4c in the ./lib directory.
# If a way to work around this is found, uncomment the
# corresponding blocks in the icu4c build and fix it here.

case "$AUTOBUILD_PLATFORM" in

    "windows")
        INCLUDE_PATH="$(cygpath -m "${stage}"/packages/include)"
        ZLIB_RELEASE_PATH="$(cygpath -m "${stage}"/packages/lib/release)"
        ZLIB_DEBUG_PATH="$(cygpath -m "${stage}"/packages/lib/debug)"
        ICU_PATH="$(cygpath -m "${stage}"/packages)"

        # Odd things go wrong with the .bat files:  branch targets
        # not recognized, file tests incorrect.  Inexplicable but
        # dropping 'echo on' into the .bat files seems to help.
        cmd.exe /C bootstrap.bat vc12

        # Windows build of viewer expects /Zc:wchar_t-, have to match that
        WINDOWS_BJAM_OPTIONS="--toolset=msvc-12.0 -j2 \
            include=$INCLUDE_PATH -sICU_PATH=$ICU_PATH \
            -sZLIB_INCLUDE=$INCLUDE_PATH/zlib \
            cxxflags=-Zc:wchar_t- \
            $BOOST_BJAM_OPTIONS"

        DEBUG_BJAM_OPTIONS="$WINDOWS_BJAM_OPTIONS -sZLIB_LIBPATH=$ZLIB_DEBUG_PATH -sZLIB_LIBRARY_PATH=$ZLIB_DEBUG_PATH -sZLIB_NAME=zlibd"
        "${bjam}" link=static variant=debug \
            --prefix="${stage}" --libdir="${stage_debug}" $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # Windows unit tests seem confused more than usual. So bypass for now
        # but retry with every update.
        BOOST_LIBS=()

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"$blib"/test
                    "${bjam}" link=static variant=debug \
                        --prefix="${stage}" --libdir="${stage_debug}" \
                        $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q
                popd
            done
        fi

        RELEASE_BJAM_OPTIONS="$WINDOWS_BJAM_OPTIONS -sZLIB_LIBPATH=$ZLIB_RELEASE_PATH -sZLIB_LIBRARY_PATH=$ZLIB_RELEASE_PATH -sZLIB_NAME=zlib"
        "${bjam}" link=static variant=release \
            --prefix="${stage}" --libdir="${stage_release}" $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"$blib"/test
                    "${bjam}" link=static variant=release \
                        --prefix="${stage}" --libdir="${stage_debug}" \
                        $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q
                popd
            done
        fi

        # Move the debug libs first, then the leftover release libs
        mv "${stage_lib}"/*-gd.lib "${stage_debug}"
        mv "${stage_lib}"/*.lib "${stage_release}"

        # bjam doesn't need vsvars, but our hand compilation does
        eval "$(AUTOBUILD_VSVER=120 "$AUTOBUILD" source_environment)"
        load_vsvars

        # populate version_file
        cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           /DVERSION_MACRO="$VERSION_MACRO" \
           /Fo"$(cygpath -w "$stage/version.obj")" \
           /Fe"$(cygpath -w "$stage/version.exe")" \
           "$(cygpath -w "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version.exe" | tr '_' '.' > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    "darwin")
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        suppress_tests date_time
        # boost::future::then() appears broken on 32-bit Mac (see boost bug
        # 9558). Disable then() method in the unit test runs and *don't use
        # future::then()* in production until it's known to be good.
        BOOST_CXXFLAGS="-gdwarf-2 \
                        -DBOOST_THREAD_DONT_PROVIDE_FUTURE_CONTINUATION \
                        -DBOOST_THREAD_DONT_PROVIDE_FUTURE_UNWRAP"

        # Force zlib static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "${stage}"/packages/lib/{debug,release}/*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done
            
        stage_lib="${stage}"/lib
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages

        DARWIN_BJAM_OPTIONS="${BOOST_BJAM_OPTIONS} \
            include=\"${stage}\"/packages/include \
            include=\"${stage}\"/packages/include/zlib/ \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            cxxflags=-Wno-c99-extensions cxxflags=-Wno-variadic-macros"

        DEBUG_BJAM_OPTIONS="${DARWIN_BJAM_OPTIONS} \
            -sZLIB_LIBPATH=\"${stage}\"/packages/lib/debug"

        RELEASE_BJAM_OPTIONS="${DARWIN_BJAM_OPTIONS} \
            -sZLIB_LIBPATH=\"${stage}\"/packages/lib/release"

        "${bjam}" toolset=darwin variant=debug $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"${blib}"/test
                    "${bjam}" toolset=darwin variant=debug -a -q \
                        $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM cxxflags="$BOOST_CXXFLAGS"
                popd
            done
        fi

        mv "${stage_lib}"/*.a "${stage_debug}"

        "${bjam}" toolset=darwin variant=release $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM stage
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"${blib}"/test
                    "${bjam}" toolset=darwin variant=release -a -q \
                        $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM cxxflags="$BOOST_CXXFLAGS"
                popd
            done
        fi

        mv "${stage_lib}"/*.a "${stage_release}"

        # populate version_file
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;

    "linux")
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        suppress_tests date_time
        # Force static linkage to libz by moving .sos out of the way
        trap restore_sos EXIT
        for solib in "${stage}"/packages/lib/debug/libz.so* "${stage}"/packages/lib/release/libz.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done
            
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages/

        DEBUG_BOOST_BJAM_OPTIONS="toolset=gcc-4.6 include=$stage/packages/include/zlib/ \
            -sZLIB_LIBPATH=$stage/packages/lib/debug \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            $BOOST_BJAM_OPTIONS"
        "${bjam}" variant=debug --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/debug \
            $DEBUG_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"${blib}"/test
                    "${bjam}" variant=debug -a -q \
                        --prefix="${stage}" --libdir="${stage}"/lib/debug \
                        $DEBUG_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM
                popd
            done
        fi

        mv "${stage_lib}"/libboost* "${stage_debug}"

        "${bjam}" --clean

        RELEASE_BOOST_BJAM_OPTIONS="toolset=gcc-4.6 include=$stage/packages/include/zlib/ \
            -sZLIB_LIBPATH=$stage/packages/lib/release \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            $BOOST_BJAM_OPTIONS"
        "${bjam}" variant=release --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/release \
            $RELEASE_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in "${BOOST_LIBS[@]}"; do
                pushd libs/"${blib}"/test
                    "${bjam}" variant=release -a -q \
                        --prefix="${stage}" --libdir="${stage}"/lib/release \
                        $RELEASE_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM
                popd
            done
        fi

        mv "${stage_lib}"/libboost* "${stage_release}"

        "${bjam}" --clean

        # populate version_file
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;
esac
    
mkdir -p "${stage}"/include
cp -a boost "${stage}"/include/
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt
mkdir -p "${stage}"/docs/boost/
cp -a "$top"/README.Linden "${stage}"/docs/boost/

cd "$top"

pass
