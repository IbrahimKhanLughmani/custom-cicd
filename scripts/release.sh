#!/bin/zsh
set -euo pipefail

# -----------------------------------------------------------------------------
# Copyright (c) 2025 Ayman Mohammed (GitHub: vymn) for Location Solutions.
# This file is part of the Telematics Workplace Mobile project.
# All rights reserved.
# -----------------------------------------------------------------------------

# Colors and Symbols
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
GRAY="\033[90m"
CHECK="${GREEN}✔${RESET}"
CROSS="${RED}✖${RESET}"
INFO="${BLUE}ℹ${RESET}"
WARN="${YELLOW}⚠${RESET}"
ARROW="${CYAN}➜${RESET}"
BOX="\xF0\x9F\x93\xA6"
UPLOAD="\xF0\x9F\x93\xA4"
ROCKET="\xF0\x9F\x9A\x80"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
SUPPORTED_FLAVORS=("workplacebyls" "workplacebytsphub" "tiabytsp")
SUPPORTED_PLATFORMS=("ios" "android")
VERSION_FILE="version.json"
CHANGELOG_FILE="CHANGELOG.md"
FLUTTER_VERSION="3.29.1"
CREDENTIALS_FILE="" # path of credentials.json file

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
check_fastlane() {
    if ! command -v fastlane &> /dev/null; then
        echo "${WARN} ${YELLOW}Fastlane not found. Installing...${RESET}"
        if command -v gem &> /dev/null; then
            gem install fastlane -N
            echo "${CHECK} ${GREEN}Fastlane installed successfully${RESET}"
        else
            echo "${CROSS} ${RED}Ruby gem command not found. Please install Ruby first:${RESET}"
            echo "  brew install ruby"
            exit 1
        fi
    else
        echo "${INFO} ${BLUE}Fastlane is already installed${RESET}"
    fi
}

check_shorebird() {
    if ! command -v shorebird &> /dev/null; then
        echo "${WARN} ${YELLOW}Shorebird CLI not found. Installing...${RESET}"
        curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh | sh
        echo "${CHECK} ${GREEN}Shorebird CLI installed successfully${RESET}"
    else
        echo "${INFO} ${BLUE}Shorebird CLI is already installed${RESET}"
    fi
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "${WARN} ${YELLOW}jq command not found. Installing...${RESET}"
        brew install jq
        if [ $? -ne 0 ]; then
            echo "${CROSS} ${RED}Failed to install jq. Please install manually:${RESET}"
            echo "  brew install jq"
            exit 1
        fi
        echo "${CHECK} ${GREEN}jq installed successfully${RESET}"
    else
        echo "${INFO} ${BLUE}jq is already installed${RESET}"
    fi
}

print_help() {
    echo "${BOLD}Usage:${RESET}
  ./release.sh <command> [flavor] [platform]

${BOLD}Commands:${RESET}
  ${CYAN}bump <flavor> <platform>${RESET}     ${DIM}Bump version for specific flavor/platform${RESET}
  ${CYAN}bump-all${RESET}                   ${DIM}Bump all flavors/platforms${RESET}
  ${CYAN}release <flavor> <platform>${RESET} ${DIM}Release using Shorebird + Fastlane${RESET}
  ${CYAN}release-all${RESET}               ${DIM}Release all combinations${RESET}
  ${CYAN}--help${RESET}                    ${DIM}Show help${RESET}"
}

append_changelog() {
    local flavor=$1 platform=$2 build_name=$3 build_number=$4
    local date=$(date +%F)
    echo "- [$date] $flavor ($platform): $build_name+$build_number" >> "$CHANGELOG_FILE"
}

update_pubspec_yaml() {
    local name=$1 number=$2
    sed -i '' "s/^[[:space:]]*version:.*$/version: $name+$number/" pubspec.yaml
    echo "${ARROW} Updated ${YELLOW}pubspec.yaml${RESET}"
}

update_codemagic_yaml() {
    local name=$1 number=$2
    if [[ -f codemagic.yaml ]]; then
        sed -i '' "s/BUILD_NAME:.*/BUILD_NAME: \"$name\"/" codemagic.yaml
        sed -i '' "s/BUILD_NUMBER:.*/BUILD_NUMBER: \"$number\"/" codemagic.yaml
        echo "${ARROW} Updated ${YELLOW}codemagic.yaml${RESET}"
    fi
}

