#!/usr/bin/env bash
#
# flutterrun.sh — équivalent Linux de flutterrun.bat
#
# Enchaîne : détection du téléphone USB -> bascule ADB en Wi-Fi -> scrcpy ->
# flutter run, sans configuration manuelle.
#
# Usage : ./flutterrun.sh [options] [-- arguments pour flutter run]
#
set -u
set -o pipefail

ADB="${ADB:-adb}"
SCRCPY="${SCRCPY:-scrcpy}"
FLUTTER="${FLUTTER:-flutter}"

PORT="${PORT:-5555}"
SERIAL=""
START_SCRCPY=1
START_FLUTTER=1
DISCONNECT_AFTER=0
LIST_ONLY=0
WATCH=0
WATCH_DEBOUNCE="0.4"
WATCH_DIRS=()
RUN_TMPDIR=""
PIDFILE=""
WATCH_FIFO=""
WATCHER_PID=""
WATCH_LOOP_PID=""
FLUTTER_ARGS=()
PS3="Choix : "

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR]  %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
FlutterRun (Linux) — lancer scrcpy + flutter run sur un téléphone Android en Wi-Fi

Usage :
  $0 [options] [-- arguments flutter]

Options :
  -h, --help          Afficher cette aide
  -l, --list          Lister les appareils adb et quitter
  -s, --serial ID     Utiliser cet appareil (serial USB ou IP:port)
  -p, --port N        Port ADB TCP (défaut : $PORT)
      --no-scrcpy     Ne pas lancer scrcpy
      --no-flutter    Ne pas lancer flutter run
      --disconnect    Déconnecter l'appareil Wi-Fi à la fin
      --watch         Hot reload automatique à chaque sauvegarde
                      (nécessite inotify-tools)
      --watch-dir DIR Dossier surveillé (défaut : lib), répétable
      --watch-debounce S
                      Regroupement des sauvegardes rapprochées (défaut : $WATCH_DEBOUNCE s)
      --              Tout ce qui suit est passé à flutter run

Exemples :
  $0
  $0 --watch
  $0 --no-scrcpy
  $0 --serial 192.168.1.42:5555
  $0 -- --release

