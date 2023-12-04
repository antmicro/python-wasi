#!/bin/bash

PROJECT_DIR=$(pwd)
PYTHON_TAG="3.10.6"
DEPS_DIR="$PROJECT_DIR/deps"
[[ -z $WASI_SDK_PATH ]] && export WASI_SDK_PATH="${DEPS_DIR}/wasi-sdk"
WORK_DIR="$PROJECT_DIR/work"
PYTHON_DIR="$WORK_DIR/cpython-$PYTHON_TAG"
WASIX_DIR="$DEPS_DIR/wasix"
WASI_EXT_LIB_DIR="$DEPS_DIR/wasi_ext_lib"
WASI_EXT_LIB_SHA="7d80d5c4b204dce8c7b14980b68b60f5184e2989"
LIB_DIR="$PROJECT_DIR/lib"
INCLUDE_DIR="$PROJECT_DIR/include"
INSTALL_PREFIX="$PROJECT_DIR/out"

set -e

clean() {
    rm -rf work/
}

clean_all() {
    rm -rf work/ deps/
}

get_deps() {
    mkdir -p $DEPS_DIR
    mkdir -p $WORK_DIR
    if [[ ! -d $PYTHON_DIR ]]; then
        if [[ ! -f $DEPS_DIR/v$PYTHON_TAG.zip ]]; then
            echo "Downloading python..."
            wget -P $DEPS_DIR -q https://github.com/python/cpython/archive/refs/tags/v$PYTHON_TAG.zip
        fi
        unzip -q -d $WORK_DIR $DEPS_DIR/v$PYTHON_TAG.zip
    fi

    if [[ ! -d $WASI_SDK_PATH ]]; then
        echo "Downloading wasi sdk..."
        wget -P ${DEPS_DIR} \
            -q https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-16/wasi-sdk-16.0-linux.tar.gz
        tar zxf ${DEPS_DIR}/wasi-sdk-16.0-linux.tar.gz -C ${DEPS_DIR}
        rm ${DEPS_DIR}/wasi-sdk-16.0-linux.tar.gz && \
        mv ${DEPS_DIR}/wasi-sdk-16.0 ${DEPS_DIR}/wasi-sdk
    fi

    if [[ ! -d $WASIX_DIR ]]; then
        echo "Downloading wasix..."
        git clone https://github.com/singlestore-labs/wasix $WASIX_DIR
        cd $WASIX_DIR && git apply $PROJECT_DIR/patches/wasix_tmp_max.patch; make
        cd $PROJECT_DIR
    fi

    if [[ ! -d $WASI_EXT_LIB_DIR ]]; then
        echo "Downloading wasi ext lib"
        git clone https://github.com/antmicro/wasi_ext_lib $WASI_EXT_LIB_DIR
        cd $WASI_EXT_LIB_DIR
        git checkout "$WASI_EXT_LIB_SHA"
        cd c_lib
        make
        cd $PROJECT_DIR
    fi

    # Python checks for this, but doesn't seem to use it.
    touch $WASI_SDK_PATH/bin/wasm32-wasi-readelf && \
    chmod +x $WASI_SDK_PATH/bin/wasm32-wasi-readelf
}

