#!/usr/bin/env bash

cd "$(dirname "$0")"
top="$(pwd)"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# error on undefined environment variables
set -u

BOOST_SOURCE_DIR="boost"
VERSION_HEADER_FILE="$BOOST_SOURCE_DIR/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

if [ -z "$AUTOBUILD" ] ; then 
    exit 1
fi

# Libraries on which we depend - please keep alphabetized for maintenance
BOOST_LIBS=(atomic chrono context date_time fiber filesystem iostreams nowide program_options \
            regex stacktrace system thread wave)

BOOST_BUILD_SPAM=""             # -d0 is quiet, "-d2 -d+4" allows compilation to be examined

top="$(pwd)"
cd "$BOOST_SOURCE_DIR"
# As of sometime between Boost 1.67 and 1.72, the Boost build engine b2's
# legacy bjam alias is no longer copied to the top-level Boost directory. Use
# b2 directly.
bjam="$(pwd)/b2"
stage="$(pwd)/stage"

[ -f "$stage"/packages/include/zlib/zlib.h ] || fail "You haven't installed the zlib package yet."
                                                     
if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
    # convert from bash path to native OS pathname
    native()
    {
        cygpath -w "$@"
    }
else
    autobuild="$AUTOBUILD"
    # no pathname conversion needed
    native()
    {
        echo "$*"
    }
fi

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# Explicitly request each of the libraries named in BOOST_LIBS.
# Use magic bash syntax to prefix each entry in BOOST_LIBS with "--with-".
BOOST_BJAM_OPTIONS="--layout=tagged -sNO_BZIP2=1 -sNO_LZMA=1 -sNO_ZSTD=1 \
                    ${BOOST_LIBS[*]/#/--with-}"

# Turn these into a bash array: it's important that all of cxxflags (which
# we're about to add) go into a single array entry.
BOOST_BJAM_OPTIONS=($BOOST_BJAM_OPTIONS)

stage_lib="${stage}"/lib
stage_debug="${stage_lib}"/debug
stage_release="${stage_lib}"/release
mkdir -p "${stage_debug}"
mkdir -p "${stage_release}"

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

find_test_jamfile_dir_for()
{
    # Not every Boost library contains a libs/x/test/Jamfile.v2 file. Some
    # have libs/x/test/build/Jamfile.v2. Some have more than one test
    # subdirectory with a Jamfile. Try to be general about it.
    # You can't use bash 'read' from a pipe, though truthfully I've always
    # wished that worked. What you *can* do is read from redirected stdin, but
    # that must follow 'done'.
    while read path
    do # caller doesn't want the actual Jamfile name, just its directory
       dirname "$path"
    done < <(find libs/$1/test -name 'Jam????*' -type f -print)
    # Credit to https://stackoverflow.com/a/11100252/5533635 for the
    # < <(command) trick. Empirically, it does iterate 0 times on empty input.
}

find_test_dirs()
{
    # Pass in the libraries of interest. This shell function emits to stdout
    # the corresponding set of test directories, one per line: the specific
    # library directories containing the Jamfiles of interest. Passing each of
    # these directories to bjam should cause it to build and run that set of
    # tests.
    for blib
    do
        find_test_jamfile_dir_for "$blib"
    done
}

# conditionally run unit tests
run_tests()
{
    # This shell function wants to accept two different sets of arguments,
    # each of arbitrary length: the list of library test directories, and the
    # list of bjam arguments for each test. Since we don't have a good way to
    # do that in bash, we read library test directories from stdin, one per
    # line; command-line arguments are simply forwarded to the bjam command.
    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
        # read individual directories from stdin below
        while read testdir
        do  sep "$testdir"
            "${bjam}" "$testdir" "$@"
        done < /dev/stdin
    fi
    return 0
}

last_file="$(mktemp -t build-cmd.XXXXXXXX)"
trap "rm '$last_file'" EXIT
# from here on, the only references to last_file will be from Python
last_file="$(native "$last_file")"
last_time="$(python -c "import os.path; print(int(os.path.getmtime(r'$last_file')))")"
start_time="$last_time"

