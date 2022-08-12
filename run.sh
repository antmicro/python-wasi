#!/bin/bash

WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
PROJECT_DIR=$(pwd)
PYTHON_TAG="3.10.6"
DEPS_DIR="$PROJECT_DIR/deps"
WORK_DIR="$PROJECT_DIR/work"
PYTHON_DIR="$WORK_DIR/cpython-$PYTHON_TAG"
WASIX_DIR="$DEPS_DIR/wasix"
LIB_DIR="$PROJECT_DIR/docker/lib"
INCLUDE_DIR="$PROJECT_DIR/docker/include"
INSTALL_PREFIX="$PROJECT_DIR/out"

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

    if [[ ! -d $WASIX_DIR ]]; then
        echo "Downloading wasix... $WASIX_DIR"
        git clone https://github.com/singlestore-labs/wasix $WASIX_DIR
        cd $WASIX_DIR && make
        cd $PROJECT_DIR
    fi

    if [[ ! -d $WASI_SDK_PATH ]]; then
        echo "Downloading wasi sdk..."
        wget -P $DEPS_DIR \
            https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-16/wasi-sdk-16.0-linux.tar.gz
        tar zxf $DEPS_DIR/wasi-sdk-16.0-linux.tar.gz -C $DEPS_DIR
        rm $DEPS_DIR/wasi-sdk-16.0-linux.tar.gz && \
        mv $DEPS_DIR/wasi-sdk-16.0 $DEPS_DIR/wasi-sdk
        export WASI_SDK_PATH=$DEPS_DIR/wasi-sdk
        export PATH=$PATH:$WASI_SDK_PATH/bin
    fi

    if [[ ! -d $WABT_PATH ]]; then
        echo "Downloading wabt..."
        wget -P $DEPS_DIR -q \
            https://github.com/WebAssembly/wabt/releases/download/1.0.29/wabt-1.0.29-ubuntu.tar.gz
        tar -xf $DEPS_DIR/wabt-1.0.29-ubuntu.tar.gz -C $DEPS_DIR
        rm $DEPS_DIR/wabt-1.0.29-ubuntu.tar.gz
    fi
}

build() {
    PYTHON_VER=$(grep '^VERSION=' "${PYTHON_DIR}/configure" | cut -d= -f2)
    PYTHON_MAJOR=$(echo $PYTHON_VER | cut -d. -f1)
    PYTHON_MINOR=$(echo $PYTHON_VER | cut -d. -f2)

    if [[ ! -d "${PYTHON_DIR}/inst/${PYTHON_VER}" ]]; then
        cd "${PYTHON_DIR}"
        rm -f Modules/Setup.local
        ./configure --disable-test-modules \
    	        --with-ensurepip=no \
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

        # Apply patches
        patch -p1 -N -r- < ${PROJECT_DIR}/patches/configure.ac.patch

        if [[ -f "${PYTHON_DIR}/Modules/_zoneinfo.c" ]]; then
            patch -p1 -N -r- < ${PROJECT_DIR}/patches/_zoneinfo.c.patch
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
        --sysroot=${WASI_SDK_PATH}/share/wasi-sysroot"
    export CPPFLAGS="${CFLAGS}"
    export LIBS="${LIBS} -L$LIB_DIR -L${WASIX_DIR} -lwasix \
        -L${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasi -lwasi-emulated-signal \
        -L${PROJECT_DIR}/docker/lib --sysroot=${WASI_SDK_PATH}/share/wasi-sysroot"
    export PATH=${PYTHON_DIR}/inst/${PYTHON_VER}/bin:$WORK_DIR/build/bin:${PATH}

    mkdir -p "$WORK_DIR/build/bin"
    echo "wasm-ld ${LIBS} --no-entry \$*" > "$WORK_DIR/build/bin/ld"
    chmod +x "$WORK_DIR/build/bin/ld"
    echo "$(echo "$(which clang)" | xargs dirname)/readelf" > "${WORK_DIR}/build/bin/wasm32-wasi-readelf"
    chmod +x "${WORK_DIR}/build/bin/wasm32-wasi-readelf"

    cp ${WASI_SDK_PATH}/share/misc/config.sub . && \
       cp ${WASI_SDK_PATH}/share/misc/config.guess . && \
       autoconf -f && \
       ./configure --host=wasm32-wasi --build=x86_64-pc-linux-gnu \
                   --with-build-python=${PYTHON_DIR}/inst/${PYTHON_VER}/bin/python${PYTHON_VER} \
                   --with-ensurepip=no \
                   --disable-ipv6 --enable-big-digits=30 --with-suffix=.wasm \
                   --with-freeze-module=./build/Programs/_freeze_module \
    	       --prefix=${INSTALL_PREFIX}/wasi-python && \
       make clean && \
       rm -f python.wasm && \
       make -j && \
       make install

    rm -f "${PYTHON_DIR}/Modules/Setup.local"

    cd $PROJECT_DIR
}

"$@"
