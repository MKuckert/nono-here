# Local sandbox defaults. Copied from the template on first provisioning,
# then never touched again by nono-here.sh — edit freely.
#
# SANDBOX_COMMAND is substituted at provisioning time with the harness
# chosen (interactively or via NONO_HERE_HARNESS); the placeholder below
# must be left intact for that substitution to happen.
SANDBOX_COMMAND="__NONO_HERE_SANDBOX_COMMAND__"
SANDBOX_COMMAND_DEFAULTS=(
  --allowed-tools "Grep Glob"
)