Variables d'environnement :
  ADB, SCRCPY, FLUTTER, PORT
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -l|--list)
                LIST_ONLY=1
                ;;
            -s|--serial)
                [ $# -ge 2 ] || die "L'option $1 attend une valeur."
                SERIAL="$2"
                shift
                ;;
            -p|--port)
                [ $# -ge 2 ] || die "L'option $1 attend une valeur."
                PORT="$2"
                shift
                ;;
            --no-scrcpy)
                START_SCRCPY=0
                ;;
            --no-flutter)
                START_FLUTTER=0
                ;;
            --disconnect)
                DISCONNECT_AFTER=1
                ;;
            --watch)
                WATCH=1
                ;;
            --watch-dir)
                [ $# -ge 2 ] || die "L'option $1 attend une valeur."
                WATCH_DIRS+=("$2")
                shift
                ;;
            --watch-debounce)
                [ $# -ge 2 ] || die "L'option $1 attend une valeur."
                WATCH_DEBOUNCE="$2"
                shift
                ;;
            --)
                shift
                FLUTTER_ARGS=("$@")
                break
                ;;
            *)
                die "Option inconnue : $1 (voir --help)"
                ;;
        esac
        shift
    done

    case "$PORT" in
        ''|*[!0-9]*)
            die "Port invalide : $PORT"
            ;;
    esac
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        die "Port invalide : $PORT (attendu : 1-65535)"
    fi

    if [ "$WATCH" -eq 1 ] && [ "$START_FLUTTER" -eq 0 ]; then
        die "--watch nécessite flutter run (incompatible avec --no-flutter)."
    fi

    if [[ ! "$WATCH_DEBOUNCE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        die "Délai de debounce invalide : $WATCH_DEBOUNCE"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "Commande introuvable : $1. Installe-la puis réessaie."
}

# Affiche "serial<TAB>state" pour chaque appareil adb.
list_device_lines() {
    "$ADB" devices 2>/dev/null | awk '
        /^List of devices attached/ { seen = 1; next }
        seen && NF {
            serial = $1
            state = $0
            sub(/^[^ \t]+[ \t]+/, "", state)
            sub(/\r$/, "", state)
            print serial "\t" state
        }'
}

adbs_has_device() {
    local target="$1"
    list_device_lines | awk -F '\t' -v s="$target" '
        $1 == s && $2 == "device" { found = 1 }
        END { exit(found ? 0 : 1) }'
}

is_ipv4() {
    [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

collect_devices() {
    WIFI_DEVS=()
    USB_DEVS=()
    BAD_DEVS=()

    local serial state
    while IFS=$'\t' read -r serial state; do
        [ -n "$serial" ] || continue
        case "$state" in
            device)
                if [[ "$serial" =~ :[0-9]+$ ]]; then
                    WIFI_DEVS+=("$serial")
                elif [[ "$serial" == emulator-* ]]; then
                    : # les émulateurs ne passent pas par USB -> Wi-Fi
                else
                    USB_DEVS+=("$serial")
                fi
                ;;
            *)
                BAD_DEVS+=("$serial ($state)")
                ;;
        esac
    done < <(list_device_lines)
}

# pick_device <libellé> <appareils...>
# Affiche l'appareil choisi. Retourne 1 si --serial ne correspond à rien,
# 2 si plusieurs appareils et pas de terminal interactif.
pick_device() {
    local label="$1"
    shift
    local -a items=("$@")

    if [ -n "$SERIAL" ]; then
        local s
        for s in "${items[@]}"; do
            if [ "$s" = "$SERIAL" ]; then
                printf '%s\n' "$s"
                return 0
            fi
        done
        return 1
    fi

    if [ ${#items[@]} -eq 1 ]; then
        printf '%s\n' "${items[0]}"
        return 0
    fi

    if [ ! -t 0 ]; then
        err "Plusieurs $label détectés. Utilise --serial pour en choisir un :"
        printf '  %s\n' "${items[@]}" >&2
        return 2
    fi

    info "Plusieurs $label détectés :"
    local s
    select s in "${items[@]}"; do
        if [ -n "$s" ]; then
            printf '%s\n' "$s"
            return 0
        fi
    done
    return 1
}

get_wifi_ip() {
    local serial="$1"
    local ip=""

    # 1) Interface Wi-Fi classique
    ip=$("$ADB" -s "$serial" shell ip -f inet addr show wlan0 2>/dev/null \
        | tr -d '\r' \
        | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')

    # 2) Autre interface wlan (certains appareils)
    if ! is_ipv4 "$ip"; then
        ip=$("$ADB" -s "$serial" shell ip -f inet addr show wlan1 2>/dev/null \
            | tr -d '\r' \
            | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
    fi

    # 3) Route utilisée pour joindre Internet
    if ! is_ipv4 "$ip"; then
        ip=$("$ADB" -s "$serial" shell ip route get 8.8.8.8 2>/dev/null \
            | tr -d '\r' \
            | awk '/wlan/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    fi

    # 4) Route par défaut (uniquement si elle passe par une interface Wi-Fi)
    if ! is_ipv4 "$ip"; then
        ip=$("$ADB" -s "$serial" shell ip route 2>/dev/null \
            | tr -d '\r' \
            | awk '/^default/ && /wlan/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    fi

    # 5) Ancienne propriété DHCP
    if ! is_ipv4 "$ip"; then
        ip=$("$ADB" -s "$serial" shell getprop dhcp.wlan0.ipaddress 2>/dev/null \
            | tr -d '\r ')
    fi

    if is_ipv4 "$ip" && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "0.0.0.0" ]; then
        printf '%s\n' "$ip"
        return 0
    fi
    return 1
}

connect_with_retry() {
    local target="$1"
    local out=""
    local i

    for i in 1 2 3 4 5 6 7 8; do
        out=$("$ADB" connect "$target" 2>&1) || true
        if adbs_has_device "$target"; then
            [ -n "$out" ] && info "$out"
            return 0
        fi
        sleep 1
    done

    [ -n "$out" ] && err "Dernière réponse d'adb : $out"
    return 1
}

start_scrcpy() {
    local device="$1"
    local safe logfile pid

    if command -v pgrep >/dev/null 2>&1 && pgrep -x scrcpy >/dev/null 2>&1; then
        if pgrep -a -x scrcpy 2>/dev/null | grep -F -- "$device" >/dev/null; then
            info "scrcpy est déjà lancé pour $device."
            return 0
        fi
        info "Une instance de scrcpy est déjà ouverte ; lancement pour $device."
    fi

    safe=$(printf '%s' "$device" | tr ':/.' '___')
    logfile="${TMPDIR:-/tmp}/fluttercast-scrcpy-${safe}.log"

    info "Lancement de scrcpy -s $device (log : $logfile)"
    ADB="$ADB" nohup "$SCRCPY" -s "$device" >"$logfile" 2>&1 &
    pid=$!

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        ok "scrcpy démarré (PID $pid)."
    else
        warn "scrcpy s'est arrêté immédiatement. Dernières lignes du log :"
        tail -n 15 "$logfile" >&2 || true
        return 1
    fi
}

trigger_hot_reload() {
    local path="$1"
    local pid=""

    if [ ! -s "$PIDFILE" ]; then
        warn "Modification de $path détectée, mais Flutter n'est pas encore prêt."
        return 0
    fi

    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        warn "Processus Flutter introuvable ; hot reload ignoré."
        return 0
    fi

    info "Modification : ${path#"$PWD"/} → hot reload"
    kill -USR1 "$pid" 2>/dev/null \
        || warn "Impossible d'envoyer SIGUSR1 à Flutter (PID $pid)."
}

watch_loop() {
    local path=""
    local last=""

    while IFS= read -r path; do
        case "$path" in
            *.dart) ;;
            *) continue ;;
        esac
        case "$path" in
            */.dart_tool/*|*/build/*|*/.git/*) continue ;;
            *.g.dart|*.freezed.dart) continue ;;
        esac

        last="$path"

        # Regroupe les sauvegardes rapprochées (formatage, build_runner, etc.)
        while IFS= read -r -t "$WATCH_DEBOUNCE" path; do
            case "$path" in
                *.dart) last="$path" ;;
            esac
        done

        trigger_hot_reload "$last"
    done
}

start_watcher() {
    local -a dirs=("$@")

    RUN_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/flutterrun.XXXXXX") || return 1
    PIDFILE="$RUN_TMPDIR/flutter.pid"
    WATCH_FIFO="$RUN_TMPDIR/events.fifo"
    rm -f "$PIDFILE"
    mkfifo "$WATCH_FIFO" || return 1

    # Lecteur : debounce puis SIGUSR1
    watch_loop <"$WATCH_FIFO" &
    WATCH_LOOP_PID=$!

    # Émetteur : événements inotify sur les fichiers .dart
    inotifywait -m -r -q \
        -e close_write -e create -e moved_to -e delete \
        --format '%w%f' \
        --exclude '(^|/)(build|\.dart_tool|\.git)(/|$)' \
        "${dirs[@]}" >"$WATCH_FIFO" 2>/dev/null &
    WATCHER_PID=$!

    sleep 0.3
    if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
        return 1
    fi
    return 0
}

cleanup() {
    trap - EXIT INT TERM

    if [ -n "$WATCH_LOOP_PID" ] && kill -0 "$WATCH_LOOP_PID" 2>/dev/null; then
        kill "$WATCH_LOOP_PID" 2>/dev/null || true
    fi
    if [ -n "$WATCHER_PID" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        kill "$WATCHER_PID" 2>/dev/null || true
    fi

    [ -n "$WATCH_LOOP_PID" ] && wait "$WATCH_LOOP_PID" 2>/dev/null || true
    [ -n "$WATCHER_PID" ] && wait "$WATCHER_PID" 2>/dev/null || true

    if [ -n "$RUN_TMPDIR" ]; then
        rm -rf "$RUN_TMPDIR"
    fi

    RUN_TMPDIR=""
    PIDFILE=""
    WATCH_FIFO=""
}

main() {
    parse_args "$@"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    require_cmd "$ADB"

    "$ADB" start-server >/dev/null 2>&1 \
        || die "Impossible de démarrer le serveur adb."

    collect_devices

    if [ "$LIST_ONLY" -eq 1 ]; then
        printf 'Appareils adb :\n'
        list_device_lines | while IFS=$'\t' read -r s st; do
            printf '  %-32s %s\n' "$s" "$st"
        done
        if [ ${#BAD_DEVS[@]} -gt 0 ]; then
            printf 'Non utilisables :\n'
            printf '  %s\n' "${BAD_DEVS[@]}"
        fi
        exit 0
    fi

    if [ "$START_FLUTTER" -eq 1 ]; then
        require_cmd "$FLUTTER"
    fi
    if [ "$START_SCRCPY" -eq 1 ]; then
        require_cmd "$SCRCPY"
    fi

    if [ "$WATCH" -eq 1 ]; then
        command -v inotifywait >/dev/null 2>&1 \
            || die "inotifywait introuvable. Installe-le avec : sudo apt install inotify-tools"
    fi

    if [ "$START_FLUTTER" -eq 1 ] && [ ! -f pubspec.yaml ]; then
        die "Aucun pubspec.yaml dans $(pwd). Lance ce script depuis la racine d'un projet Flutter."
    fi

    local d=""
    if [ "$WATCH" -eq 1 ]; then
        if [ ${#WATCH_DIRS[@]} -eq 0 ]; then
            if [ -d lib ]; then
                WATCH_DIRS=("lib")
            else
                WATCH_DIRS=(".")
            fi
        fi
        for d in "${WATCH_DIRS[@]}"; do
            [ -d "$d" ] || die "Dossier à surveiller introuvable : $d"
        done
    fi

    local device=""
    local usb=""
    local ip=""
    local out=""

    if [ -n "$SERIAL" ]; then
        if [[ "$SERIAL" =~ :[0-9]+$ ]]; then
            adbs_has_device "$SERIAL" \
                || die "L'appareil '$SERIAL' n'est pas connecté (état 'device'). Vérifie 'adb devices'."
            device="$SERIAL"
        else
            adbs_has_device "$SERIAL" \
                || die "L'appareil '$SERIAL' n'est pas connecté (état 'device'). Vérifie 'adb devices'."
            usb="$SERIAL"
        fi
    elif [ ${#WIFI_DEVS[@]} -gt 0 ]; then
        device=$(pick_device "appareils Wi-Fi" "${WIFI_DEVS[@]}") || exit 1
    elif [ ${#USB_DEVS[@]} -gt 0 ]; then
        usb=$(pick_device "appareils USB" "${USB_DEVS[@]}") || exit 1
    fi

    if [ -z "$device" ] && [ -z "$usb" ]; then
        err "Aucun téléphone utilisable détecté."
        if [ ${#BAD_DEVS[@]} -gt 0 ]; then
            err "Appareil(s) détecté(s) mais non autorisé(s) ou non prêt(s) :"
            printf '  %s\n' "${BAD_DEVS[@]}" >&2
            err "Accepte la popup « Autoriser le débogage USB » sur le téléphone."
        else
            err "Branche le téléphone en USB, active le débogage USB, puis réessaie."
        fi
        exit 1
    fi

    if [ -n "$usb" ]; then
        ok "Téléphone USB : $usb"

        info "Recherche de l'adresse IP Wi-Fi..."
        if ! ip=$(get_wifi_ip "$usb"); then
            die "Impossible de trouver l'IP Wi-Fi. Vérifie que le Wi-Fi du téléphone est activé et connecté au même réseau que le PC."
        fi
        ok "IP Wi-Fi : $ip"

        info "Activation du mode TCP/IP sur le port $PORT..."
        if ! out=$("$ADB" -s "$usb" tcpip "$PORT" 2>&1); then
            die "Échec de 'adb tcpip $PORT' : $out"
        fi
        [ -n "$out" ] && info "$out"

        device="$ip:$PORT"

        info "Connexion à $device..."
        if ! connect_with_retry "$device"; then
            die "Connexion Wi-Fi impossible. Vérifie que le téléphone et le PC sont sur le même réseau, et qu'aucun pare-feu ne bloque le port $PORT."
        fi
        ok "Connecté en Wi-Fi : $device"
        info "Tu peux débrancher le câble USB."
    else
        ok "Déjà connecté en Wi-Fi : $device"
    fi

    if [ "$START_SCRCPY" -eq 1 ]; then
        start_scrcpy "$device" || true
    fi

    if [ "$WATCH" -eq 1 ]; then
        info "Surveillance de : ${WATCH_DIRS[*]} (hot reload auto, debounce ${WATCH_DEBOUNCE}s)"
        if ! start_watcher "${WATCH_DIRS[@]}"; then
            die "Impossible de démarrer la surveillance. Vérifie l'installation de inotify-tools."
        fi
        ok "Hot reload automatique actif : sauvegarde un fichier .dart pour recharger l'app."
    fi

    local rc=0
    if [ "$START_FLUTTER" -eq 1 ]; then
        local -a cmd=("$FLUTTER" run -d "$device")
        if [ "$WATCH" -eq 1 ]; then
            cmd+=(--pid-file "$PIDFILE")
        fi
        cmd+=("${FLUTTER_ARGS[@]}")
        if [ "$WATCH" -eq 1 ]; then
            info "flutter run -d $device (PID écrit dans $PIDFILE)"
        else
            info "flutter run -d $device"
        fi
        "${cmd[@]}"
        rc=$?
    else
        info "Mode sans flutter run (--no-flutter)."
    fi

    if [ "$DISCONNECT_AFTER" -eq 1 ]; then
        "$ADB" disconnect "$device" >/dev/null 2>&1 || true
        info "Déconnecté : $device"
    fi

    exit "$rc"
}

main "$@"
