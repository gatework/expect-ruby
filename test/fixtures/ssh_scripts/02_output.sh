set -eu
printf 'STDOUT_FIRST\n'
printf 'STDERR_SECOND\n' >&2
printf '中文输出：日志验证\n'
printf 'STDOUT_LAST\n'
