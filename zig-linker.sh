#!/bin/bash
# Wrapper script to use zig as cross-compilation linker
exec zig cc -target arm-linux-musleabihf "$@"
