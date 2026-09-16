#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
info_plist="${project_root}/AppBundle/Info.plist"
entitlements_plist="${project_root}/AppBundle/LumaChat.entitlements"
privacy_manifest="${project_root}/AppBundle/PrivacyInfo.xcprivacy"
archive_builder="${project_root}/Scripts/release_archive.py"
update_feed_builder="${project_root}/Scripts/generate_update_feed.py"
release_metadata_builder="${project_root}/Scripts/generate_release_metadata.py"
security_auditor="${project_root}/Scripts/security_audit.py"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}")
architecture=$(/usr/bin/uname -m)
release_root="${project_root}/tmp/release-${version}-${architecture}"
scratch_path="${release_root}/scratch"
cache_path="${release_root}/cache"
config_path="${release_root}/config"
security_path="${release_root}/security"
system_temporary_path="${release_root}/system-tmp"
xdg_cache_path="${release_root}/xdg-cache"
xdg_config_path="${release_root}/xdg-config"
clang_module_cache="${release_root}/clang-module-cache"
swift_module_cache="${release_root}/swift-module-cache"
test_app_support="${release_root}/test-app-support"
archive_verification_directory="${release_root}/archive-verification"
archive_member_list="${release_root}/archive-members.txt"
notary_upload_path="${release_root}/LumaChat-notary-upload.zip"
notary_submit_log="${release_root}/notary-submit.json"
notary_developer_log="${release_root}/notary-developer-log.json"
signed_entitlements_log="${release_root}/signed-entitlements.plist"
distribution_directory="${project_root}/dist"
application_name="LumaChat.app"
application_path="${distribution_directory}/${application_name}"
archive_path="${distribution_directory}/LumaChat-${version}-${architecture}.zip"
release_mode="${LUMACHAT_RELEASE_MODE:-development}"
signing_identity="${LUMACHAT_SIGNING_IDENTITY:--}"
notary_profile="${LUMACHAT_NOTARY_PROFILE:-}"
update_feed_url="${LUMACHAT_UPDATE_FEED_URL:-}"
update_archive_url="${LUMACHAT_UPDATE_ARCHIVE_URL:-}"
update_public_key="${LUMACHAT_UPDATE_PUBLIC_KEY:-}"
update_private_key_path="${LUMACHAT_UPDATE_PRIVATE_KEY_PATH:-}"
signing_team_identifier="${LUMACHAT_SIGNING_TEAM_ID:-}"
release_notes_url="${LUMACHAT_RELEASE_NOTES_URL:-}"
builtin_plugin_id="com.lumachat.artifact-workflows"
builtin_plugin_source="${project_root}/Extensions/Builtin/${builtin_plugin_id}"
builtin_plugin_destination="${application_path}/Contents/Resources/BuiltinPlugins/${builtin_plugin_id}"
artifact_skills=(pdf document spreadsheet presentation image visualization site)
builtin_plugin_expected_entry_count=16

case "${release_mode}" in
    development)
        if [[ "${signing_identity}" != "-" ]]; then
            print -u2 -r -- "Development release mode accepts ad-hoc identity '-' only."
            exit 1
        fi
        ;;
    production)
        required_release_values=(
            "${signing_identity}"
            "${notary_profile}"
            "${update_feed_url}"
            "${update_archive_url}"
            "${update_public_key}"
            "${update_private_key_path}"
            "${signing_team_identifier}"
        )
        for required_value in "${required_release_values[@]}"; do
            if [[ -z "${required_value}" || "${required_value}" == *$'\n'* || "${required_value}" == *$'\r'* ]]; then
                print -u2 -r -- "Production release credentials/configuration are incomplete or malformed."
                exit 1
            fi
        done
        if [[ "${signing_identity}" != "Developer ID Application: "* ]]; then
            print -u2 -r -- "Production requires an exact Developer ID Application identity."
            exit 1
        fi
        if [[ ! "${signing_team_identifier}" =~ '^[A-Z0-9]{10}$' ]]; then
            print -u2 -r -- "LUMACHAT_SIGNING_TEAM_ID must be a 10-character Apple Team ID."
            exit 1
        fi
        if [[ ! -f "${update_private_key_path}" || -L "${update_private_key_path}" ]]; then
            print -u2 -r -- "The Ed25519 update private key must be a regular non-symlink file."
            exit 1
        fi
        if [[ -z "${SOURCE_DATE_EPOCH:-}" || ! "${SOURCE_DATE_EPOCH}" =~ '^[0-9]{10,}$' ]]; then
            print -u2 -r -- "Production requires numeric SOURCE_DATE_EPOCH for reproducible metadata."
            exit 1
        fi
        if ! /usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/grep -F -- "\"${signing_identity}\"" >/dev/null; then
            print -u2 -r -- "The configured Developer ID identity is not available in Keychain."
            exit 1
        fi
        ;;
    *)
        print -u2 -r -- "LUMACHAT_RELEASE_MODE must be development or production."
        exit 1
        ;;
