#!/bin/bash
set -ex

DEBUG=0

get_latest_patch_version() {
    # get the latest patch version available and set LAST_PATCH
    if [ -z "$VERSION" ]; then
        VERSION="$(get_latest_stable_version)"
    fi
    LAST_PATCH=`grep Chrome $VV8/patches/*/version.txt | grep $VERSION | awk '{print $2}' | sort -n | tail -n 1`
    if [ -z "$LAST_PATCH" ]; then
        LAST_PATCH=`grep Chrome $VV8/patches/*/version.txt | awk '{print $2}' | sort -n | tail -n 1`
        echo "No patch found for $VERSION, using the latest patch $LAST_PATCH"
    fi
}

get_latest_patch_file() {
    LAST_PATCH_FILE=`grep $LAST_PATCH $VV8/patches/*/version.txt | awk '{print $1}' | sort -n | tail -n 1 | sed "s/:Chrome//" | sed "s/version.txt/trace-apis.diff/"`
    #FIXME: this is a hack to get the object patch, we should settle on one patch file moving forward
    if [ ! -f "$LAST_PATCH_FILE" ]; then
        LAST_PATCH_FILE=`grep $LAST_PATCH $VV8/patches/*/version.txt | awk '{print $1}' | sort -n | tail -n 1 | sed "s/:Chrome//" | sed "s/version.txt/trace-apis-object.diff/"`
    fi
    if [ ! -f "$LAST_PATCH_FILE" ]; then
        echo "No patch file found for $LAST_PATCH"
    fi
}

get_latest_stable_version() {
    curl -s https://omahaproxy.appspot.com/linux
}

VV8="$(pwd)/visiblev8"
[ ! -d $VV8 ] && git clone https://github.com/wspr-ncsu/visiblev8.git $VV8


if [ -z "$1" ]; then
    echo "No Chrome version supplied. Will use the latest stable version."
    VERSION="$(get_latest_stable_version)"
    echo "Latest Chrome stable version is $VERSION"
else
    VERSION=$1
fi

if [[ "$2" -eq 1 ]]; then
    echo "Debug mode is on"
    DEBUG=1
fi

WD="/tmp/$VERSION"
DP="$(pwd)/depot_tools"


get_latest_patch_version
echo $LAST_PATCH;

get_latest_patch_file
echo $LAST_PATCH_FILE

# Git tweaks
git config --global --add safe.directory '*'
export GIT_CACHE_PATH="/build/.git_cache"

### checkout the stable chrome version and its dependencies
[ ! -d $WD/src ] && git clone --depth 4 --branch $VERSION https://github.com/chromium/chromium.git $WD/src
[ ! -d depot_tools ] && git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PATH:${DP}"
cd $WD/
# gclient config https://chromium.googlesource.com/chromium/src.git
cat >.gclient <<EOL
solutions = [
  { "name"        : 'src',
    "url"         : 'https://chromium.googlesource.com/chromium/src.git',
    "deps_file"   : 'DEPS',
    "managed"     : False,
    "custom_deps" : {
    },
    "custom_vars": {
        "checkout_pgo_profiles": True,
    },
  },
]
EOL
cd $WD/src
./build/install-build-deps.sh
gclient sync -D --force --reset --with_branch_heads # --shallow --no-history

### Build config
[ ! -d $WD/src/out/Release ] && mkdir -p $WD/src/out/Release
# we need to provide the correct build args to enable targets like chrome/installer/linux:stable_deb
if [ "$DEBUG" -eq "0" ]; then
    # production args
    cat >>out/Release/args.gn <<EOL
enable_nacl=false
dcheck_always_on=false
is_debug=false
is_official_build=true
enable_linux_installer=true
is_component_build = false
use_thin_lto=false
is_cfi=false
chrome_pgo_phase=0
v8_use_external_startup_data=true
EOL
# target_cpu="x64"
else
    # debug args
    cat >>out/Release/args.gn <<EOL
is_debug=true
dcheck_always_on=true
enable_nacl=false
is_component_build=false
enable_linux_installer=true
v8_enable_debugging_features=true
v8_enable_object_print=true
v8_optimized_debug=false
v8_enable_backtrace=true
v8_postmortem_support=true
v8_use_external_startup_data=false
v8_enable_i18n_support=false
v8_static_library=true
v8_use_external_startup_data=true
EOL
# target_cpu="x64"
fi
gn gen out/Release

### Apply VisibleV8 patches
cd $WD/src/v8
echo "Using $LAST_PATCH_FILE to patch V8"
# "Run `docker commit $(docker ps -q -l) patch-failed` to analyze the failed patches."
patch -p1 <$LAST_PATCH_FILE 
cd $WD/src

# building
autoninja -C out/Release chrome d8 wasm_api_tests cctest inspector-test  v8_mjsunit v8_shell v8/test/unittests icudtl.dat snapshot_blob.bin web_idl_database chrome/installer/linux:stable_deb

# Build and run V8 tests directly
# ./v8/tools/dev/gm.py x64.release.check 


# copy artifacts
mkdir -p /artifacts/$VERSION/
cp out/Release/chrome /artifacts/$VERSION/chrome-vv8-$VERSION
cp out/Release/v8_shell /artifacts/$VERSION/vv8-shell-$VERSION
cp out/Release/*.deb /artifacts/$VERSION/
cp -r out/Release/unittests /artifacts/$VERSION/
cp out/Release/icudtl.dat /artifacts/$VERSION/
cp out/Release/snapshot_blob.bin /artifacts/$VERSION/
# check here how to use web_idl_database.pickle: https://source.chromium.org/chromium/chromium/src/+/main:third_party/blink/renderer/bindings/scripts/web_idl/README.md
cp out/Release/gen/third_party/blink/renderer/bindings/web_idl_database.pickle /artifacts/$VERSION/
# cp out/Release/natives_blob.bin /artifacts/$VERSION/
chmod +rw -R /artifacts

# Testing V8
#TODO: run v8 tests
# python3 ./v8/tools/run-tests.py --out=../out/Release/ unittests

#TODO: old versions have a different way to dump the idl
#$VV8/builder/resources/build/dump_idl.py "$WD/src" > "/artifacts/$VERSION/idldata.json"