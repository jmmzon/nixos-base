# Bluetooth (BlueZ) with PipeWire audio, and phone calls through a paired
# phone.
#
# With `my.bluetooth.phoneCalls.enable` this machine is the phone's
# hands-free kit: PipeWire's native HFP backend takes the hands-free role and
# serves its telephony API on the session bus (org.pipewire.Telephony), which
# `call` uses to dial, answer and hang up. A WirePlumber rule turns the
# phone's call nodes into a playback and a capture stream, so call audio is
# linked to the default speakers and microphone like any other stream. The
# machine does not offer itself as an A2DP/LE Audio sink then: a phone that
# connected for media would hold the media profile instead of the call one.
{ ... }:
{
  flake.modules.nixos.bluetooth =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.my.bluetooth;
      call = pkgs.writeShellApplication {
        name = "call";
        runtimeInputs = [
          pkgs.systemd # busctl
          pkgs.jq
          pkgs.libnotify
        ];
        text = ''
          svc=org.pipewire.Telephony
          root=/org/pipewire/Telephony
          ag_if=org.pipewire.Telephony.AudioGateway1
          call_if=org.pipewire.Telephony.Call1

          # Without a terminal (a tel: link) messages go to a notification.
          say() {
            if [ -t 2 ]; then
              echo "call: $1" >&2
            else
              notify-send -a Phone -i call-start "Phone" "$1" || true
            fi
          }
          die() {
            say "$1"
            exit 1
          }
          usage() {
            cat <<'EOF'
          usage: call NUMBER        dial NUMBER (or a tel: URI) on the phone
                 call answer        answer the incoming call
                 call hangup        end every call
                 call tones DIGITS  send DTMF tones in the active call
                 call status        the connected phone and its calls
          EOF
          }

          objects() {
            busctl --user --json=short call "$svc" "$1" \
              org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null |
              jq -c '.data[0] // {}'
          }
          gateways() {
            objects "$root" |
              jq -r --arg i "$ag_if" 'to_entries[] | select(.value[$i]) | .key'
          }
          gateway() {
            local ag
            ag=$(gateways | head -n 1)
            [ -n "$ag" ] ||
              die "no phone connected as hands-free (pair and connect it in the Bluetooth panel)"
            echo "$ag"
          }
          # One line per call: path, state, number, name.
          calls() {
            local ag
            for ag in $(gateways); do
              objects "$ag" | jq -r --arg i "$call_if" '
                to_entries[] | select(.value[$i]) | .value[$i] as $c |
                [.key, ($c.State.data // "?"), ($c.LineIdentification.data // ""),
                 ($c.Name.data // "")] | @tsv'
            done
          }
          ag_call() {
            busctl --user call "$svc" "$1" "$ag_if" "''${@:2}" >/dev/null
          }

          # tel:+48%20123-456;phone-context=x → +48123456
          normalize() {
            local n=$1
            n=''${n#tel:}
            n=''${n#//}
            n=''${n%%;*}
            n=''${n//%2B/+}
            n=''${n//%2b/+}
            n=''${n//%20/}
            n=$(printf '%s' "$n" | tr -d ' ()./-')
            [[ $n =~ ^\+?[0-9*#]+$ ]] || die "not a phone number: $1"
            echo "$n"
          }

          case "''${1:-}" in
            "" | -h | --help | help)
              usage
              ;;
            status)
              ags=$(gateways)
              [ -n "$ags" ] || {
                echo "no phone connected as hands-free"
                exit 0
              }
              for ag in $ags; do
                addr=$(busctl --user --json=short get-property "$svc" "$ag" "$ag_if" Address |
                  jq -r '.data')
                echo "phone $addr ($ag)"
              done
              calls | while IFS=$'\t' read -r _ state number name; do
                echo "  $state ''${number:-unknown}''${name:+ ($name)}"
              done
              ;;
            answer)
              path=$(calls | awk -F '\t' '$2 == "incoming" || $2 == "waiting" { print $1; exit }')
              [ -n "$path" ] || die "no incoming call"
              busctl --user call "$svc" "$path" "$call_if" Answer >/dev/null
              ;;
            hangup)
              for ag in $(gateways); do
                ag_call "$ag" HangupAll
              done
              ;;
            tones)
              [[ ''${2:-} =~ ^[0-9*#A-Da-d]+$ ]] || die "usage: call tones DIGITS"
              ag=$(gateway)
              ag_call "$ag" SendTones s "$2"
              ;;
            *)
              number=$(normalize "$1")
              ag=$(gateway)
              ag_call "$ag" Dial s "$number" || die "the phone refused to dial $number"
              say "calling $number"
              ;;
          esac
        '';
      };
    in
    lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          hardware.bluetooth = {
            enable = true;
            powerOnBoot = true;
          };
        }
        (lib.mkIf cfg.phoneCalls.enable {
          environment.systemPackages = [ call ];
          services.pipewire.wireplumber.extraConfig."51-bluetooth-phone-calls" = {
            "monitor.bluez.properties" = {
              "bluez5.hfphsp-backend" = "native";
              "bluez5.roles" = [
                "a2dp_source"
                "bap_source"
                "hsp_hs"
                "hsp_ag"
                "hfp_hf"
                "hfp_ag"
              ];
              "bluez5.telephony-dbus-service" = true;
            };
            # The phone's call nodes (profile headset-audio-gateway) become a
            # playback stream (its voice) and a capture stream (ours), which
            # the linking policy connects to the default sink and source.
            "monitor.bluez.rules" = [
              {
                matches = [
                  {
                    "node.name" = "~bluez_input.*";
                    "api.bluez5.profile" = "headset-audio-gateway";
                  }
                ];
                actions.update-props = {
                  "media.class" = "Stream/Output/Audio";
                  "media.role" = "Phone";
                  "node.autoconnect" = true;
                };
              }
              {
                matches = [
                  {
                    "node.name" = "~bluez_output.*";
                    "api.bluez5.profile" = "headset-audio-gateway";
                  }
                ];
                actions.update-props = {
                  "media.class" = "Stream/Input/Audio";
                  "media.role" = "Phone";
                  "node.autoconnect" = true;
                };
              }
            ];
          };
        })
      ]
    );

  flake.modules.homeManager.bluetooth =
    { lib, osConfig, ... }:
    lib.mkIf osConfig.my.bluetooth.phoneCalls.enable {
      xdg.desktopEntries.phone-call = {
        name = "Phone call";
        comment = "Dial through the connected phone";
        exec = "call %u";
        icon = "call-start";
        noDisplay = true;
        mimeType = [ "x-scheme-handler/tel" ];
      };
      xdg.mimeApps.defaultApplications."x-scheme-handler/tel" = [ "phone-call.desktop" ];
    };
}
