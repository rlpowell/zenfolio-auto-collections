#!/bin/bash

# Error trapping from https://gist.github.com/oldratlee/902ad9a398affca37bfcfab64612e7d1
__error_trapper() {
  local parent_lineno="$1"
  local code="$2"
  local commands="$3"
  echo "error exit status $code, at file $0 on or near line $parent_lineno: $commands"
}
trap '__error_trapper "${LINENO}/${BASH_LINENO}" "$?" "$BASH_COMMAND"' ERR

set -euE -o pipefail

# Cron's path tends to suck
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:$HOME/bin:$HOME/.local/bin

podman build -t rlpowell/zenfolio .

podman run --rm -it -v ~/Dropbox/Portable\ Twin\ Media:/pics:z -v $PWD:/src:z -t rlpowell/zenfolio ruby "$@"
