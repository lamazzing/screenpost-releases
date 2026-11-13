#!/usr/bin/env bash
# Fresh-Mac release check for ScreenPost. Designed for a GitHub-hosted macOS runner (passwordless sudo,
# a logged-in GUI session). It modifies TCC and /Applications, so do NOT run it on a machine you care about.
# It never connects X, never posts, never buys. See e2e/README.md.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ART="${ARTIFACTS_DIR:-$PWD/artifacts}"
SPDRIVE="${SPDRIVE:-$HERE/spdrive/.build/release/spdrive}"
BUNDLE_ID="com.luca.screenpost"
APP="/Applications/ScreenPost.app"
REPO="${GITHUB_REPOSITORY:-lamazzing/screenpost-releases}"
SITE_URL="${SITE_URL:-https://screenpost.app/download}"
WORK="${RUNNER_TEMP:-/tmp}/sp-release-check"
DESKTOP="$HOME/Desktop"
PRE_GRANT_CHECK="${PRE_GRANT_CHECK:-1}"

mkdir -p "$ART" "$WORK" "$DESKTOP"
LOG="$ART/release-check.log"
SPLOG="$ART/spdrive.log"
REPORT="$ART/report.md"
: >"$LOG"; : >"$SPLOG"
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
N=0; FAILS=0

OSVER="$(sw_vers -productVersion)"; OSMAJOR="${OSVER%%.*}"; ARCH="$(uname -m)"
{
  echo "# ScreenPost fresh-Mac release check"
  echo
  echo "- Runner: macOS $OSVER ($ARCH), $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "- Repo: $REPO"
  echo
  echo "| # | Step | Result | Screenshot |"
  echo "|---|------|--------|------------|"
} >"$REPORT"

log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-48; }
shot() { screencapture -x "$ART/$1" >>"$LOG" 2>&1 || true; }

# step "name" cmd...   runs cmd, records pass/fail + a screenshot. Returns the cmd status.
step() {
  local name="$1"; shift
  N=$((N+1))
  local file; file="$(printf '%02d-%s.png' "$N" "$(slug "$name")")"
  log "STEP $N: $name"
  local rc=0
  "$@" >>"$LOG" 2>&1 || rc=$?
  shot "$file"
  if [ $rc -eq 0 ]; then
    echo "| $N | $name | PASS | [$file]($file) |" >>"$REPORT"; log "  PASS"
  else
    echo "| $N | $name | **FAIL** | [$file]($file) |" >>"$REPORT"; FAILS=$((FAILS+1)); log "  FAIL (rc=$rc)"
  fi
  return $rc
}
# critical step: abort the scenario on failure
crit() { step "$@" || finish "aborted: critical step failed"; }

sp() { echo "+ spdrive $*" >>"$SPLOG"; "$SPDRIVE" "$@" >>"$SPLOG" 2>&1; local rc=$?; [ $rc -ne 0 ] && tail -n 40 "$SPLOG" >>"$LOG"; return $rc; }

spdump() { local out="$1"; shift; "$SPDRIVE" dump "$@" >"$out" 2>&1 || true; }

# Some macOS versions put a system consent dialog in front (e.g. the macOS 15 "bypass the system private window picker"
# prompt). Press its Allow button if one is up. Only ever presses "Allow" in system UI processes.
dismiss_system_dialog() {
  local n
  for n in UserNotificationCenter CoreServicesUIAgent "Control Center" replayd SystemUIServer; do
    if "$SPDRIVE" press "Allow" --process "$n" --timeout 1 >>"$SPLOG" 2>&1; then echo "dismissed system dialog from $n"; return 0; fi
  done
  return 1
}

finish() {
  log "finishing: $1"
  pkill -x ScreenPost >/dev/null 2>&1 || true
  sudo log show --start "$START_TS" --predicate 'process == "ScreenPost" OR subsystem CONTAINS "screenpost"' --info --debug --style compact >"$ART/app-log.txt" 2>&1 || true
  {
    echo
    [ -f "$ART/version.txt" ] && cat "$ART/version.txt"
    if [ "$FAILS" -eq 0 ]; then echo "**Result: PASS** ($N steps)"; else echo "**Result: FAIL** ($FAILS of $N steps failed)"; fi
    echo "Note: $1"
  } >>"$REPORT"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >>"$GITHUB_STEP_SUMMARY"
  [ "$FAILS" -eq 0 ] && exit 0 || exit 1
}

# ---------------------------------------------------------------- 1. download + verify

