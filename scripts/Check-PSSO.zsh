#!/bin/zsh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Check-PSSO v2.5 (Recurring) - enable "AutoFill from Company Portal" after Platform SSO registration,
# optionally enforce the main AutoFill toggle and an AutoFill-provider allowlist.
# Author - Satish Singhi
# Based on: microsoft/shell-intune-samples "Set Autofill Automatically after PSSO Registration"
# Target: macOS 26 (Tahoe) and macOS 27 (Golden Gate). Runs on macOS 13+.
#
# Changes vs v2.4:
#   - ENABLE_BEFORE_PSSO=true: elects AutoFill from Company Portal even before Platform SSO registration
#     completes (existing Macs receiving the PSSO policy later), aiming to pre-empt the registration
#     AutoFill prompt. A marker written before registration is tagged '|pre-psso' and never honoured by the
#     fast path, so the script re-checks until registration completes. false = v2.4 behaviour.
#
# Changes in v2.4 (vs v2.3):
#   - Main toggle "AutoFill Passwords and Passkeys" = user preference com.apple.Safari AutoFillPasswords
#     (confirmed on device; an Intune Preference file forcing it does not move the toggle). Logged every
#     full run. ENFORCE_MODE=true: if off, set it as the user, restart the user's cfprefsd, read back.
#     Never overrides an MDM-forced AutoFillPasswords=false.
#   - Provider allowlist: extension point read at runtime from the Company Portal appex Info.plist; all
#     registered providers logged. Allowed = Company Portal + Apple (com.apple.*) + EXTRA_ALLOWED.
#     ENFORCE_MODE=true disables any other ENABLED provider (pluginkit -e ignore); false = audit only.
#   - Safari restriction check reads AutoFillPasswordsInSafari (key Intune device restrictions deliver).
#     Informational: it does not block Company Portal passkeys.
#   - Sections run independently (Platform SSO not complete no longer skips toggle/allowlist checks).
# Retained: per-user marker keyed to macOS build + CP version, allowPasswordAutoFill=false honoured,
#   Microsoft Team ID check, pluginkit -a nudge, no blocking waits, always exit 0, single-line commands.
#
# Intune (Devices > macOS > Shell scripts): run as signed-in user = No, frequency = every 15 minutes.
# Upload this file directly - do not copy/paste its contents.

# ===== Configuration =====
verbose=false
ENFORCE_MODE=false
ENABLE_BEFORE_PSSO=true
EXTRA_ALLOWED=()
MS_TEAM_ID="UBF8T346G9"
autofill_id="com.microsoft.CompanyPortalMac.Mac-Autofill-Extension"
cp_app_path="/Applications/Company Portal.app"
autofill_bundle="$cp_app_path/Contents/PlugIns/AutofillExtensionMacOS.appex"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/checkPSSO"
logfile="$logandmetadir/Check-PSSO.log"
statedir="$logandmetadir/state"
managed_prefs="/Library/Managed Preferences"

# ===== 0. Console user + fast path (silent) =====
currentUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')
if [[ -z "$currentUser" || "$currentUser" == "loginwindow" ]]; then
    exit 0
fi
currentUID=$(id -u "$currentUser" 2>/dev/null)
if [[ -z "$currentUID" ]]; then
    exit 0
fi

