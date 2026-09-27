#!/bin/zsh

# Launch a packaged app with an isolated, disposable Application Support root.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    print -u2 -r -- "Usage: Scripts/ui_smoke.sh [path/to/LumaChat.app]"
    exit 2
fi

script_directory="${0:A:h}"
project_root="${script_directory:h}"
app_bundle="${1:-${project_root}/dist/LumaChat.app}"
app_executable="${app_bundle}/Contents/MacOS/LumaChat"
capability="${app_bundle}/Contents/Resources/UISmokeProfileCapability.txt"
profile_parent="${project_root}/tmp"

if [[ ! -f "${app_executable}" || ! -x "${app_executable}" ]]; then
    print -u2 -r -- "Packaged app executable not found: ${app_executable}"
    exit 1
fi
if [[ ! -f "${capability}" || -L "${capability}"
      || "$(/bin/cat "${capability}")" != "LumaChat UI smoke profile v1" ]]; then
    print -u2 -r -- "App bundle does not support isolated UI smoke: ${app_bundle}"
    exit 1
fi
if [[ -L "${profile_parent}" ]]; then
    print -u2 -r -- "Refusing a symlinked smoke profile parent: ${profile_parent}"
    exit 1
fi
/bin/mkdir -p "${profile_parent}"

profile_root=$(/usr/bin/mktemp -d "${profile_parent}/ui-smoke-profile.XXXXXXXX")
marker="${profile_root}/.lumachat-ui-smoke-profile"
/bin/chmod 700 "${profile_root}"
print -r -- "LumaChat UI smoke profile v1" > "${marker}"
/bin/chmod 600 "${marker}"

cleanup() {
    # Only remove the exact temporary profile created by this invocation.
    if [[ "${profile_root:h}" == "${profile_parent}"
          && "${profile_root:t}" == ui-smoke-profile.*
          && -d "${profile_root}" && ! -L "${profile_root}"
          && -f "${marker}" && ! -L "${marker}"
          && "$(/bin/cat "${marker}")" == "LumaChat UI smoke profile v1" ]]; then
        /bin/rm -rf -- "${profile_root}"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print -r -- "UI smoke profile: ${profile_root}"
if ! verification=$(
    LUMACHAT_UI_SMOKE_PROFILE="${profile_root}" \
        "${app_executable}" --verify-ui-smoke-profile
); then
    print -u2 -r -- "App binary did not verify the isolated UI smoke profile."
    exit 1
fi
if [[ "${verification}" != "LumaChat UI smoke profile v1 ready" ]]; then
    print -u2 -r -- "App binary returned an unexpected UI smoke profile response."
    exit 1
fi
LUMACHAT_UI_SMOKE_PROFILE="${profile_root}" "${app_executable}"