get_package_name() {
    case $1 in
        workplacebyls) echo "com.locationsolutions.workplacebyls" ;;
        workplacebytsphub) echo "com.locationsolutions.workplacebytsphub" ;;
        tiabytsp) echo "com.locationsolutions.tiabytsp" ;;
        *) echo "com.locationsolutions.workplacebyls" ;;
    esac
}

get_ipa_path() {
    case $1 in
        tiabytsp) echo "build/ios/ipa/TIA by TSP.ipa" ;;
        workplacebyls) echo "build/ios/ipa/Workplace By LS.ipa" ;;
        workplacebytsphub) echo "build/ios/ipa/Workplace By TSPHub.ipa" ;;
        *) echo "" ;;
    esac
}

upload_to_google_play() {
    local flavor=$1
    local aab="build/app/outputs/bundle/${flavor}Release/app-${flavor}-release.aab"
    [[ ! -f $aab ]] && echo "${CROSS} AAB not found: $aab" && return
    local creds=$(jq -r ".$flavor.google_play" "$CREDENTIALS_FILE")
    local pkg=$(get_package_name $flavor)
    echo "${UPLOAD} Uploading to ${BOLD}Google Play${RESET}..."
    fastlane supply --aab "$aab" --package_name "$pkg" --track production --json_key "$creds" \
        --skip_upload_metadata --skip_upload_images --skip_upload_screenshots
}

upload_to_app_store() {
    local flavor=$1
    local ipa=$(get_ipa_path $flavor)
    [[ ! -f $ipa ]] && echo "${CROSS} IPA not found: $ipa" && return
    local key=$(jq -r ".$flavor.app_store_key_path" "$CREDENTIALS_FILE")
    echo "${UPLOAD} Uploading to ${BOLD}App Store Connect${RESET}..."
    fastlane deliver --ipa "$ipa" --skip_metadata --skip_screenshots \
        --submit_for_review --automatic_release --api_key_path "$key"
}

handle_bump() {
    local flavor=$1 platform=$2
    build_name=$(jq -r ".$flavor.build_name" "$VERSION_FILE")
    build_number=$(jq -r ".$flavor.$platform.build_number" "$VERSION_FILE")

    [[ "$build_name" == "null" || "$build_number" == "null" ]] && \
        echo "${CROSS} Missing version info for $flavor ($platform)" && exit 1

    new_build=$((build_number + 1))
    tmp=$(mktemp)
    jq ".$flavor.$platform.build_number = $new_build" "$VERSION_FILE" > "$tmp" && mv "$tmp" "$VERSION_FILE"

    update_pubspec_yaml "$build_name" "$new_build"
    update_codemagic_yaml "$build_name" "$new_build"
    append_changelog "$flavor" "$platform" "$build_name" "$new_build"

    echo "${CHECK} Bumped ${BOLD}$flavor${RESET} (${DIM}$platform${RESET}) → ${GREEN}$build_name+$new_build${RESET}"
}

handle_bump_all() {
    for flavor in "${SUPPORTED_FLAVORS[@]}"; do
        for platform in "${SUPPORTED_PLATFORMS[@]}"; do
            handle_bump "$flavor" "$platform"
        done
    done
    echo "${BOX} ${GREEN}All versions bumped and saved${RESET}"
}

handle_release() {
    local flavor=$1 platform=$2
    echo ""
    echo "${MAGENTA}➤ Releasing $flavor ($platform)...${RESET}"

    build_name=$(jq -r ".$flavor.build_name" "$VERSION_FILE")
    build_number=$(jq -r ".$flavor.$platform.build_number" "$VERSION_FILE")
    [[ "$build_name" == "null" || "$build_number" == "null" ]] && \
        echo "${CROSS} Missing version info for $flavor ($platform)" && return

    # Bump patch version and build number
    IFS='.' read -r major minor patch <<< "$build_name"
    new_patch=$((patch + 1))
    new_build_name="${major}.${minor}.${new_patch}"
    new_build=$((build_number + 1))

    # Update version.json early
    tmp=$(mktemp)
    jq ".$flavor.build_name = \"$new_build_name\" | .$flavor.$platform.build_number = $new_build" \
        "$VERSION_FILE" > "$tmp" && mv "$tmp" "$VERSION_FILE"

    update_pubspec_yaml "$new_build_name" "$new_build"
    update_codemagic_yaml "$new_build_name" "$new_build"
    append_changelog "$flavor" "$platform" "$new_build_name" "$new_build"

    echo "${ROCKET} ${CYAN}Running Shorebird release...${RESET}"
    target="lib/main_${flavor}.dart"
    shorebird release "$platform" \
        --flutter-version="$FLUTTER_VERSION" \
        --flavor "$flavor" \
        -t "$target" \
        --build-name="$new_build_name" \
        --build-number="$new_build"

    [[ "$platform" == "android" ]] && upload_to_google_play "$flavor"
    [[ "$platform" == "ios" ]] && upload_to_app_store "$flavor"

    echo "${CHECK} ${GREEN}Done: $flavor ($platform) → $new_build_name+$new_build${RESET}"
}