esac

for required_file in \
    "${entitlements_plist}" \
    "${privacy_manifest}" \
    "${update_feed_builder}" \
    "${release_metadata_builder}" \
    "${security_auditor}"; do
    [[ -f "${required_file}" && ! -L "${required_file}" ]]
done

if /usr/bin/find "${distribution_directory}" -name '._*' -print -quit 2>/dev/null \
    | /usr/bin/grep -q .; then
    print -u2 -r -- "Distribution directory contains AppleDouble files and was preserved."
    exit 1
fi

# The bundled catalog resolves this exact source layout in development, while
# release builds copy the same payload beneath Contents/Resources/BuiltinPlugins.
# Fail before a long build if either side of that contract has drifted.
[[ -d "${builtin_plugin_source}" && ! -L "${builtin_plugin_source}" ]]
[[ -d "${builtin_plugin_source}/skills" && ! -L "${builtin_plugin_source}/skills" ]]
[[ -f "${builtin_plugin_source}/plugin.json" && ! -L "${builtin_plugin_source}/plugin.json" ]]
for skill_name in "${artifact_skills[@]}"; do
    [[ -d "${builtin_plugin_source}/skills/${skill_name}" \
        && ! -L "${builtin_plugin_source}/skills/${skill_name}" ]]
    [[ -f "${builtin_plugin_source}/skills/${skill_name}/SKILL.md" \
        && ! -L "${builtin_plugin_source}/skills/${skill_name}/SKILL.md" ]]
done
if /usr/bin/find "${builtin_plugin_source}" -name '._*' -print -quit \
    | /usr/bin/grep -q .; then
    print -u2 -r -- "Bundled Artifact Workflow source contains AppleDouble metadata files."
    exit 1
fi
if /usr/bin/find "${builtin_plugin_source}" -type l -print -quit \
    | /usr/bin/grep -q .; then
    print -u2 -r -- "Bundled Artifact Workflow source contains a symlink."
    exit 1
fi
builtin_plugin_entry_count=$(
    /usr/bin/find "${builtin_plugin_source}" -mindepth 1 -print \
        | /usr/bin/wc -l \
        | /usr/bin/tr -d '[:space:]'
)
if [[ "${builtin_plugin_entry_count}" != "${builtin_plugin_expected_entry_count}" ]]; then
    print -u2 -r -- "Bundled Artifact Workflow source layout does not match the release contract."
    exit 1
fi

if [[ -e "${release_root}" ]]; then
    if /usr/bin/find "${release_root}" -name '._*' -print -quit \
        | /usr/bin/grep -q .; then
        print -u2 -r -- "Existing release staging contains AppleDouble files and was preserved."
        exit 1
    fi
    /bin/rm -rf "${release_root}"
fi

/bin/mkdir -p \
    "${scratch_path}" \
    "${cache_path}" \
    "${config_path}" \
    "${security_path}" \
    "${system_temporary_path}" \
    "${xdg_cache_path}" \
    "${xdg_config_path}" \
    "${clang_module_cache}" \
    "${swift_module_cache}" \
    "${test_app_support}" \
    "${distribution_directory}"

# A release archive is never produced from an unverified source tree. Tests use
# the same project-local, isolated toolchain paths as the release build.
env \
    TMPDIR="${system_temporary_path}" \
    LUMACHAT_RELEASE_TEST_ROOT="${system_temporary_path}" \
    PYTHONDONTWRITEBYTECODE=1 \
    /usr/bin/python3 "${project_root}/Scripts/test_release_archive.py"

