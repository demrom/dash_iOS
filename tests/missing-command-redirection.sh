#!/bin/sh
# Run with Dash and an existing disposable directory; require empty stderr.
set -eu
test_dir=${1:?usage: missing-command-redirection.sh test-directory}
for iteration in 1 2 3; do
	if dash-missing-command >"$test_dir/missing.out" 2>&1; then
		exit 1
	else
		[ "$?" -eq 127 ]
	fi
	IFS= read -r diagnostic <"$test_dir/missing.out"
	case $diagnostic in
		*dash-missing-command:*not\ found) ;;
		*) exit 1 ;;
	esac
	printf 'recovery %s\n' "$iteration"
done
printf 'MISSING_COMMAND_REDIRECTION_OK\n'
