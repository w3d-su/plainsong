#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
helper_directory="$script_directory/editor-find-f2-capture"

# shellcheck source=editor-find-f2-capture/common.sh
source "$helper_directory/common.sh"
# shellcheck source=editor-find-f2-capture/processes.sh
source "$helper_directory/processes.sh"
# shellcheck source=editor-find-f2-capture/monitor.sh
source "$helper_directory/monitor.sh"
# shellcheck source=editor-find-f2-capture/run.sh
source "$helper_directory/run.sh"

f2_capture_main "$@"
