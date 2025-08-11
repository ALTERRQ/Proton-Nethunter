#!/bin/bash

# Wrap to ckbuild.sh
export WP=${WP:-$(realpath $PWD/../)}

bash build/ckbuild.sh "$@" > >(tee -a log.txt) 2>&1