build() {
    PYTHON_VER=$(grep '^VERSION=' "${PYTHON_DIR}/configure" | cut -d= -f2)
    PYTHON_MAJOR=$(echo $PYTHON_VER | cut -d. -f1)
    PYTHON_MINOR=$(echo $PYTHON_VER | cut -d. -f2)
    export PATH="${WASI_SDK_PATH}/bin:${PATH}"

    if [[ ! -d "${PYTHON_DIR}/inst/${PYTHON_VER}" ]]; then
        cd "${PYTHON_DIR}"
        rm -f Modules/Setup.local
        ./configure --disable-test-modules \
    	        --with-ensurepip=no \
    	        --disable-test-modules \
    	        --prefix="${PYTHON_DIR}/inst/${PYTHON_VER}" \
    	        --exec-prefix="${PYTHON_DIR}/inst/${PYTHON_VER}" && \
            make clean && \
            make && \
    	make install
    else
        cd ${PYTHON_DIR}
    fi

    export CONFIG_SITE="${PROJECT_DIR}/config.site"

    if [[ ($PYTHON_MAJOR -ge "3") && ($PYTHON_MINOR -ge "11") ]]; then
        rm -f "${PYTHON_DIR}/Modules/Setup.local"
        patch -p1 -N -r- < ${PROJECT_DIR}/patches/getpath.py.patch
    else
        export LIBS="-Wl,--stack-first -Wl,-z,stack-size=83886080"

        cp "${PROJECT_DIR}/Setup.local" "${PYTHON_DIR}/Modules/Setup.local"

        # Apply patches (some of them don't need to match)
        patch -p1 -N -r- < ${PROJECT_DIR}/patches/configure.ac.patch || true
        patch -p1 -N -r- < ${PROJECT_DIR}/patches/python.c.patch || true
        patch -p1 -N -r- < ${PROJECT_DIR}/patches/tempfile.patch

        if [[ -f "${PYTHON_DIR}/Modules/_zoneinfo.c" ]]; then
            patch -p1 -N -r- < ${PROJECT_DIR}/patches/_zoneinfo.c.patch || true
        fi

        if [[ ("$PYTHON_MAJOR" -eq "3") && ("$PYTHON_MINOR" -le "8") ]]; then
            sed -i 's/_zoneinfo/#_zoneinfo/' "${PYTHON_DIR}/Modules/Setup.local"
            sed -i 's/_decimal/#_decimal/' "${PYTHON_DIR}/Modules/Setup.local"
        fi
    fi

    export CC="clang --target=wasm32-wasi"
    export CFLAGS="-g -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
        -I$INCLUDE_DIR -I${WASIX_DIR}/include -isystem ${WASIX_DIR}/include \
        -I${WASI_SDK_PATH}/share/wasi-sysroot/include -I${PROJECT_DIR}/docker/include \
        -I${WASI_EXT_LIB_DIR}/c_lib/ \
        --sysroot=${WASI_SDK_PATH}/share/wasi-sysroot"
    export CPPFLAGS="${CFLAGS}"
    export LIBS="${LIBS} -L$LIB_DIR -L${WASIX_DIR} -lwasix \
        -L${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasi -lwasi-emulated-signal \
        -L${WASI_EXT_LIB_DIR}/c_lib/bin -lwasi_ext_lib \
        -L${PROJECT_DIR}/docker/lib --sysroot=${WASI_SDK_PATH}/share/wasi-sysroot"
    export PATH=${PYTHON_DIR}/inst/${PYTHON_VER}/bin:$WORK_DIR/build/bin:${PATH}

    mkdir -p "$WORK_DIR/build/bin"
    echo "wasm-ld ${LIBS} --no-entry \$*" > "$WORK_DIR/build/bin/ld"
    chmod +x "$WORK_DIR/build/bin/ld"
    echo "$(echo "$(which clang)" | xargs dirname)/readelf" > "${WORK_DIR}/build/bin/wasm32-wasi-readelf"
    chmod +x "${WORK_DIR}/build/bin/wasm32-wasi-readelf"

    cp ${WASI_SDK_PATH}/share/misc/config.sub .
    cp ${WASI_SDK_PATH}/share/misc/config.guess .
    autoconf -f
    ./configure --host=wasm32-wasi --build=x86_64-pc-linux-gnu \
                --with-build-python=${PYTHON_DIR}/inst/${PYTHON_VER}/bin/python${PYTHON_VER} \
                --with-ensurepip=no \
                --disable-test-modules \
                --disable-ipv6 --enable-big-digits=30 --with-suffix=.wasm \
                --with-freeze-module=./build/Programs/_freeze_module \
 	       --prefix=${INSTALL_PREFIX}/wasi-python
    make clean
    rm -f python.wasm
    make -j$(nproc)
    make install

    rm -f "${PYTHON_DIR}/Modules/Setup.local"
    echo "out/wasi-python/lib/python${PYTHON_MAJOR}.${PYTHON_MINOR}" "out/wasi-python/lib/python"

    cd $PROJECT_DIR
    ln -s "python${PYTHON_MAJOR}.${PYTHON_MINOR}" "out/wasi-python/lib/python"
}

"$@"