download_and_verify() {
  mkdir -p "$WORK/site" "$WORK/gh"
  curl -fSL --retry 3 -o "$WORK/site/ScreenPost.zip" "$SITE_URL" || return 1
  GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" gh release download --repo "$REPO" --pattern ScreenPost.zip --dir "$WORK/gh" --clobber || return 1
  local a b
  a="$(shasum -a 256 "$WORK/site/ScreenPost.zip" | cut -d' ' -f1)"
  b="$(shasum -a 256 "$WORK/gh/ScreenPost.zip" | cut -d' ' -f1)"
  echo "site  sha256: $a ($(stat -f %z "$WORK/site/ScreenPost.zip") bytes)"
  echo "github sha256: $b ($(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null))"
  [ "$a" = "$b" ] || { echo "MISMATCH: $SITE_URL differs from the latest GitHub release asset"; return 1; }
}

unpack_and_verify() {
  rm -rf "$WORK/unz"; mkdir -p "$WORK/unz"
  ditto -x -k "$WORK/site/ScreenPost.zip" "$WORK/unz" || return 1
  local app="$WORK/unz/ScreenPost.app"
  [ -d "$app" ] || { echo "ScreenPost.app missing in zip"; ls "$WORK/unz"; return 1; }
  codesign --verify --deep --strict --verbose=2 "$app" || return 1
  local out; out="$(spctl -a -t exec -vv "$app" 2>&1)"; echo "$out"
  echo "$out" | grep -q "accepted" || return 1
  echo "$out" | grep -qi "Notarized" || { echo "not reported as Notarized"; return 1; }
}

install_app() {
  sudo rm -rf "$APP"
  sudo ditto "$WORK/unz/ScreenPost.app" "$APP" || return 1
  sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  local v b
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  echo "installed ScreenPost $v (build $b)"
  echo "- App: ScreenPost **$v** (build $b)" >>"$ART/version.txt"
}

# ---------------------------------------------------------------- 2. permissions (TCC)

SYS_DB="/Library/Application Support/com.apple.TCC/TCC.db"
USER_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

tcc_insert() { # db service client client_type csreq_hex
  local db="$1" svc="$2" client="$3" ctype="$4" csreq="${5:-}"
  [ -f "$db" ] || return 0
  local cols names vals
  cols=",$(sudo sqlite3 "$db" "select group_concat(name) from pragma_table_info('access');"),"
  has() { case "$cols" in *",$1,"*) return 0;; *) return 1;; esac; }
  names="service,client,client_type"; vals="'$svc','$client',$ctype"
  if has auth_value; then names="$names,auth_value,auth_reason,auth_version"; vals="$vals,2,3,1"
  else names="$names,allowed,prompt_count"; vals="$vals,1,1"; fi
  if has csreq; then names="$names,csreq"; if [ -n "$csreq" ]; then vals="$vals,X'$csreq'"; else vals="$vals,NULL"; fi; fi
  has flags && { names="$names,flags"; vals="$vals,0"; }
  has last_modified && { names="$names,last_modified"; vals="$vals,CAST(strftime('%s','now') AS INTEGER)"; }
  sudo sqlite3 "$db" "INSERT OR REPLACE INTO access ($names) VALUES ($vals);"
}

grant() { # service client client_type csreq_hex   -> system DB (and user DB, best effort)
  tcc_insert "$SYS_DB" "$1" "$2" "$3" "${4:-}" || echo "WARN: system TCC insert failed for $1 $2"
  tcc_insert "$USER_DB" "$1" "$2" "$3" "${4:-}" 2>/dev/null || true
}

