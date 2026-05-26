#!/bin/bash

# Wrap to ckbuild.sh
export WP=${WP:-$(realpath $PWD/../)}

# Update repo & Update/install git submodules
git pull
git submodule update --init --recursive

bash build/ckbuild.sh "$@"  > >(tee log.txt) 2>&1