env \
    TMPDIR="${system_temporary_path}" \
    TMP="${system_temporary_path}" \
    TEMP="${system_temporary_path}" \
    XDG_CACHE_HOME="${xdg_cache_path}" \
    XDG_CONFIG_HOME="${xdg_config_path}" \
    CLANG_MODULE_CACHE_PATH="${clang_module_cache}" \
    SWIFT_MODULECACHE_PATH="${swift_module_cache}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${swift_module_cache}" \
    LUMACHAT_APP_SUPPORT_PATH="${test_app_support}" \
    LUMACHAT_RUNTIME_TMP_PATH="${project_root}/tmp" \
    swift test \
        --jobs 2 \
        --scratch-path "${scratch_path}" \
        --cache-path "${cache_path}" \
        --config-path "${config_path}" \
        --security-path "${security_path}" \
        --disable-sandbox \
        --disable-automatic-resolution

env \
    TMPDIR="${system_temporary_path}" \
    TMP="${system_temporary_path}" \
    TEMP="${system_temporary_path}" \
    XDG_CACHE_HOME="${xdg_cache_path}" \
    XDG_CONFIG_HOME="${xdg_config_path}" \
    CLANG_MODULE_CACHE_PATH="${clang_module_cache}" \
    SWIFT_MODULECACHE_PATH="${swift_module_cache}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${swift_module_cache}" \
    swift build \
        --jobs 2 \
        --configuration release \
        --scratch-path "${scratch_path}" \
        --cache-path "${cache_path}" \
        --config-path "${config_path}" \
        --security-path "${security_path}" \
        --disable-sandbox \
        --disable-automatic-resolution

if [[ -e "${application_path}" ]]; then
    if /usr/bin/find "${application_path}" -name '._*' -print -quit \
        | /usr/bin/grep -q .; then
        print -u2 -r -- "Existing release app contains AppleDouble files and was preserved."
        exit 1
    fi
    /bin/rm -rf "${application_path}"
fi
/bin/rm -f "${archive_path}"

/bin/mkdir -p \
    "${application_path}/Contents/MacOS" \
    "${application_path}/Contents/Resources/bin" \
    "${builtin_plugin_destination}/skills"
/bin/cp "${scratch_path}/release/LumaChatDesktop" \
    "${application_path}/Contents/MacOS/LumaChat"
/bin/cp "${scratch_path}/release/lumachat" \
    "${application_path}/Contents/Resources/bin/lumachat"
/bin/cp "${scratch_path}/release/lumachat-updater" \
    "${application_path}/Contents/Resources/bin/lumachat-updater"
/bin/cp "${info_plist}" "${application_path}/Contents/Info.plist"
/bin/cp "${project_root}/AppBundle/AppIcon.icns" \
    "${application_path}/Contents/Resources/AppIcon.icns"
/bin/cp "${privacy_manifest}" \
    "${application_path}/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ "${release_mode}" == "production" ]]; then
    /usr/bin/plutil -replace LumaChatUpdateFeedURL \
        -string "${update_feed_url}" "${application_path}/Contents/Info.plist"
    /usr/bin/plutil -replace LumaChatUpdatePublicKey \
        -string "${update_public_key}" "${application_path}/Contents/Info.plist"
    /usr/bin/plutil -replace LumaChatUpdateTeamIdentifier \
        -string "${signing_team_identifier}" "${application_path}/Contents/Info.plist"
fi
/bin/cp "${builtin_plugin_source}/plugin.json" \
    "${builtin_plugin_destination}/plugin.json"
for skill_name in "${artifact_skills[@]}"; do
    /bin/mkdir -p "${builtin_plugin_destination}/skills/${skill_name}"
    /bin/cp "${builtin_plugin_source}/skills/${skill_name}/SKILL.md" \
        "${builtin_plugin_destination}/skills/${skill_name}/SKILL.md"
done
/bin/chmod 755 "${application_path}/Contents/MacOS/LumaChat"
/bin/chmod 755 "${application_path}/Contents/Resources/bin/lumachat"
/bin/chmod 755 "${application_path}/Contents/Resources/bin/lumachat-updater"
/bin/chmod 644 \
    "${application_path}/Contents/Info.plist" \
    "${application_path}/Contents/Resources/AppIcon.icns" \
    "${application_path}/Contents/Resources/PrivacyInfo.xcprivacy" \
    "${builtin_plugin_destination}/plugin.json"
for skill_name in "${artifact_skills[@]}"; do
    /bin/chmod 644 "${builtin_plugin_destination}/skills/${skill_name}/SKILL.md"
done

