# Boot timing history: one row per boot with the firmware's own FPDT
# milestones, systemd's startup split and the BIOS version, so the cost of
# each firmware setting can be compared boot by boot. `boot-timing note
# "<change>"` labels the next boot; `boot-timing` prints the history.
{ ... }:
{
  flake.modules.nixos.boot-timing =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      dir = "/var/lib/boot-timing";
      boot-timing = pkgs.writeShellApplication {
        name = "boot-timing";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.systemd
          pkgs.util-linux
        ];
        text = ''
          # BOOT_TIMING_DIR and BOOT_TIMING_BOOT_ID exist for tests only.
          dir=''${BOOT_TIMING_DIR:-${dir}}
          history=$dir/history.tsv
          label_file=$dir/next-label
          fpdt=/sys/firmware/acpi/fpdt/boot
          header=$(echo "boot_id boot_start bios_version bios_date fw_start loader_load loader_launch ebs_start ebs_end sd_firmware sd_loader sd_kernel sd_initrd sd_userspace sd_graphical prev_shutdown label" | tr ' ' '\t')

          # Microseconds (or nanoseconds with a divisor) as seconds, "-" when unknown.
          secs() { awk -v v="$1" -v d="''${2:-1000000}" 'BEGIN { if (v == "" || v < 0) print "-"; else printf "%.3f\n", v / d }'; }
          fpdt_value() {
            if [ -r "$fpdt/$1" ]; then secs "$(cat "$fpdt/$1")" 1000000000; else echo -; fi
          }
          prop() { systemctl show ''${2:+"$2"} -p "$1" --value 2>/dev/null || true; }
          dmi() { tr '\t' ' ' <"/sys/class/dmi/id/$1" 2>/dev/null || echo -; }

          previous_shutdown() {
            local msgs
            msgs=$(journalctl -b -1 _PID=1 -o cat --no-pager 2>/dev/null |
              grep -E '^Reached target (System Reboot|System Power Off|Kexec|System Halt)' || true)
            case "$msgs" in
              *Reboot*) echo reboot ;;
              *"Power Off"*) echo poweroff ;;
              *Kexec*) echo kexec ;;
              *Halt*) echo halt ;;
              *) echo unknown ;;
            esac
          }

          # One row for the running boot, label column left empty.
          row() {
            local id start fw loader initrd user finish graphical kernel_end
            id=''${BOOT_TIMING_BOOT_ID:-$(tr -d - </proc/sys/kernel/random/boot_id)}
            start=$(date -d "$(systemctl show -p KernelTimestamp --value --timestamp=unix)" '+%F %T' 2>/dev/null || echo -)
            fw=$(prop FirmwareTimestampMonotonic)
            loader=$(prop LoaderTimestampMonotonic)
            initrd=$(prop InitRDTimestampMonotonic)
            user=$(prop UserspaceTimestampMonotonic)
            finish=$(prop FinishTimestampMonotonic)
            graphical=$(prop ActiveEnterTimestampMonotonic graphical.target)
            # Without an initrd the kernel runs until userspace starts.
            if [ "''${initrd:-0}" -gt 0 ]; then kernel_end=$initrd; else kernel_end=$user; fi
            printf '%s\t' \
              "$id" "$start" "$(dmi bios_version)" "$(dmi bios_date)" \
              "$(fpdt_value firmware_start_ns)" "$(fpdt_value bootloader_load_ns)" \
              "$(fpdt_value bootloader_launch_ns)" "$(fpdt_value exitbootservice_start_ns)" \
              "$(fpdt_value exitbootservice_end_ns)"
            if [ "''${fw:-0}" -gt 0 ]; then secs $((fw - loader)); else echo -; fi | tr '\n' '\t'
            if [ "''${loader:-0}" -gt 0 ]; then secs "$loader"; else echo -; fi | tr '\n' '\t'
            secs "$kernel_end" | tr '\n' '\t'
            if [ "''${initrd:-0}" -gt 0 ]; then secs $((user - initrd)); else echo -; fi | tr '\n' '\t'
            if [ "''${finish:-0}" -gt 0 ]; then secs $((finish - user)); else echo -; fi | tr '\n' '\t'
            if [ "''${graphical:-0}" -gt 0 ]; then secs $((graphical - user)); else echo -; fi | tr '\n' '\t'
            previous_shutdown
          }

          # The history as an aligned table, with the change in time to the
          # boot loader launch from the previous row.
          show() {
            local file=$1
            awk -F'\t' -v OFS='\t' '
              NR == 1 { print "boot", "start", "bios", "firmware", "Δfw", "loader", "kernel", "initrd", "user", "graphical", "prev", "label"; next }
              {
                d = "-"
                if ($7 != "-" && prev != "") d = sprintf("%+.3f", $7 - prev)
                if ($7 != "-") prev = $7
                print substr($1, 1, 8), $2, $3, $7, d, $11, $12, $13, $14, $15, $16, ($17 == "" ? "-" : $17)
              }' "$file" | column -t -s "$(printf '\t')"
          }

          capture() {
            mkdir -p "$dir"
            [ -s "$history" ] || printf '%s\n' "$header" >"$history"
            local r id label=""
            r=$(row)
            id=$(cut -f1 <<<"$r")
            if cut -f1 "$history" | grep -qxF "$id"; then
              echo "boot-timing: boot $id already recorded"
              return 0
            fi
            if [ -s "$label_file" ]; then label=$(head -n1 "$label_file" | tr '\t' ' '); fi
            printf '%s\t%s\n' "$r" "$label" >>"$history"
            rm -f "$label_file"
            awk -F'\t' -v id="$id" '$1 == id {
              printf "boot-timing: firmware %s s (loader launch), loader %s s, kernel %s s, initrd %s s, userspace %s s, graphical %s s; prev %s; label %s\n",
                $7, $11, $12, $13, $14, $15, $16, ($17 == "" ? "-" : $17) }' "$history"
          }

          case "''${1:-show}" in
            show)
              if [ -s "$history" ]; then show "$history"; else echo "boot-timing: no boots recorded yet"; fi
              ;;
            now)
              tmp=$(mktemp)
              trap 'rm -f "$tmp"' EXIT
              { printf '%s\n' "$header"; printf '%s\t\n' "$(row)"; } >"$tmp"
              show "$tmp"
              ;;
            note)
              shift
              if [ $# -eq 0 ]; then
                if [ -s "$label_file" ]; then cat "$label_file"; else echo "boot-timing: no label set"; fi
              elif [ "$*" = "--clear" ]; then
                rm -f "$label_file"
              else
                printf '%s\n' "$*" >"$label_file"
                echo "boot-timing: next boot will be labelled: $*"
              fi
              ;;
            capture) capture ;;
            *)
              echo "usage: boot-timing [show | now | note [LABEL | --clear] | capture]" >&2
              exit 2
              ;;
          esac
        '';
      };
    in
    lib.mkIf config.my.bootTiming.enable {
      environment.systemPackages = [ boot-timing ];

      # Group-writable by wheel so `boot-timing note` needs no sudo.
      systemd.tmpfiles.rules = [ "d ${dir} 2775 root wheel - -" ];

      systemd.services.boot-timing-capture = {
        description = "Record this boot's firmware and systemd timings";
        # Wait for startup to finish so systemd can report userspace time.
        script = ''
          timeout 600 systemctl is-system-running --wait >/dev/null || true
          exec ${lib.getExe boot-timing} capture
        '';
        serviceConfig = {
          Type = "oneshot";
          SyslogIdentifier = "boot-timing";
          UMask = "0002";
          Nice = 10;
        };
      };

      systemd.timers.boot-timing-capture = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnBootSec = "3min";
      };
    };
}