process_chain() { # absolute executable paths of this process's ancestors
  local pid=$$ i=0
  while [ "$pid" -gt 1 ] && [ $i -lt 8 ]; do
    local comm; comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//')"
    case "$comm" in /*) echo "$comm";; esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; [ -z "$pid" ] && break
    i=$((i+1))
  done
}

show_tcc() {
  echo "TCC columns in access table (macOS $OSVER): $(sudo sqlite3 "$SYS_DB" "select count(*) from pragma_table_info('access');") -> $(sudo sqlite3 "$SYS_DB" "select group_concat(name,',') from pragma_table_info('access');")"
  sudo sqlite3 -header "$SYS_DB" "select service,client,client_type,auth_value from access where client like '%screenpost%' or client like '%spdrive%' or client like '%screencapture%' or client='/bin/bash';" 2>&1 || true
}

grant_driver_permissions() {
  echo "csrutil: $(csrutil status 2>&1)"
  local clients=("$SPDRIVE" /bin/bash /bin/zsh /bin/sh /usr/sbin/screencapture /usr/bin/osascript /usr/bin/env)
  while IFS= read -r p; do clients+=("$p"); done < <(process_chain)
  for c in "${clients[@]}"; do
    for svc in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
      grant "$svc" "$c" 1
    done
  done
  sudo killall tccd 2>/dev/null || true
  show_tcc
  sleep 2
  "$SPDRIVE" check || { echo "spdrive is not trusted for Accessibility after the TCC write"; return 1; }
}

app_csreq_hex() {
  local req
  req="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
  [ -n "$req" ] || { echo "no designated requirement" >&2; return 1; }
  echo "$req" | csreq -r- -b "$WORK/app.csreq" || return 1
  xxd -p "$WORK/app.csreq" | tr -d '\n'
}

grant_app_permissions() {
  local hex; hex="$(app_csreq_hex)" || return 1
  echo "csreq blob: ${#hex} hex chars (matches only the genuine signed app)"
  grant kTCCServiceScreenCapture "$BUNDLE_ID" 0 "$hex"
  grant kTCCServiceSystemPolicyDesktopFolder "$BUNDLE_ID" 0 "$hex"
  # macOS 15+ monthly "Allow For One Month" screen capture reminder (replayd). Best effort: pre-approve far in the future.
  if [ "$OSMAJOR" -ge 15 ]; then
    local plist="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
    mkdir -p "$(dirname "$plist")"
    echo "replayd approvals before:"; plutil -p "$plist" 2>&1 || true
    python3 - "$plist" "$APP/Contents/MacOS/ScreenPost" <<'PY'
import plistlib, sys, os, datetime
path, exe = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(path):
    try: d = plistlib.load(open(path, 'rb'))
    except Exception: d = {}
d[exe] = datetime.datetime(2099, 1, 1)
plistlib.dump(d, open(path, 'wb'))
print("replayd approvals:", path, list(d.keys()))
PY
  fi
  sudo killall tccd replayd 2>/dev/null || true
  show_tcc
  sudo sqlite3 "$SYS_DB" "select 1 from access where service='kTCCServiceScreenCapture' and client='$BUNDLE_ID' and auth_value=2;" | grep -q 1 || return 1
  sleep 2
}

screen_capture_works() {
  local f="$WORK/probe.png"; rm -f "$f"
  screencapture -x "$f" || return 1
  [ -s "$f" ] || return 1
  local size; size="$(stat -f %z "$f")"; echo "probe screenshot: $size bytes"
  [ "$size" -gt 20000 ]
}

# ---------------------------------------------------------------- 3. scenario helpers

launch_app() {
  open -a "$APP" || return 1
  sleep 2
  pgrep -x ScreenPost >/dev/null
}
quit_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do pgrep -x ScreenPost >/dev/null || return 0; sleep 1; done
  pkill -x ScreenPost; sleep 1; return 0
}

MARK="$WORK/mark"
new_desktop_png() { # waits for a non-trivial PNG on the Desktop newer than $MARK
  local end=$((SECONDS+${1:-20})) f
  while [ $SECONDS -lt $end ]; do
    f="$(find "$DESKTOP" -maxdepth 1 -name '*.png' -newer "$MARK" -size +10k 2>/dev/null | head -1)"
    if [ -n "$f" ]; then echo "new file: $f ($(stat -f %z "$f") bytes)"; sips -g pixelWidth -g pixelHeight "$f" | tail -2; touch "$MARK"; return 0; fi
    sleep 1
  done
  echo "no new PNG appeared on the Desktop"; ls -la "$DESKTOP"; return 1
}

# ---------------------------------------------------------------- run

log "macOS $OSVER $ARCH; spdrive=$SPDRIVE"
[ -x "$SPDRIVE" ] || { log "spdrive binary not found at $SPDRIVE"; echo "spdrive missing" >>"$REPORT"; exit 2; }

crit "Download site and GitHub release, sha256 match" download_and_verify
crit "Unzip, codesign verify, Gatekeeper notarization" unpack_and_verify
crit "Install to /Applications" install_app
crit "Grant Accessibility and screen capture to the driver (TCC)" grant_driver_permissions
step "Screen capture works for the runner shell" screen_capture_works

# Phase 1: permission screen without the grant.
phase1() {
  launch_app || return 1
  sp wait-window "Welcome to ScreenPost" --timeout 40 || return 1
  sp press "Set up ScreenPost" || return 1
  sp wait-text "Allow Screen Recording" --timeout 10 || return 1
  sp assert-disabled "Continue" || return 1
}
if [ "$PRE_GRANT_CHECK" = "1" ]; then
  step "Onboarding Screen Recording step shown without permission" phase1
  spdump "$ART/dump-screen-recording-step.txt" --window "Welcome"
  quit_app
fi

crit "Grant Screen Recording to ScreenPost (csreq-bound TCC entry)" grant_app_permissions
defaults delete "$BUNDLE_ID" SPOnboardingStep >/dev/null 2>&1 || true
touch "$MARK"

crit "Launch ScreenPost with permission granted" launch_app
crit "Welcome window appears" sp wait-window "Welcome to ScreenPost" --timeout 40
spdump "$ART/dump-welcome.txt" --window "Welcome"

# Resume-tolerant: if phase 1 left the app on step 1, "Set up ScreenPost" is simply absent.
s_welcome() { sp press "Set up ScreenPost" --timeout 4 || sp wait-text "Allow Screen Recording|Screen Recording Allowed" --timeout 10; }
crit "Onboarding: Welcome -> Set up ScreenPost" s_welcome
s_screenrec() { sp wait-text "Screen Recording Allowed" --timeout 25 && sp press "Continue" --timeout 20; }
crit "Onboarding: Screen Recording shows allowed, Continue" s_screenrec
s_hotkeys() { sp wait-text "Your capture shortcuts|Your shortcuts" --timeout 10 && sp assert-exists "Skip the test|skip the test" && sp press "Continue"; }
crit "Onboarding: Shortcuts" s_hotkeys
s_overlay() { sp wait-text "quick-access overlay" --timeout 10 && sp press "Continue"; }
crit "Onboarding: Quick-access overlay" s_overlay
s_connectx() {
  sp wait-text "Connect X" --timeout 10 || return 1
  sp assert-exists "Skip for now" || return 1
  sp press "Skip for now" --timeout 10   # never connect X
}
crit "Onboarding: Connect X, skip for now" s_connectx
s_ai() {
  sp wait-text "Set up AI" --timeout 10 || return 1
  sp press "Continue|Start with free uses for now" --role button   # free uses, no key
}
crit "Onboarding: Set up AI, continue with free uses" s_ai
s_done() { sp wait-text "ready" --timeout 10 && sp assert-exists "Take your first capture"; }
crit "Onboarding: Done step reached" s_done

# "Take your first capture" opens History and starts an area selection; drag a region.
s_first_capture() {
  sp press "Take your first capture" || return 1
  sleep 2
  sp drag 300 250 900 650 || return 1
  sleep 3
  dismiss_system_dialog || true
  sleep 2
  "$SPDRIVE" windows >"$ART/windows-after-capture.txt" 2>&1 || true
  spdump "$ART/dump-after-first-capture.txt"
  sp wait-text "Save to Desktop|Saved to Desktop|Copied" --timeout 3 || true
  sp assert-exists "Edit" --role button
}
crit "Finish onboarding, first capture by area drag" s_first_capture

s_edit_save() {
  sp press "Edit" --role button --timeout 15 || return 1
  sp wait-window "Screenshot" --timeout 20 || return 1
  spdump "$ART/dump-editor.txt" --window "Screenshot"
  sp press "Save to Desktop" --timeout 20 || return 1
  new_desktop_png 20
}
step "Capture card -> Edit -> Save to Desktop writes a PNG" s_edit_save
step "Close the editor" sp press "Done" --timeout 10

s_full_capture() {
  sp menu-extra "Full screen|Fullscreen|Capture Full Screen" || return 1
  sleep 3
  dismiss_system_dialog || true
  sleep 2
  spdump "$ART/dump-capture-card.txt"
  sp assert-exists "Edit" --role button --timeout 15
}
step "Full-screen capture via the menu bar item shows the capture card" s_full_capture

s_card_save() { sp press "Save" --role button --timeout 15 && new_desktop_png 20; }
step "Capture card Save writes a PNG to the Desktop" s_card_save

s_history() {
  sp menu-extra "History…|History" || return 1
  sp wait-window "ScreenPost" --timeout 15 || return 1
  sp assert-exists "Edit|Open capture" --window "ScreenPost" || return 1
  sp assert-exists "Copy" --window "ScreenPost" || return 1
  sp assert-exists "Share Link|Copy Link" --window "ScreenPost" || return 1
  sp assert-exists "Post to X" --window "ScreenPost"
}
step "History shows capture card actions" s_history
spdump "$ART/dump-history.txt" --window "ScreenPost"

finish "scenario complete"