# Never silently delete AppleDouble files during a release. If the backing
# filesystem materializes them, fail closed so the operator can move the fresh
# staging directory to a metadata-safe volume without losing any file.
if /usr/bin/find "${application_path}" -type f -name '._*' -print -quit \
    | /usr/bin/grep -q .; then
    print -u2 -r -- "Release app staging contains AppleDouble metadata files."
    exit 1
fi
signing_arguments=(--force --options runtime --sign "${signing_identity}")
if [[ "${release_mode}" == "production" ]]; then
    signing_arguments=(--force --options runtime --timestamp --sign "${signing_identity}")
fi
# Sign every nested executable first, then the outer bundle. `--deep` is used
# only for verification; recursive signing can conceal an omitted component.
/usr/bin/codesign "${signing_arguments[@]}" \
    "${application_path}/Contents/Resources/bin/lumachat"
/usr/bin/codesign "${signing_arguments[@]}" \
    "${application_path}/Contents/Resources/bin/lumachat-updater"
/usr/bin/codesign "${signing_arguments[@]}" \
    --entitlements "${entitlements_plist}" \
    "${application_path}"
if /usr/bin/find "${application_path}" -type f -name '._*' -print -quit \
    | /usr/bin/grep -q .; then
    print -u2 -r -- "Code signing materialized AppleDouble metadata files."
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "${application_path}"
/usr/bin/plutil -lint "${application_path}/Contents/Info.plist"
/usr/bin/plutil -lint "${application_path}/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/codesign --display --entitlements :- "${application_path}" \
    > "${signed_entitlements_log}" 2>/dev/null
if /usr/bin/plutil -extract com.apple.security.get-task-allow raw -o - \
    "${signed_entitlements_log}" 2>/dev/null | /usr/bin/grep -qx 'true'; then
    print -u2 -r -- "Distribution signature unexpectedly enables get-task-allow."
    exit 1
fi

if [[ "${release_mode}" == "production" ]]; then
    env PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${archive_builder}" create \
        --source "${application_path}" \
        --archive "${notary_upload_path}"
    /usr/bin/xcrun notarytool submit "${notary_upload_path}" \
        --keychain-profile "${notary_profile}" \
        --wait \
        --output-format json > "${notary_submit_log}"
    notary_status=$(/usr/bin/plutil -extract status raw -o - "${notary_submit_log}")
    notary_submission_id=$(/usr/bin/plutil -extract id raw -o - "${notary_submit_log}")
    [[ -n "${notary_submission_id}" ]]
    /usr/bin/xcrun notarytool log "${notary_submission_id}" \
        --keychain-profile "${notary_profile}" \
        "${notary_developer_log}"
    if [[ "${notary_status}" != "Accepted" ]]; then
        print -u2 -r -- "Apple notarization did not return Accepted; see ${notary_developer_log}."
        exit 1
    fi
    /usr/bin/xcrun stapler staple "${application_path}"
    /usr/bin/xcrun stapler validate "${application_path}"
    /usr/sbin/spctl --assess --type execute --verbose=4 "${application_path}"
fi

env PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${archive_builder}" create \
    --source "${application_path}" \
    --archive "${archive_path}"
/usr/bin/unzip -tq "${archive_path}"
env PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${archive_builder}" verify \
    --source "${application_path}" \
    --archive "${archive_path}"

# Inspect archive member names directly. On filesystems without native extended
# attributes (for example ExFAT), extracting even a clean ZIP can materialize
# `._*` sidecars for filesystem metadata; those files are not archive members.
/usr/bin/unzip -Z1 "${archive_path}" > "${archive_member_list}"
if /usr/bin/grep -Eq '(^|/)\._[^/]*$|(^|/)__MACOSX(/|$)' \
    "${archive_member_list}"; then
    print -u2 -r -- "Archive contains AppleDouble metadata entries."
    exit 1
fi

# CRC alone does not prove that the shipped bundle remains runnable. Extract
# into clean project-local staging and verify the exact archived app again.
/bin/mkdir -p "${archive_verification_directory}"
/usr/bin/unzip -q "${archive_path}" -d "${archive_verification_directory}"
verified_application_path="${archive_verification_directory}/${application_name}"
verified_executable="${verified_application_path}/Contents/MacOS/LumaChat"
verified_cli="${verified_application_path}/Contents/Resources/bin/lumachat"
verified_updater="${verified_application_path}/Contents/Resources/bin/lumachat-updater"
verified_builtin_plugin="${verified_application_path}/Contents/Resources/BuiltinPlugins/${builtin_plugin_id}"
/usr/bin/codesign --verify --deep --strict "${verified_application_path}"
/usr/bin/plutil -lint "${verified_application_path}/Contents/Info.plist"
[[ -x "${verified_executable}" ]]
[[ -x "${verified_cli}" ]]
[[ -x "${verified_updater}" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${verified_application_path}/Contents/Info.plist")" == "LumaChat" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${verified_application_path}/Contents/Info.plist")" == "${version}" ]]
/usr/bin/cmp -s \
    "${builtin_plugin_source}/plugin.json" \
    "${verified_builtin_plugin}/plugin.json"
