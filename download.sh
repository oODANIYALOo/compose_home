#!/bin/bash

set -euo pipefail

REPO_OWNER="oODANIYALOo"
REPO_NAME="compose_home"
BRANCH="main"            
DOWNLOAD_DIR="./downloaded"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


check_dependencies() {
    local missing_deps=()
    
    if ! command -v dialog &> /dev/null; then
        missing_deps+=("dialog")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing dependencies: ${missing_deps[*]}${NC}"
        echo "Please install them using:"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
        echo "  macOS: brew install ${missing_deps[*]}"
        echo "  ARCH: sudo pacman -Sy ${missing_deps[*]}"
        exit 1
    fi
}


get_github_directory_contents() {
    local dir_path="$1"
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${dir_path}?ref=${BRANCH}"
    
    local response
    response=$(curl -s -H "Accept: application/vnd.github.v3+json" "$api_url")
    
    if echo "$response" | grep -q "API rate limit exceeded"; then
        return 1
    fi
    
    if echo "$response" | grep -q "\"type\":\"dir\""; then
        echo "$response" | jq -r '.[] | select(.type == "dir") | .name' 2>/dev/null
        return 0
    else
        return 1
    fi
}

get_directories_git() {
    local dir_path="$1"
    local temp_dir
    
    temp_dir=$(mktemp -d)
    
    if git clone --depth 1 --no-checkout --filter=blob:none \
        "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$temp_dir" &>/dev/null; then
        
        cd "$temp_dir" || return 1
        
        git ls-tree -d --name-only "${BRANCH}:${dir_path}" 2>/dev/null || true
        
        cd - > /dev/null || return 1
        rm -rf "$temp_dir"
        return 0
    fi
    
    rm -rf "$temp_dir"
    return 1
}

get_available_directories() {
    local base_dir="$1"
    local dirs=()
    
    if dirs=($(get_github_directory_contents "$base_dir")); then
        echo "${dirs[@]}"
        return 0
    fi
    
    if dirs=($(get_directories_git "$base_dir")); then
        echo "${dirs[@]}"
        return 0
    fi
    
    return 1
}

download_directory() {
    local dir_path="$1"
    local target_dir="$2"
    local dir_name=$(basename "$dir_path")
    
    mkdir -p "$target_dir"
    
    dialog --title "Downloading" --infobox "Downloading ${dir_name}...\n\nPlease wait..." 8 50
    
    local temp_dir=$(mktemp -d)
    
    (
        cd "$temp_dir" || return 1
        git init -q
        git remote add origin "https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
        git sparse-checkout init --cone
        git sparse-checkout set "$dir_path"
        git pull -q origin "$BRANCH"
    ) &>/dev/null
    
    if [ -d "$temp_dir/$dir_path" ]; then
        rm -rf "$target_dir/$dir_name"
        cp -r "$temp_dir/$dir_path" "$target_dir/"
        local result=$?
        rm -rf "$temp_dir"
        return $result
    else
        rm -rf "$temp_dir"
        return 1
    fi
}


show_environment_menu() {
    local choice
    
    choice=$(dialog --clear --title "GitHub Repository Downloader" \
        --backtitle "Download from: ${REPO_OWNER}/${REPO_NAME}" \
        --menu "Select the environment to download from:" \
        15 60 4 \
        "last-version" "Latest stable versions" \
        "localy" "Local development versions" \
        "production" "Production ready versions" \
        "exit" "Exit the program" \
        3>&1 1>&2 2>&3)
    
    echo "$choice"
}