handle_release_all() {
    # Get initial version from first flavor/platform to use as base
    local flavor="${SUPPORTED_FLAVORS[1]}"
    local platform="${SUPPORTED_PLATFORMS[1]}"
    

    # echo "base_flavor: $base_flavor (base_platform: $base_platform)"
    build_name=$(jq -r ".$flavor.build_name" "$VERSION_FILE")
    build_number=$(jq -r ".$flavor.$platform.build_number" "$VERSION_FILE")

    # Calculate new version numbers once
    IFS='.' read -r major minor patch <<< "$build_name"
    local new_patch=$((patch + 1))
    local new_build_name="${major}.${minor}.${new_patch}"
    local new_build=$((build_number + 1))

    echo "${INFO} ${CYAN}Using version $new_build_name+$new_build for all flavors${RESET}"

    # Update version.json for all flavors at once
    local tmp=$(mktemp)
    # Read the content of the file first
    local json_content=$(cat "$VERSION_FILE")
    for flavor in "${SUPPORTED_FLAVORS[@]}"; do
        json_content=$(echo "$json_content" | jq ".$flavor.build_name = \"$new_build_name\"")
        for platform in "${SUPPORTED_PLATFORMS[@]}"; do
            json_content=$(echo "$json_content" | jq ".$flavor.$platform.build_number = $new_build")
        done
    done
    echo "$json_content" > "$tmp" && mv "$tmp" "$VERSION_FILE"

    # Update pubspec.yaml and codemagic.yaml once
    update_pubspec_yaml "$new_build_name" "$new_build"
    update_codemagic_yaml "$new_build_name" "$new_build"

    # Perform releases with the same version
    for flavor in "${SUPPORTED_FLAVORS[@]}"; do
        for platform in "${SUPPORTED_PLATFORMS[@]}"; do
            echo ""
            echo "${MAGENTA}➤ Releasing $flavor ($platform)...${RESET}"

            echo "${ROCKET} ${CYAN}Running Shorebird release...${RESET}"
            target="lib/main_${flavor}.dart"
            shorebird release "$platform" \
                --flutter-version="$FLUTTER_VERSION" \
                --flavor "$flavor" \
                -t "$target" \
                --build-name="$new_build_name" \
                --build-number="$new_build"

            [[ "$platform" == "android" ]] && upload_to_google_play "$flavor"
            [[ "$platform" == "ios" ]] && upload_to_app_store "$flavor"

            append_changelog "$flavor" "$platform" "$new_build_name" "$new_build"
            echo "${CHECK} ${GREEN}Done: $flavor ($platform) → $new_build_name+$new_build${RESET}"
        done
    done
    
    echo "${CHECK} ${GREEN}All releases completed with version $new_build_name+$new_build${RESET}"
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------
COMMAND=${1:-}
FLAVOR=${2:-}
PLATFORM=${3:-}

# Check for required tools
check_jq # Always needed for version manipulation

# Check for release-specific tools
if [[ "$COMMAND" == "release" || "$COMMAND" == "release-all" ]]; then
    check_fastlane
    check_shorebird
fi

case "$COMMAND" in
    bump)
        [[ -z $FLAVOR || -z $PLATFORM ]] && echo "${CROSS} Usage: bump <flavor> <platform>" && exit 1
        handle_bump "$FLAVOR" "$PLATFORM"
        ;;
    bump-all)
        handle_bump_all
        ;;
    release)
        [[ -z $FLAVOR || -z $PLATFORM ]] && echo "${CROSS} Usage: release <flavor> <platform>" && exit 1
        handle_release "$FLAVOR" "$PLATFORM"
        ;;
    release-all)
        handle_release_all
        ;;
    --help)
        print_help
        ;;
    *)
        echo "${CROSS} Unknown command: $COMMAND"
        print_help
        ;;
esac