for skill_name in "${artifact_skills[@]}"; do
    /usr/bin/cmp -s \
        "${builtin_plugin_source}/skills/${skill_name}/SKILL.md" \
        "${verified_builtin_plugin}/skills/${skill_name}/SKILL.md"
done
verified_binary_description=$(/usr/bin/file "${verified_executable}")
[[ "${verified_binary_description}" == *"${architecture}"* ]]
verified_cli_description=$(/usr/bin/file "${verified_cli}")
[[ "${verified_cli_description}" == *"${architecture}"* ]]
verified_updater_description=$(/usr/bin/file "${verified_updater}")
[[ "${verified_updater_description}" == *"${architecture}"* ]]
if [[ "${release_mode}" == "production" ]]; then
    /usr/bin/xcrun stapler validate "${verified_application_path}"
    /usr/sbin/spctl --assess --type execute --verbose=4 "${verified_application_path}"
    verified_team=$(
        /usr/bin/codesign --display --verbose=4 "${verified_application_path}" 2>&1 \
            | /usr/bin/sed -n 's/^TeamIdentifier=//p'
    )
    [[ "${verified_team}" == "${signing_team_identifier}" ]]
fi
if /usr/bin/find "${verified_application_path}" -name '._*' -print -quit \
    | /usr/bin/grep -q .; then
    print -u2 -r -- "Archive verification staging contains AppleDouble metadata files."
    exit 1
fi

binary_architecture=$(/usr/bin/file "${application_path}/Contents/MacOS/LumaChat")
cli_path="${application_path}/Contents/Resources/bin/lumachat"
archive_hash=$(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')
if /usr/bin/find "${distribution_directory}" -maxdepth 1 -type f \
    \( -name "._${application_name}" -o -name "._${archive_path:t}" \) \
    -print -quit | /usr/bin/grep -q .; then
    print -u2 -r -- "Distribution directory contains AppleDouble metadata files."
    exit 1
fi

if [[ "${release_mode}" == "production" ]]; then
    update_feed_arguments=(
        --archive "${archive_path}"
        --application "${application_path}"
        --archive-url "${update_archive_url}"
        --feed-output "${distribution_directory}/update-v1.json"
        --private-key "${update_private_key_path}"
        --public-key-base64 "${update_public_key}"
        --version "${version}"
        --build "${build_number}"
        --minimum-system-version "14.0"
        --bundle-identifier "com.lumachat.desktop"
        --team-identifier "${signing_team_identifier}"
        --architecture "${architecture}"
    )
    if [[ -n "${release_notes_url}" ]]; then
        update_feed_arguments+=(--release-notes-url "${release_notes_url}")
    fi
    env \
        TMPDIR="${system_temporary_path}" \
        PYTHONDONTWRITEBYTECODE=1 \
        SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
        /usr/bin/python3 "${update_feed_builder}" \
            "${update_feed_arguments[@]}"
fi

env \
    PYTHONDONTWRITEBYTECODE=1 \
    TMPDIR="${system_temporary_path}" \
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
    /usr/bin/python3 "${release_metadata_builder}" \
        --project-root "${project_root}" \
        --app "${application_path}" \
        --archive "${archive_path}" \
        --output-directory "${distribution_directory}" \
        --release-mode "${release_mode}" \
        --version "${version}" \
        --build "${build_number}" \
        --architecture "${architecture}"

env PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${security_auditor}" \
    --project-root "${project_root}" \
    --application "${application_path}" \
    --release-mode "${release_mode}" \
    --report "${release_root}/security-audit.json"

print -r -- "Release app: ${application_path}"
print -r -- "Release mode: ${release_mode}"
print -r -- "CLI shim: ${cli_path}"
print -r -- "Release zip: ${archive_path}"
print -r -- "Binary: ${binary_architecture}"
print -r -- "SHA-256: ${archive_hash}"
