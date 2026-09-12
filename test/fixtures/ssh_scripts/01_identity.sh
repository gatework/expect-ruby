set -eu
printf 'USER=%s\n' "$(id -un)"
printf 'TTY=%s\n' "$(tty)"
printf 'IDENTITY_OK\n'
