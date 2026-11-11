# shellcheck shell=bash
# service-port.sh — die eine Ableitung des OpenCode-Dienst-Ports.
#
# Wird von run.sh, stop-tunnel.command, diagnose.sh und bootstrap.sh gesourct.
# Vier Kopien derselben Funktion waeren genau die stille Drift, die dieses Repo
# sonst vermeidet: Start, Stopp und Diagnose muessen denselben Port treffen, den
# die -R-Bindung benutzt. Wer hier etwas aendert, aendert es fuer alle vier.
#
# Voraussetzung: die .env des Aufrufers ist bereits gesourct (LOCAL_PORT dient
# als Fallback). Massgeblich ist `opencode service status` — es druckt die URL
# des gemeinsamen Dienstes (z.B. http://127.0.0.1:49374, denselben Prozess, an
# dem die TUI per `serve --service` haengt). Whitespace und ein abschliessendes
# "/" werden toleriert, weil das je nach Version variiert.
#
# Rueckgabe: Port als Ziffernfolge, oder leer. Was leer bedeutet, entscheidet
# der Aufrufer: run.sh und stop-tunnel.command brechen ab (eine falsche
# Forward-Signatur raeumt sonst die falsche Menge auf), Diagnose und Bootstrap
# zeigen "unbekannt" und ueberspringen die Port-Pruefung.
service_port() {
  local url port
  url="$(opencode service status 2>/dev/null)" || url=""
  url="$(printf '%s' "$url" | tr -d '[:space:]' | sed 's:/*$::')"
  # Alles hinter dem letzten ":" ist der Port; "http://127.0.0.1" ohne Port
  # landet bei "//127.0.0.1" und faellt unten durch die Ziffernpruefung.
  # Bei gestopptem Dienst druckt `status` wortwoertlich "stopped" — das ist
  # ebenfalls kein Port und landet im Fallback.
  port="${url##*:}"
  case "$port" in ''|*[!0-9]*) port="" ;; esac
  if [ -z "$port" ]; then port="${LOCAL_PORT:-}"; fi
  # Der Fallback wird genauso geprueft wie die Status-Ausgabe: ein Tippfehler in
  # LOCAL_PORT (z.B. "49374x") darf keine falsche Forward-Signatur erzeugen,
  # sondern muss beim Aufrufer als "unbekannt" ankommen.
  case "$port" in *[!0-9]*) port="" ;; esac
  printf '%s' "$port"
}
