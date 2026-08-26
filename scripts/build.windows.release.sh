#!/bin/bash
set -xe

git clone --no-checkout https://github.com/curl/curl
cd curl
git fetch origin 5ce164e0e9290c96eb7d502173426c0a135ec008
git checkout --detach 5ce164e0e9290c96eb7d502173426c0a135ec008
cmake -DCMAKE_BUILD_TYPE=Release -DCURL_USE_LIBSSH2=OFF -DHTTP_ONLY=ON -DCURL_USE_SCHANNEL=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_CURL_EXE=OFF -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX" -G "Unix Makefiles" -DHAVE_LIBIDN2=OFF -DCURL_USE_LIBPSL=OFF .
make install -j4
cd ..

git clone --no-checkout https://github.com/jbeder/yaml-cpp
cd yaml-cpp
git fetch origin e5fe9f2cddbd1a9a8b423bbe40cca661aec6208a
git checkout --detach e5fe9f2cddbd1a9a8b423bbe40cca661aec6208a
cmake -DCMAKE_BUILD_TYPE=Release -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX" -G "Unix Makefiles" .
make install -j4
cd ..

git clone --no-checkout https://github.com/ftk/quickjspp.git
cd quickjspp
git fetch origin 0c00c48895919fc02da3f191a2da06addeb07f09
git checkout 0c00c48895919fc02da3f191a2da06addeb07f09
patch quickjs/quickjs-libc.c -i ../scripts/patches/0001-quickjs-libc-add-realpath-for-Windows.patch
cmake -G "Unix Makefiles" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-D__MINGW_FENV_DEFINED" .
make quickjs -j4

install -d "$MINGW_PREFIX/lib/quickjs/"
install -m644 quickjs/libquickjs.a "$MINGW_PREFIX/lib/quickjs/"
install -d "$MINGW_PREFIX/include/quickjs"
install -m644 quickjs/quickjs.h quickjs/quickjs-libc.h "$MINGW_PREFIX/include/quickjs/"
install -m644 quickjspp.hpp "$MINGW_PREFIX/include/"
cd ..

git clone --no-checkout https://github.com/PerMalmberg/libcron
cd libcron
git fetch origin ee34810b11bd23c8be637345532f91059b68b2d7
git checkout --detach ee34810b11bd23c8be637345532f91059b68b2d7
git submodule update --init
cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX" .
make libcron install -j4
cd ..

git clone --no-checkout https://github.com/Tencent/rapidjson
cd rapidjson
git fetch origin 24b5e7a8b27f42fa16b96fc70aade9106cf7102f
git checkout --detach 24b5e7a8b27f42fa16b96fc70aade9106cf7102f
cmake -DRAPIDJSON_BUILD_DOC=OFF -DRAPIDJSON_BUILD_EXAMPLES=OFF -DRAPIDJSON_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX" -G "Unix Makefiles" .
make install -j4
cd ..

git clone --no-checkout https://github.com/ToruNiina/toml11
cd toml11
git fetch origin 499be3c177bcf9b42848d5d9567153e4edfcbc8a
git checkout --detach 499be3c177bcf9b42848d5d9567153e4edfcbc8a
cmake -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX" -G "Unix Makefiles" -DCMAKE_CXX_STANDARD=11 .
make install -j4
cd ..

python -m ensurepip
python -m pip install --no-cache-dir \
    GitPython==3.1.59 gitdb==4.0.12 smmap==5.0.3 typing-extensions==4.7.1
python scripts/update_rules.py -c scripts/rules_config.conf

rm -f C:/Strawberry/perl/bin/pkg-config C:/Strawberry/perl/bin/pkg-config.bat
cmake -DCMAKE_BUILD_TYPE=Release -G "Unix Makefiles" .
make -j4
rm subconverter.exe
# shellcheck disable=SC2046
g++ $(find CMakeFiles/subconverter.dir/src -name "*.obj") curl/lib/libcurl.a -o base/subconverter.exe -static -Wl,--allow-multiple-definition -lbcrypt -lpcre2-8  -llibcron -lyaml-cpp -liphlpapi -lcrypt32 -lws2_32 -lwsock32 -lz  -Lquickjspp/quickjs -lquickjs -s 
mv base subconverter
