#!/bin/bash

THIS_SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

set -e

echo
echo "==> Performing step"
ruby "${THIS_SCRIPTDIR}/step.rb" \
	-s "${xamarin_project}" \
	-c "${xamarin_configuration}" \
	-p "${xamarin_platform}" \
	-t "${test_to_run}" \
	-e "${emulator_serial}"