show_directory_selection() {
    local env_type="$1"
    local -n dirs_ref=$2
    local -n selected_ref=$3
    
    local menu_items=()
    local i=1
    
    for dir in "${dirs_ref[@]}"; do
        menu_items+=("$i" "$dir" "off")
        ((i++))
    done
    
    if [ ${#menu_items[@]} -eq 0 ]; then
        dialog --title "Error" --msgbox "No directories found in '${env_type}'!" 8 50
        return 1
    fi
    
    local cmd_output
    cmd_output=$(dialog --clear --title "Select Directories" \
        --backtitle "Environment: ${env_type}" \
        --checklist "Select directories to download:\n(Use SPACE to select, ENTER to confirm)" \
        20 60 15 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    
    local exit_status=$?
    
    if [ $exit_status -eq 0 ] && [ -n "$cmd_output" ]; then
        selected_ref=()
        for num in $cmd_output; do
            num=$(echo "$num" | tr -d '"')
            local index=$((num - 1))
            selected_ref+=("${dirs_ref[$index]}")
        done
        return 0
    fi
    
    return 1
}

show_download_progress() {
    local env_type="$1"
    local -n selected_ref=$2
    local total=${#selected_ref[@]}
    local current=0
    
    (
        for dir in "${selected_ref[@]}"; do
            current=$((current + 1))
            percent=$((current * 100 / total))
            
            echo "$percent"
            echo "XXX"
            echo "Downloading: $dir"
            echo "Progress: $current of $total"
            echo "XXX"
            
            if download_directory "${env_type}/${dir}" "${DOWNLOAD_DIR}/${env_type}"; then
                echo "✅ Completed: $dir"
            else
                echo "❌ Failed: $dir"
            fi
        done
    ) | dialog --title "Downloading Files" \
        --gauge "Starting download..." 10 70 0
}

show_summary() {
    local env_type="$1"
    local -n successful_ref=$2
    local -n failed_ref=$3
    
    local summary=""
    summary+="Environment: ${env_type}\n"
    summary+="Download location: ${DOWNLOAD_DIR}/${env_type}\n\n"
    
    summary+="✅ Successfully downloaded:\n"
    if [ ${#successful_ref[@]} -gt 0 ]; then
        for dir in "${successful_ref[@]}"; do
            summary+="  • $dir\n"
        done
    else
        summary+="  None\n"
    fi
    
    summary+="\n❌ Failed downloads:\n"
    if [ ${#failed_ref[@]} -gt 0 ]; then
        for dir in "${failed_ref[@]}"; do
            summary+="  • $dir\n"
        done
    else
        summary+="  None\n"
    fi
    
    dialog --title "Download Complete" \
        --msgbox "$summary" 20 60
}


main() {
    check_dependencies
    
    mkdir -p "$DOWNLOAD_DIR"
    
    while true; do
        local env_choice
        env_choice=$(show_environment_menu)
        
        if [ -z "$env_choice" ] || [ "$env_choice" = "exit" ]; then
            dialog --title "Goodbye" --msgbox "Thank you for using GitHub Downloader!\n\nDownloaded files are in: ${DOWNLOAD_DIR}" 10 50
            clear
            echo -e "${GREEN}Files downloaded to: ${DOWNLOAD_DIR}${NC}"
            exit 0
        fi
        
        dialog --title "Loading" --infobox "Fetching directories from ${env_choice}...\nPlease wait..." 8 50
        
        local dirs=()
        if ! dirs=($(get_available_directories "$env_choice")); then
            dialog --title "Error" \
                --msgbox "Failed to fetch directories from GitHub.\n\nPossible issues:\n• API rate limit exceeded\n• Repository not found\n• Network issues\n\nPlease check your configuration." 12 60
            continue
        fi
        
        if [ ${#dirs[@]} -eq 0 ]; then
            dialog --title "No Directories" \
                --msgbox "No directories found in '${env_choice}'.\n\nThis could mean:\n• The directory is empty\n• The path doesn't exist\n• You don't have access" 12 60
            continue
        fi
        
        local selected_dirs=()
        if show_directory_selection "$env_choice" dirs selected_dirs; then
            if [ ${#selected_dirs[@]} -gt 0 ]; then
                # Confirm selection
                local confirm_msg="You selected:\n\n"
                for dir in "${selected_dirs[@]}"; do
                    confirm_msg+="  • ${dir}\n"
                done
                confirm_msg+="\nTotal: ${#selected_dirs[@]} directories\n\nDownload to: ${DOWNLOAD_DIR}/${env_choice}/\n\nProceed with download?"
                
                if dialog --title "Confirm Selection" --yesno "$confirm_msg" 15 60; then
                    local successful=()
                    local failed=()
                    
                    for dir in "${selected_dirs[@]}"; do
                        if download_directory "${env_choice}/${dir}" "${DOWNLOAD_DIR}/${env_choice}"; then
                            successful+=("$dir")
                        else
                            failed+=("$dir")
                        fi
                    done
                    
                    show_summary "$env_choice" successful failed
                    
                    dialog --title "Continue" \
                        --yesno "Do you want to download more directories?" 7 50
                    
                    if [ $? -ne 0 ]; then
                        dialog --title "Goodbye" --msgbox "Thank you for using GitHub Downloader!\n\nDownloaded files are in: ${DOWNLOAD_DIR}" 10 50
                        clear
                        echo -e "${GREEN}Files downloaded to: ${DOWNLOAD_DIR}${NC}"
                        exit 0
                    fi
                fi
            else
                dialog --title "No Selection" --msgbox "No directories selected!" 8 50
            fi
        fi
    done
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --owner)
            REPO_OWNER="$2"
            shift 2
            ;;
        --repo)
            REPO_NAME="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --output)
            DOWNLOAD_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "GitHub Repository Directory Downloader"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --owner NAME     GitHub repository owner (default: your-username)"
            echo "  --output DIR     Download directory (default: ./downloaded)"
            echo "  --help, -h       Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 --owner mycompany --repo configs --branch production --output ./configs"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main