os_build=$(sw_vers -buildVersion)
cp_version=$(/usr/bin/defaults read "$cp_app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
fingerprint="${os_build}|${cp_version}"
markerfile="$statedir/${currentUID}.enabled"

if [[ "$ENFORCE_MODE" != true && -f "$markerfile" && "$(cat "$markerfile" 2>/dev/null)" == "$fingerprint" ]]; then
    exit 0
fi

# ===== Logging and helpers =====
mkdir -p "$logandmetadir" "$statedir" 2>/dev/null
chmod 700 "$statedir" 2>/dev/null
if [[ ! -d "$logandmetadir" ]]; then
    echo "ERROR: Failed to create log directory $logandmetadir"
    exit 0
fi
if [[ -f "$logfile" ]] && (( $(stat -f%z "$logfile" 2>/dev/null || echo 0) > 1048576 )); then
    mv "$logfile" "${logfile}.old"
fi
exec > >(tee -a "$logfile") 2>&1

log() { echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | $1"; }
asuser() { launchctl asuser "$currentUID" sudo -u "$currentUser" "$@"; }
pk_line() { asuser pluginkit -m -v 2>/dev/null | grep -F "$autofill_id" | head -1; }
state_of() { local c="${1:0:1}"; [[ "$c" == [[:space:]] ]] && c=""; printf '%s' "$c"; }
pk_state_char() { state_of "$(pk_line)"; }
id_of() { print -r -- "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\(/) { sub(/\(.*/, "", $i); print $i; exit } }'; }
team_id() { codesign -dv --verbose=2 "$1" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }'; }
plist_val() { [[ -f "$2" ]] && /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }
write_marker() { local m="$fingerprint"; [[ "$psso_ok" != true ]] && m="${fingerprint}|pre-psso"; printf '%s\n' "$m" > "$markerfile"; chmod 600 "$markerfile" 2>/dev/null; }
is_allowed() { [[ "$1" == "$autofill_id" || "$1" == com.apple.* || ${EXTRA_ALLOWED[(Ie)$1]} -gt 0 ]]; }

log "--- Check-PSSO v2.5 run start ---"
log "Console user: $currentUser (UID $currentUID) | state fingerprint: $fingerprint | enforce: $ENFORCE_MODE | enable before PSSO: $ENABLE_BEFORE_PSSO"

# ===== 1. macOS version =====
macos_version=$(sw_vers -productVersion)
macos_major=${macos_version%%.*}
if (( macos_major < 13 )); then
    log "macOS $macos_version: Platform SSO requires macOS 13 or later. Nothing to do."
    exit 0
fi
if (( macos_major != 26 && macos_major != 27 )); then
    log "NOTE: macOS $macos_version is outside the validated targets (26, 27). Continuing."
fi
if [[ "$verbose" == true ]]; then
    log "macOS $macos_version (Build $os_build) | Hardware: $(sysctl -n hw.model) | Running as: $(whoami)"
fi

# ===== 2. Is AutoFill allowed? (never override MDM) =====
for plist in "$managed_prefs/com.apple.applicationaccess.plist" "$managed_prefs/$currentUser/com.apple.applicationaccess.plist"; do
    if [[ "$(plist_val allowPasswordAutoFill "$plist")" == "false" ]]; then
        log "BLOCKED: MDM restriction allowPasswordAutoFill=false in $plist. No AutoFill changes made. Will re-check next run."
        exit 0
    fi
done
mdm_master_forced_off=false
for plist in "$managed_prefs/com.apple.Safari.plist" "$managed_prefs/$currentUser/com.apple.Safari.plist"; do
    if [[ "$(plist_val AutoFillPasswordsInSafari "$plist")" == "false" ]]; then
        log "INFO: Safari AutoFillPasswordsInSafari=false in $plist (Safari password AutoFill restricted; Company Portal passkeys unaffected)."
    fi
    if [[ "$(plist_val AutoFillPasswords "$plist")" == "false" ]]; then
        mdm_master_forced_off=true
        log "INFO: MDM forces AutoFillPasswords=false in $plist - main toggle will not be changed."
    fi
done
log "AutoFill allowed: no allowPasswordAutoFill restriction found"

# ===== 3. Company Portal present, current and genuine =====
if [[ ! -d "$cp_app_path" ]]; then
    log "Company Portal NOT installed at $cp_app_path. Will retry on next scheduled run."
    exit 0
fi
if [[ ! -d "$autofill_bundle" ]]; then
    log "Company Portal $cp_version has no AutoFill extension (AutofillExtensionMacOS.appex). Update Company Portal. Will retry."
    exit 0
fi
cp_team=$(team_id "$cp_app_path")
ext_team=$(team_id "$autofill_bundle")
if [[ "$cp_team" != "$MS_TEAM_ID" || "$ext_team" != "$MS_TEAM_ID" ]]; then
    log "SECURITY: Company Portal signature check failed (app team '${cp_team:-none}', extension team '${ext_team:-none}', expected $MS_TEAM_ID). No changes made."
    exit 0
fi
log "Company Portal $cp_version installed; app and AutoFill extension signed by Microsoft ($MS_TEAM_ID)"

# ===== 4. Platform SSO registration =====
psso_ok=false
if command -v app-sso &>/dev/null; then
    psso_output=$(asuser app-sso platform -s 2>&1)
    psso_rc=$?
    if [[ "$verbose" == true ]]; then
        log "app-sso exit code: $psso_rc"
        echo "$psso_output" | while IFS= read -r line; do log "  $line"; done
    fi
    reg_true=$(printf '%s\n' "$psso_output" | grep -Eic '"registrationCompleted"[[:space:]]*:[[:space:]]*true')
    if [[ $psso_rc -eq 0 ]] && (( reg_true >= 1 )); then
        psso_ok=true
        log "Platform SSO registration: COMPLETE ($reg_true registrationCompleted=true entries)"
    else
        log "Platform SSO registration: NOT COMPLETE. Will re-check next run."
    fi
else
    log "app-sso not found. Will re-check next run."
fi

# ===== 5. Company Portal AutoFill extension =====
if [[ "$psso_ok" != true && "$ENABLE_BEFORE_PSSO" != true ]]; then
    log "Company Portal AutoFill step skipped until Platform SSO registration completes (ENABLE_BEFORE_PSSO=false)."
fi
if [[ "$psso_ok" == true || "$ENABLE_BEFORE_PSSO" == true ]]; then
    [[ "$psso_ok" != true ]] && log "ENABLE_BEFORE_PSSO: enabling Company Portal AutoFill ahead of Platform SSO registration."
    registration_line=$(pk_line)
    if [[ -z "$registration_line" ]]; then
        log "AutoFill extension not registered for $currentUser - asking pluginkit to register it..."
        asuser pluginkit -a "$autofill_bundle" 2>&1
        sleep 2
        registration_line=$(pk_line)
    fi
    if [[ -z "$registration_line" ]]; then
        log "AutoFill extension still not registered. Will retry on next scheduled run."
    else
        log "Extension registered: $registration_line"
        pk_state=$(pk_state_char)
        if [[ "$pk_state" == "+" ]]; then
            log "AutoFill from Company Portal: already ENABLED."
            write_marker
        else
            log "Enabling AutoFill from Company Portal (current state: '${pk_state:-unset}')..."
            cp_enabled=false
            for attempt in 1 2 3; do
                asuser pluginkit -e use -i "$autofill_id" 2>&1
                sleep 2
                pk_state=$(pk_state_char)
                if [[ "$pk_state" == "+" ]]; then
                    cp_enabled=true
                    break
                fi
                log "Enable attempt $attempt/3 - state '${pk_state:-unset}', retrying..."
                sleep 3
            done
            if [[ "$cp_enabled" == true ]]; then
                log "AutoFill from Company Portal: ENABLED (attempt $attempt). State recorded."
                write_marker
            else
                log "AutoFill from Company Portal: FAILED TO ENABLE (last state: '${pk_state:-unset}'). Will retry on next scheduled run."
            fi
        fi
    fi
fi

# ===== 6. Main toggle "AutoFill Passwords and Passkeys" (com.apple.Safari AutoFillPasswords) =====
master=$(asuser defaults read com.apple.Safari AutoFillPasswords 2>/dev/null)
log "Main AutoFill toggle (AutoFillPasswords): ${master:-unset}"
if [[ "$master" != "1" ]]; then
    if [[ "$mdm_master_forced_off" == true ]]; then
        log "Main toggle: left OFF (forced by MDM)."
    elif [[ "$ENFORCE_MODE" == true ]]; then
        asuser defaults write com.apple.Safari AutoFillPasswords -bool true 2>&1
        asuser killall cfprefsd 2>/dev/null
        sleep 2
        master=$(asuser defaults read com.apple.Safari AutoFillPasswords 2>/dev/null)
        if [[ "$master" == "1" ]]; then
            log "Main toggle: ENABLED (read-back 1)."
        else
            log "Main toggle: FAILED to enable (read-back '${master:-unset}'). Will retry on next scheduled run."
        fi
    else
        log "Main toggle: OFF - not changed (ENFORCE_MODE=false)."
    fi
fi

# ===== 7. AutoFill provider allowlist =====
ext_point=$(plist_val NSExtension:NSExtensionPointIdentifier "$autofill_bundle/Contents/Info.plist")
if [[ -z "$ext_point" ]]; then
    log "Allowlist: could not read NSExtensionPointIdentifier from the Company Portal extension. Skipped."
    exit 0
fi
log "Allowlist: AutoFill provider extension point = $ext_point"
providers=$(asuser pluginkit -m -v -p "$ext_point" 2>/dev/null)
violations=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(id_of "$line")
    [[ -z "$pid" ]] && continue
    st=$(state_of "$line")
    if is_allowed "$pid"; then
        log "  ALLOWED     [${st:-unset}] $pid"
        continue
    fi
    log "  NOT ALLOWED [${st:-unset}] $pid"
    if [[ "$st" == "+" ]]; then
        (( violations++ ))
        if [[ "$ENFORCE_MODE" == true ]]; then
            asuser pluginkit -e ignore -i "$pid" 2>&1
            sleep 1
            new_st=$(state_of "$(asuser pluginkit -m -v -p "$ext_point" 2>/dev/null | grep -F "$pid" | head -1)")
            log "    -> disabled (state now '${new_st:-unset}')"
        else
            log "    -> enabled but not on allowlist (audit only, ENFORCE_MODE=false)"
        fi
    fi
done <<< "$providers"
log "Allowlist: $violations enabled non-allowlisted provider(s) found."
exit 0