sep()
{
    python -c "
from __future__ import print_function
import os
import sys
import time
start = $start_time
last_file = r'$last_file'
last = int(os.path.getmtime(last_file))
now = int(time.time())
os.utime(last_file, (now, now))
def since(baseline, now):
    duration = now - baseline
    rest, secs = divmod(duration, 60)
    hours, mins = divmod(rest, 60)
    return '%2d:%02d:%02d' % (hours, mins, secs)
print('((((( %s )))))' % since(last, now), file=sys.stderr)
print(since(start, now), ' $* '.center(72, '='), file=sys.stderr)
"
}

case "$AUTOBUILD_PLATFORM" in

    windows*)
        # We've observed some weird failures in which the PATH is too big
        # to be passed to a child process! When that gets munged, we start
        # seeing errors like 'nmake' failing to find the 'cl.exe' command.
        # Thing is, by this point in the script we've acquired a shocking
        # number of duplicate entries. Dedup the PATH using Python's
        # OrderedDict, which preserves the order in which you insert keys.
        # We find that some of the Visual Studio PATH entries appear both
        # with and without a trailing slash, which is pointless. Strip
        # those off and dedup what's left.
        # Pass the existing PATH as an explicit argument rather than
        # reading it from the environment, to bypass the fact that cygwin
        # implicitly converts PATH to Windows form when running a native
        # executable. Since we're setting bash's PATH, leave everything in
        # cygwin form. That means splitting and rejoining on ':' rather
        # than on os.pathsep, which on Windows is ';'.
        # Use python -u, else the resulting PATH will end with a spurious
        # '\r'.
        export PATH="$(python -u -c "import sys
