# Executed by the Nix-built sunshine-output helper.
#
# create: add the stream's virtual output, then disable every other enabled
#   output. Umbriel moves each disabled output's workspaces (layout, columns,
#   floating windows) to the only output left, the stream, and remembers
#   their home.
# remove: enable the outputs `create` disabled, so those workspaces return
#   home, move anything still on the stream to a physical workspace, and
#   destroy the virtual output. Also run when the Sunshine service stops, so a
#   crash never leaves the physical monitors off.
set -euo pipefail

stream_output=sunshine
export UMBRIEL_SOCKET="${UMBRIEL_SOCKET:-${XDG_RUNTIME_DIR:?}/umbriel-${WAYLAND_DISPLAY:-wayland-0}.sock}"
# Outputs `create` disabled, one name per line; lives as long as the session.
state="${XDG_RUNTIME_DIR:?}/sunshine-output.disabled"

has_output() {
  umbriel outputs --json | jq -e --arg name "$1" 'any(.[]; .name == $name)' >/dev/null
}

others_enabled() {
  umbriel outputs --json | jq -r --arg name "$stream_output" \
    '.[] | select(.name != $name and .enabled) | .name'
}

case "${1:-}" in
  create)
    width=${SUNSHINE_CLIENT_WIDTH:-1920}
    height=${SUNSHINE_CLIENT_HEIGHT:-1080}
    fps=${SUNSHINE_CLIENT_FPS:-60}
    [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ && "$fps" =~ ^[0-9]+$ ]] || exit 1
    # Leave an existing stream output alone rather than displacing its windows.
    if ! has_output "$stream_output"; then
      umbriel output-create "$stream_output" "${width}x${height}@${fps}" >/dev/null
    fi
    # Disable only once the stream output is up, so one output stays enabled.
    has_output "$stream_output" || { echo 'Stream output did not appear' >&2; exit 1; }
    mapfile -t disable < <(others_enabled)
    focused=$(umbriel windows --json | jq -r 'first(.[] | select(.focused) | .id) // empty')
    # Append: a second create (reconnect) must not forget the first one's list.
    for output in "${disable[@]}"; do
      printf '%s\n' "$output" >>"$state"
      umbriel msg output-disable "$output"
    done
    # Stay on the workspace in use: it moved to the stream as a new workspace.
    if [[ -n "$focused" ]]; then
      umbriel msg window-focus "$focused" || true
    fi
    ;;
  remove)
    # Bring the physical outputs back first; their workspaces return with them.
    if [[ -s "$state" ]]; then
      mapfile -t restore < <(sort -u "$state")
      for output in "${restore[@]}"; do
        has_output "$output" && umbriel msg output-enable "$output"
      done
    fi
    rm -f "$state"
    # Never leave only the stream: without a record, enable one other output,
    # the physically largest (a real monitor, not a capture or dummy device
    # reporting no size), not all of them, which would wake a disabled one.
    if [[ -z "$(others_enabled)" ]]; then
      fallback=$(umbriel outputs --json | jq -r --arg name "$stream_output" \
        '[.[] | select(.name != $name)]
         | sort_by(-((.physical_size.width_mm // 0) * (.physical_size.height_mm // 0)))
         | first | .name // empty')
      [[ -n "$fallback" ]] && umbriel msg output-enable "$fallback"
    fi
    # What is left on the stream is its own: give the application's undo
    # action time to close its windows before moving the rest.
    for ((attempt=0; attempt<25; attempt++)); do
      windows=$(umbriel windows --json)
      if ! jq -e --arg prefix "$stream_output:" \
        'any(.[]; .workspace | startswith($prefix))' <<<"$windows" >/dev/null; then
        break
      fi
      sleep 0.2
    done
    # Explicitly relocate windows opened on the stream's own workspaces,
    # clearing their remembered output affinity.
    # Disabled outputs still list their workspaces: pick an enabled one. An
    # anonymous workspace is selected by position, a named one by name.
    mapfile -t destination < <(umbriel workspaces --json | jq -r --arg output "$stream_output" \
      --argjson enabled "$(others_enabled | jq -Rn '[inputs]')" \
      '[.[] | select(.output != $output and .active and (.output | IN($enabled[])))]
       | sort_by(.focused | not) | first
       | if . == null then empty
         elif .named then "--name", .name, "--output", .output
         else (.index | tostring), "--output", .output end')
    mapfile -t survivors < <(umbriel windows --json | jq -r --arg prefix "$stream_output:" \
      '.[] | select(.workspace | startswith($prefix)) | .id')
    for window in "${survivors[@]}"; do
      ((${#destination[@]})) || { echo 'No destination for stream windows' >&2; break; }
      umbriel msg window-focus "$window"
      umbriel msg window-move-to-workspace-silent "${destination[@]}"
    done
    if has_output "$stream_output"; then
      umbriel output-destroy "$stream_output" >/dev/null
    fi
    ;;
  *) echo 'Usage: sunshine-output create|remove' >&2; exit 2 ;;
esac
