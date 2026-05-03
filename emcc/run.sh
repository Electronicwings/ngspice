#!/bin/bash

# Function to handle errors
handle_error() {
    echo "Error: $1" >&2
    exit 1
}

echo "Entrypoint script is Running..."

NGSPICE_HOME="https://github.com/danchitnis/ngspice-sf-mirror"
#NGSPICE_HOME="https://git.code.sf.net/p/ngspice/ngspice"

echo -e "Ngspice git repository is $NGSPICE_HOME\n"

cd /opt || handle_error "Failed to change directory to /opt"
git clone https://github.com/emscripten-core/emsdk.git || handle_error "Failed to clone emsdk repository"
cd emsdk || handle_error "Failed to change directory to emsdk"
./emsdk install 4.0.7 || handle_error "Failed to install 4.0.7 emsdk"
./emsdk activate 4.0.7 || handle_error "Failed to activate 4.0.7 emsdk"
source ./emsdk_env.sh || handle_error "Failed to source emsdk environment"

echo -e "\n"
echo -e "Installing ngspice...\n"

cd /opt || handle_error "Failed to change directory to /opt"

git clone $NGSPICE_HOME ngspice-ngspice || handle_error "Failed to clone ngspice repository"

cd ngspice-ngspice || handle_error "Failed to change directory to ngspice-ngspice"

#https://www.cyberciti.biz/faq/how-to-use-sed-to-find-and-replace-text-in-files-in-linux-unix-shell/
#https://sourceforge.net/p/ngspice/patches/99/
#https://sed.js.org/
sed -i 's/-Wno-unused-but-set-variable/-Wno-unused-const-variable/g' ./configure.ac || handle_error "Failed to modify configure.ac (1)"
sed -i 's/AC_CHECK_FUNCS(\[time getrusage\])/AC_CHECK_FUNCS(\[time\])/g' ./configure.ac || handle_error "Failed to modify configure.ac (2)"

./autogen.sh || handle_error "Failed to run autogen.sh"
mkdir release || handle_error "Failed to create release directory"
cd release || handle_error "Failed to change directory to release"

emconfigure ../configure --disable-debug --with-readline=no --disable-openmp --disable-xspice \
    --with-ngshared \
    || handle_error "Failed to run emconfigure"

wait

emmake make || handle_error "Failed to run emmake make"

wait

mkdir -p /mnt/build || handle_error "Failed to create /mnt/build directory"

# Copy any ngspice library artifacts libtool produced (.a, .so, .la)
echo "=== Searching for ngspice library artifacts ==="
find . -name "libngspice*" -type f 2>/dev/null
find . -name "libngspice*" -type f -exec cp {} /mnt/build/ \;

# Copy the shared-API header (consumer needs this to #include <sharedspice.h>)
cp ../src/include/ngspice/sharedspice.h /mnt/build/ || handle_error "Failed to copy sharedspice.h"

# List what we produced
echo "=== /mnt/build contents ==="
ls -la /mnt/build/

echo -e "\n"
echo -e "This script has completed successfully\n"