from collections import OrderedDict
print(':'.join(OrderedDict((dir.rstrip('/'), 1) for dir in sys.argv[1].split(':'))))" "$PATH")"
    
        INCLUDE_PATH="$(cygpath -m "${stage}"/packages/include)"
        ZLIB_DEBUG_PATH="$(cygpath -m "${stage}"/packages/lib/debug)"
        ZLIB_RELEASE_PATH="$(cygpath -m "${stage}"/packages/lib/release)"

        case "$AUTOBUILD_VSVER" in
            120)
                bootstrapver="vc12"
                bjamtoolset="msvc-12.0"
                ;;
            150)
                bootstrapver="vc141"
                bjamtoolset="msvc-14.1"
                ;;
            16*)
                bootstrapver="vc142"
                bjamtoolset="msvc-14.2"
                ;;
            17*)
                bootstrapver="vc143"
                bjamtoolset="msvc-14.3"
                ;;
            *)
                echo "Unrecognized AUTOBUILD_VSVER='$AUTOBUILD_VSVER'" 1>&2 ; exit 1
                ;;
        esac

        sep "bootstrap"
        # Odd things go wrong with the .bat files:  branch targets
        # not recognized, file tests incorrect.  Inexplicable but
        # dropping 'echo on' into the .bat files seems to help.
        cmd.exe /C bootstrap.bat "$bootstrapver" || echo bootstrap failed 1>&2
        # Failure of this bootstrap.bat file may or may not produce nonzero rc
        # -- check for the program it should have built.
        if [ ! -x "$bjam.exe" ]
        then cat "bootstrap.log"
             exit 1
        fi

        # Without --abbreviate-paths, some compilations fail with:
        # failed to write output file 'some\long\path\something.rsp'!
        # Without /FS, some compilations fail with:
        # fatal error C1041: cannot open program database '...\vc120.pdb';
        # if multiple CL.EXE write to the same .PDB file, please use /FS
        # BOOST_STACKTRACE_LINK (not _DYN_LINK) requests external library:
        # https://www.boost.org/doc/libs/release/doc/html/stacktrace/configuration_and_build.html
        # This helps avoid macro collisions in consuming source files:
        # https://github.com/boostorg/stacktrace/issues/76#issuecomment-489347839
        WINDOWS_BJAM_OPTIONS=(address-model=$AUTOBUILD_ADDRSIZE architecture=x86 link=static runtime-link=shared \
        cxxstd=17 \
        debug-symbols=on \
        --toolset=$bjamtoolset \
        -j$NUMBER_OF_PROCESSORS \
        --hash \
        include=$INCLUDE_PATH \
        cxxflags=/std:c++17 \
        cxxflags=/permissive- \
        "${BOOST_BJAM_OPTIONS[@]}")

        DEBUG_BJAM_OPTIONS=("${WINDOWS_BJAM_OPTIONS[@]}" variant=debug)

        cp "$top/user-config.jam" user-config.jam
        sed -i -e "s#ZLIB_LIB_PATH#${ZLIB_DEBUG_PATH}#g" user-config.jam
        sed -i -e "s#ZLIB_LIB_NAME#zlibd#g" user-config.jam
        sed -i -e "s#ZLIB_INCLUDE_PATH#${INCLUDE_PATH}/zlib#g" user-config.jam

        USER_CONFIG="$(cygpath -m -a ./user-config.jam)"

        sep "debugbuild"
        "${bjam}" --prefix="$(cygpath -m  ${stage})" --libdir="$(cygpath -m  ${stage_debug})" \
            "${DEBUG_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --user-config="$USER_CONFIG" -a -q stage

        # Constraining Windows unit tests to link=static produces unit-test
        # link errors. While it may be possible to edit the test/Jamfile.v2
        # logic in such a way as to succeed statically, it's simpler to allow
        # dynamic linking for test purposes. However -- with dynamic linking,
        # some test executables expect to implicitly load a couple of ICU
        # DLLs. But our installed ICU doesn't even package those DLLs!
        # TODO: Does this clutter our eventual tarball, or are the extra Boost
        # DLLs in a separate build directory?
        # In any case, we still observe failures in certain libraries' unit
        # tests. Certain libraries depend on ICU; thread tests are so deeply
        # nested that even with --abbreviate-paths, the .rsp file pathname is
        # too long for Windows. Poor sad broken Windows.

        # conditionally run unit tests
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
             | \
        run_tests \
                  --prefix="$(native "${stage}")" --libdir="$(native "${stage_debug}")" \
                  "${DEBUG_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --user-config="$USER_CONFIG" -a -q

        # Move the libs
        mv "${stage_lib}"/*.lib "${stage_debug}"

        sep "clean"
        "${bjam}" --clean-all

        RELEASE_BJAM_OPTIONS=("${WINDOWS_BJAM_OPTIONS[@]}" variant=release optimization=speed)

        cp "$top/user-config.jam" user-config.jam
        sed -i -e "s#ZLIB_LIB_PATH#${ZLIB_RELEASE_PATH}#g" user-config.jam
        sed -i -e "s#ZLIB_LIB_NAME#zlib#g" user-config.jam
        sed -i -e "s#ZLIB_INCLUDE_PATH#${INCLUDE_PATH}/zlib#g" user-config.jam

        USER_CONFIG="$(cygpath -m -a ./user-config.jam)"

        sep "releasebuild"
        "${bjam}" --prefix="$(cygpath -m  ${stage})" --libdir="$(cygpath -m  ${stage_release})" \
            "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --user-config="$USER_CONFIG" -a -q stage

        # Constraining Windows unit tests to link=static produces unit-test
        # link errors. While it may be possible to edit the test/Jamfile.v2
        # logic in such a way as to succeed statically, it's simpler to allow
        # dynamic linking for test purposes. However -- with dynamic linking,
        # some test executables expect to implicitly load a couple of ICU
        # DLLs. But our installed ICU doesn't even package those DLLs!
        # TODO: Does this clutter our eventual tarball, or are the extra Boost
        # DLLs in a separate build directory?
        # In any case, we still observe failures in certain libraries' unit
        # tests. Certain libraries depend on ICU; thread tests are so deeply
        # nested that even with --abbreviate-paths, the .rsp file pathname is
        # too long for Windows. Poor sad broken Windows.

        # conditionally run unit tests
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
             | \
        run_tests \
                  --prefix="$(native "${stage}")" --libdir="$(native "${stage_release}")" \
                  $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM --user-config="$USER_CONFIG" -a -q

        # Move the libs
        mv "${stage_lib}"/*.lib "${stage_release}"

        sep "version"
        # bjam doesn't need vsvars, but our hand compilation does
        load_vsvars

        # populate version_file
        cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           /DVERSION_MACRO="$VERSION_MACRO" \
           /Fo"$(native "$stage/version.obj")" \
           /Fe"$(native "$stage/version.exe")" \
           "$(native "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        localver=`$stage/version.exe | tr '_' '.' | tr -d '\15\32'`
        echo "${localver}.0" > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    darwin*)
        # Setup osx sdk platform
        SDKNAME="macosx"
        export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)

        # Deploy Targets
        X86_DEPLOY=10.15
        ARM64_DEPLOY=11.0

        # Force zlib static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "${stage}"/packages/lib/{debug,release}/*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done

        INCLUDE_PATH="${stage}/packages/include"
        ZLIB_DEBUG_PATH="${stage}/packages/lib/debug"
        ZLIB_RELEASE_PATH="${stage}/packages/lib/release"

        cp "$top/user-config.jam" debug-user-config.jam
        sed -e "s#ZLIB_LIB_PATH#${ZLIB_DEBUG_PATH}#g" -i back debug-user-config.jam
        sed -e "s#ZLIB_LIB_NAME#z#g" -i back debug-user-config.jam
        sed -e "s#ZLIB_INCLUDE_PATH#${INCLUDE_PATH}/zlib#g" -i back debug-user-config.jam

        cp "$top/user-config.jam" release-user-config.jam
        sed -e "s#ZLIB_LIB_PATH#${ZLIB_RELEASE_PATH}#g" -i back release-user-config.jam
        sed -e "s#ZLIB_LIB_NAME#z#g" -i back release-user-config.jam
        sed -e "s#ZLIB_INCLUDE_PATH#${INCLUDE_PATH}/zlib#g" -i back release-user-config.jam

        sep "Bootstrap"
        stage_lib="${stage}"/lib
        ./bootstrap.sh --prefix=$(pwd) --with-toolset=clang cxxflags="-arch x86_64 -arch arm64" cflags="-arch x86_64 -arch arm64" linkflags="-arch x86_64 -arch arm64"

        # Boost.Context and Boost.Coroutine2 now require C++14 support.
        # Without the -Wno-etc switches, clang spams the build output with
        # many hundreds of pointless warnings.
        # Building Boost.Regex without --disable-icu causes the viewer link to
        # fail for lack of an ICU library.
        DARWIN_BJAM_OPTIONS=("${BOOST_BJAM_OPTIONS[@]}" \
            link=static \
            visibility=hidden \
            cxxstd=17 \
            debug-symbols=on \
            cxxflags=-std=c++17 \
            cxxflags=-stdlib=libc++ \
            cxxflags="-isysroot ${SDKROOT}" \
            cxxflags=-fPIC
            cflags="-isysroot ${SDKROOT}" \
            cflags=-fPIC
            linkflags="-isysroot ${SDKROOT}" \
            "include=${stage}/packages/include" \
            "include=${stage}/packages/include/zlib/" \
            "-sZLIB_INCLUDE=${stage}/packages/include/zlib/" \
            --disable-icu)

        DEBUG_BJAM_OPTIONS=("${DARWIN_BJAM_OPTIONS[@]}" --user-config="$PWD/debug-user-config.jam" variant=debug optimization=off)
        RELEASE_BJAM_OPTIONS=("${DARWIN_BJAM_OPTIONS[@]}" --user-config="$PWD/release-user-config.jam" variant=release optimization=speed)

        ARM64_OPTIONS=(toolset=clang-darwin target-os=darwin abi=aapcs address-model=64 architecture=arm \
            cxxflags="-arch arm64" cflags="-arch arm64" linkflags="-arch arm64" \
            cxxflags=-mmacosx-version-min=${ARM64_DEPLOY} \
            cflags=-mmacosx-version-min=${ARM64_DEPLOY})

        X86_OPTIONS=(toolset=clang-darwin target-os=darwin abi=sysv binary-format=mach-o address-model=64 architecture=x86 \
            "cxxflags=-arch x86_64" "cflags=-arch x86_64" linkflags="-arch x86_64" \
            cflags=-msse4.2 cxxflags=-msse4.2 \
            cxxflags=-mmacosx-version-min=${X86_DEPLOY} \
            cflags=-mmacosx-version-min=${X86_DEPLOY})        

        # setup for x86
        export MACOSX_DEPLOYMENT_TARGET=${X86_DEPLOY}

        sep "X86 Debug Build"
        rm -rf bin.v2
        "${bjam}" "${X86_OPTIONS[@]}" "${DEBUG_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --stagedir="$stage/debug_x86" stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # With Boost 1.64, skip filesystem/tests/issues -- we get:
        # error: Unable to find file or target named
        # error:     '6638-convert_aux-fails-init-global.cpp'
        # error: referred to from project at
        # error:     'libs/filesystem/test/issues'
        # regex/tests/de_fuzz depends on an external Fuzzer library:
        # ld: library not found for -lFuzzer
        # Sadly, as of Boost 1.65.1, the Stacktrace self-tests just do not
        # seem ready for prime time on Mac.
        # Bump the timeout for Boost.Thread tests because our TeamCity Mac
        # build hosts are getting a bit long in the tooth.
        sep "X86 Debug Tests"
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'program_options/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
            | \
        run_tests "${X86_OPTIONS[@]}" -a -q \
                  "${DEBUG_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM \
                  cxxflags="-DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED" \
                  cxxflags="-DBOOST_THREAD_TEST_TIME_MS=250"

        sep "X86 Release Build"
        rm -rf bin.v2
        "${bjam}" "${X86_OPTIONS[@]}" "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --stagedir="$stage/release_x86" stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # With Boost 1.64, skip filesystem/tests/issues -- we get:
        # error: Unable to find file or target named
        # error:     '6638-convert_aux-fails-init-global.cpp'
        # error: referred to from project at
        # error:     'libs/filesystem/test/issues'
        # regex/tests/de_fuzz depends on an external Fuzzer library:
        # ld: library not found for -lFuzzer
        # Sadly, as of Boost 1.65.1, the Stacktrace self-tests just do not
        # seem ready for prime time on Mac.
        # Bump the timeout for Boost.Thread tests because our TeamCity Mac
        # build hosts are getting a bit long in the tooth.
        sep "X86 Release Tests"
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'program_options/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
            | \
        run_tests "${X86_OPTIONS[@]}" -a -q \
                  "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM \
                  cxxflags="-DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED" \
                  cxxflags="-DBOOST_THREAD_TEST_TIME_MS=250"

        # setup for ARM64
        export MACOSX_DEPLOYMENT_TARGET=${ARM64_DEPLOY}

        sep "ARM64 Debug Build"
        rm -rf bin.v2
        "${bjam}" "${ARM64_OPTIONS[@]}" "${DEBUG_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --stagedir="$stage/debug_arm64" stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # With Boost 1.64, skip filesystem/tests/issues -- we get:
        # error: Unable to find file or target named
        # error:     '6638-convert_aux-fails-init-global.cpp'
        # error: referred to from project at
        # error:     'libs/filesystem/test/issues'
        # regex/tests/de_fuzz depends on an external Fuzzer library:
        # ld: library not found for -lFuzzer
        # Sadly, as of Boost 1.65.1, the Stacktrace self-tests just do not
        # seem ready for prime time on Mac.
        # Bump the timeout for Boost.Thread tests because our TeamCity Mac
        # build hosts are getting a bit long in the tooth.
        sep "ARM64 Debug Tests"
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'program_options/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
            | \
        run_tests "${ARM64_OPTIONS[@]}" -a -q \
                  "${DEBUG_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM \
                  cxxflags="-DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED" \
                  cxxflags="-DBOOST_THREAD_TEST_TIME_MS=250"

        sep "ARM64 Release Build"
        rm -rf bin.v2
        "${bjam}" "${ARM64_OPTIONS[@]}" "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM --stagedir="$stage/release_arm64" stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # With Boost 1.64, skip filesystem/tests/issues -- we get:
        # error: Unable to find file or target named
        # error:     '6638-convert_aux-fails-init-global.cpp'
        # error: referred to from project at
        # error:     'libs/filesystem/test/issues'
        # regex/tests/de_fuzz depends on an external Fuzzer library:
        # ld: library not found for -lFuzzer
        # Sadly, as of Boost 1.65.1, the Stacktrace self-tests just do not
        # seem ready for prime time on Mac.
        # Bump the timeout for Boost.Thread tests because our TeamCity Mac
        # build hosts are getting a bit long in the tooth.
        sep "ARM64 Release Tests"
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'program_options/' \
             -e 'regex/' \
             -e 'stacktrace/' \
             -e 'thread/' \
            | \
        run_tests "${ARM64_OPTIONS[@]}" -a -q \
                  "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM \
                  cxxflags="-DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED" \
                  cxxflags="-DBOOST_THREAD_TEST_TIME_MS=250"

        # create debug fat libs
        lipo -create ${stage}/debug_x86/lib/libboost_atomic-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_atomic-mt-d-a64.a -output ${stage}/lib/debug/libboost_atomic-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_chrono-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_chrono-mt-d-a64.a -output ${stage}/lib/debug/libboost_chrono-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_context-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_context-mt-d-a64.a -output ${stage}/lib/debug/libboost_context-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_date_time-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_date_time-mt-d-a64.a -output ${stage}/lib/debug/libboost_date_time-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_fiber-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_fiber-mt-d-a64.a -output ${stage}/lib/debug/libboost_fiber-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_filesystem-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_filesystem-mt-d-a64.a -output ${stage}/lib/debug/libboost_filesystem-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_iostreams-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_iostreams-mt-d-a64.a -output ${stage}/lib/debug/libboost_iostreams-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_nowide-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_nowide-mt-d-a64.a -output ${stage}/lib/debug/libboost_nowide-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_program_options-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_program_options-mt-d-a64.a -output ${stage}/lib/debug/libboost_program_options-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_regex-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_regex-mt-d-a64.a -output ${stage}/lib/debug/libboost_regex-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_stacktrace_basic-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_stacktrace_basic-mt-d-a64.a -output ${stage}/lib/debug/libboost_stacktrace_basic-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_stacktrace_noop-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_stacktrace_noop-mt-d-a64.a -output ${stage}/lib/debug/libboost_stacktrace_noop-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_system-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_system-mt-d-a64.a -output ${stage}/lib/debug/libboost_system-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_thread-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_thread-mt-d-a64.a -output ${stage}/lib/debug/libboost_thread-mt-d.a
        lipo -create ${stage}/debug_x86/lib/libboost_wave-mt-d-x64.a ${stage}/debug_arm64/lib/libboost_wave-mt-d-a64.a -output ${stage}/lib/debug/libboost_wave-mt-d.a

        # create release fat libs
        lipo -create ${stage}/release_x86/lib/libboost_atomic-mt-x64.a ${stage}/release_arm64/lib/libboost_atomic-mt-a64.a -output ${stage}/lib/release/libboost_atomic-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_chrono-mt-x64.a ${stage}/release_arm64/lib/libboost_chrono-mt-a64.a -output ${stage}/lib/release/libboost_chrono-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_context-mt-x64.a ${stage}/release_arm64/lib/libboost_context-mt-a64.a -output ${stage}/lib/release/libboost_context-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_date_time-mt-x64.a ${stage}/release_arm64/lib/libboost_date_time-mt-a64.a -output ${stage}/lib/release/libboost_date_time-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_fiber-mt-x64.a ${stage}/release_arm64/lib/libboost_fiber-mt-a64.a -output ${stage}/lib/release/libboost_fiber-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_filesystem-mt-x64.a ${stage}/release_arm64/lib/libboost_filesystem-mt-a64.a -output ${stage}/lib/release/libboost_filesystem-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_iostreams-mt-x64.a ${stage}/release_arm64/lib/libboost_iostreams-mt-a64.a -output ${stage}/lib/release/libboost_iostreams-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_nowide-mt-x64.a ${stage}/release_arm64/lib/libboost_nowide-mt-a64.a -output ${stage}/lib/release/libboost_nowide-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_program_options-mt-x64.a ${stage}/release_arm64/lib/libboost_program_options-mt-a64.a -output ${stage}/lib/release/libboost_program_options-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_regex-mt-x64.a ${stage}/release_arm64/lib/libboost_regex-mt-a64.a -output ${stage}/lib/release/libboost_regex-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_stacktrace_basic-mt-x64.a ${stage}/release_arm64/lib/libboost_stacktrace_basic-mt-a64.a -output ${stage}/lib/release/libboost_stacktrace_basic-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_stacktrace_noop-mt-x64.a ${stage}/release_arm64/lib/libboost_stacktrace_noop-mt-a64.a -output ${stage}/lib/release/libboost_stacktrace_noop-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_system-mt-x64.a ${stage}/release_arm64/lib/libboost_system-mt-a64.a -output ${stage}/lib/release/libboost_system-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_thread-mt-x64.a ${stage}/release_arm64/lib/libboost_thread-mt-a64.a -output ${stage}/lib/release/libboost_thread-mt.a
        lipo -create ${stage}/release_x86/lib/libboost_wave-mt-x64.a ${stage}/release_arm64/lib/libboost_wave-mt-a64.a -output ${stage}/lib/release/libboost_wave-mt.a

        # populate version_file
        sep "Version"
        cc -arch x86_64 -arch arm64 -O2 -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        localver=`$stage/version | tr '_' '.' | tr -d '\15\32'`
        echo "${localver}.0" > "$stage/version.txt"
        rm "$stage/version"
        ;;

    linux*)
        # Force static linkage to libz by moving .sos out of the way
        trap restore_sos EXIT
        for solib in "${stage}"/packages/lib/debug/libz.so* "${stage}"/packages/lib/release/libz.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done

        sep "bootstrap"
        ./bootstrap.sh --prefix=$(pwd) --without-icu

        DEBUG_BOOST_BJAM_OPTIONS=(address-model=$AUTOBUILD_ADDRSIZE architecture=x86 \
            --disable-icu toolset=gcc link=static debug-symbols=on cxxstd=17 \
            "include=${stage}/packages/include" \
            "include=${stage}/packages/include/zlib/" \
            "-sZLIB_LIBPATH=$stage/packages/lib/debug" \
            "-sZLIB_INCLUDE=${stage}\/packages/include/zlib/" \
            "${BOOST_BJAM_OPTIONS[@]}" \
            "cflags=-Og" "cflags=-fPIC" "cflags=-DPIC" "cflags=-g" \
            "cxxflags=-std=c++17" "cxxflags=-Og" "cxxflags=-fPIC" "cxxflags=-DPIC" "cxxflags=-g")
        sep "Debug Build"
        "${bjam}" variant=debug --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/debug \
            "${DEBUG_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # libs/regex/test/de_fuzz produces:
        # error: "clang" is not a known value of feature <toolset>
        # error: legal values: "gcc"
        sep "Debug Tests"
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'atomic/' \
             -e 'chrono/' \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'regex/' \
             -e 'thread/' \
            | \
        run_tests variant=debug -a -q \
                  --prefix="${stage}" --libdir="${stage}"/lib/debug \
                  "${DEBUG_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM

        mv "${stage_lib}"/libboost*-d-*.a "${stage_debug}"

        sep "Debug Clean"
        "${bjam}" --clean

        RELEASE_BOOST_BJAM_OPTIONS=(address-model=$AUTOBUILD_ADDRSIZE architecture=x86 \
            --disable-icu toolset=gcc link=static debug-symbols=on cxxstd=17 "include=$stage/packages/include/zlib/" \
            "-sZLIB_LIBPATH=$stage/packages/lib/release" \
            "-sZLIB_INCLUDE=${stage}\/packages/include/zlib/" \
            "${BOOST_BJAM_OPTIONS[@]}" \
            "cflags=-O3" "cflags=-fstack-protector-strong" "cflags=-fPIC" "cflags=-D_FORTIFY_SOURCE=2" "cflags=-DPIC" "cflags=-g" \
            "cxxflags=-std=c++17" "cxxflags=-O3" "cxxflags=-fstack-protector-strong" "cxxflags=-fPIC" "cxxflags=-D_FORTIFY_SOURCE=2" "cxxflags=-DPIC" "cxxflags=-g")

        sep "Release Build"
        "${bjam}" variant=release --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/release \
            "${RELEASE_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        # date_time Posix test failures: https://svn.boost.org/trac/boost/ticket/10570
        # libs/regex/test/de_fuzz produces:
        # error: "clang" is not a known value of feature <toolset>
        # error: legal values: "gcc"
        sep "Release Tests"
        find_test_dirs "${BOOST_LIBS[@]}" | \
        grep -v \
             -e 'atomic/' \
             -e 'chrono/' \
             -e 'date_time/' \
             -e 'filesystem/' \
             -e 'iostreams/' \
             -e 'regex/' \
             -e 'thread/' \
            | \
        run_tests variant=release -a -q \
                  --prefix="${stage}" --libdir="${stage}"/lib/release \
                  "${RELEASE_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM

        mv "${stage_lib}"/libboost*.a "${stage_release}"

        sep "Release Clean"
        "${bjam}" --clean

        # populate version_file
        sep "Version"
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        localver=`$stage/version | tr '_' '.' | tr -d '\15\32'`
        echo "${localver}.0" > "$stage/version.txt"
        rm "$stage/version"
        ;;
esac

sep "includes and text"
mkdir -p "${stage}"/include
cp -a boost "${stage}"/include/
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt

cd "$top"
