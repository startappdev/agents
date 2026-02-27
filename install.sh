#!/bin/bash

# Claude Code Agents & Skills - Interactive Installer
# Installs agents, commands, and hooks to your Claude configuration

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CLAUDE_DIR="$HOME/.claude"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
REPO_AGENTS_DIR="./agents"
REPO_COMMANDS_DIR="./commands"
REPO_HOOKS_DIR="./hooks"

print_header() {
    echo ""
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${CYAN} Claude Code Agents & Skills - Installer${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}+${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error()   { echo -e "${RED}x${NC} $1"; }
print_info()    { echo -e "${BLUE}i${NC} $1"; }

check_repository() {
    if [ ! -d "$REPO_AGENTS_DIR" ] && [ ! -d "$REPO_COMMANDS_DIR" ]; then
        print_error "Run this script from the repository root directory."
        exit 1
    fi
}

setup_directories() {
    print_info "Setting up Claude directories..."
    mkdir -p "$AGENTS_DIR" "$COMMANDS_DIR" "$HOOKS_DIR"
    print_success "Directories ready"
    echo ""
}

check_existing_file() {
    local source_file=$1
    local target_file=$2
    if [ -f "$target_file" ]; then
        if ! diff -q "$source_file" "$target_file" &>/dev/null; then
            return 0
        fi
    fi
    return 1
}

check_existing_dir() {
    local source_dir=$1
    local target_dir=$2
    if [ -d "$target_dir" ]; then
        if ! diff -rq "$source_dir" "$target_dir" &>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# --- Agents ---

get_available_agents() {
    if [ -d "$REPO_AGENTS_DIR" ]; then
        find "$REPO_AGENTS_DIR" -maxdepth 1 -name "*.md" -exec basename {} .md \;
    fi
}

install_agent() {
    local name=$1 force=$2
    local src="$REPO_AGENTS_DIR/${name}.md"
    local dst="$AGENTS_DIR/${name}.md"
    [ ! -f "$src" ] && { print_error "Agent '$name' not found"; return 1; }

    if check_existing_file "$src" "$dst"; then
        if [ "$force" != "yes" ]; then
            print_warning "Agent '$name' exists and differs"
            read -p "  Overwrite? (y/n): " -n 1 -r; echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Skipped '$name'"; return 0; }
        fi
    fi
    cp "$src" "$dst"
    print_success "Installed agent: $name"
}

# --- Commands ---

get_available_commands() {
    if [ -d "$REPO_COMMANDS_DIR" ]; then
        find "$REPO_COMMANDS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
    fi
}

install_command() {
    local name=$1 force=$2
    local src="$REPO_COMMANDS_DIR/$name"
    local dst="$COMMANDS_DIR/$name"
    local flat_file="$COMMANDS_DIR/${name}.md"
    [ ! -d "$src" ] && { print_error "Command '$name' not found"; return 1; }

    # Handle flat file → directory migration
    # Claude Code supports both ~/.claude/commands/foo.md and ~/.claude/commands/foo/foo.md
    # If a flat file exists alongside the directory, it causes duplicate commands
    if [ -f "$flat_file" ]; then
        if [ "$force" != "yes" ]; then
            print_warning "Command '$name' exists as flat file (${name}.md)"
            read -p "  Replace with directory format? (y/n): " -n 1 -r; echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Skipped '$name'"; return 0; }
        fi
        rm -f "$flat_file"
        print_info "Removed flat file: ${name}.md"
    fi

    if check_existing_dir "$src" "$dst"; then
        if [ "$force" != "yes" ]; then
            print_warning "Command '$name' exists and differs"
            read -p "  Overwrite? (y/n): " -n 1 -r; echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Skipped '$name'"; return 0; }
        fi
        rm -rf "$dst"
    fi
    cp -r "$src" "$COMMANDS_DIR/"
    print_success "Installed command: $name"
}

# --- Hooks ---

get_available_hooks() {
    if [ -d "$REPO_HOOKS_DIR" ]; then
        find "$REPO_HOOKS_DIR" -maxdepth 1 -name "*.sh" -exec basename {} \;
    fi
}

install_hook() {
    local name=$1 force=$2
    local src="$REPO_HOOKS_DIR/$name"
    local dst="$HOOKS_DIR/$name"
    [ ! -f "$src" ] && { print_error "Hook '$name' not found"; return 1; }

    if check_existing_file "$src" "$dst"; then
        if [ "$force" != "yes" ]; then
            print_warning "Hook '$name' exists and differs"
            read -p "  Overwrite? (y/n): " -n 1 -r; echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Skipped '$name'"; return 0; }
        fi
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    print_success "Installed hook: $name"
}

# --- Selection menus ---

select_items() {
    local type=$1
    shift
    local items=("$@")

    if [ ${#items[@]} -eq 0 ]; then
        print_info "No ${type}s found"
        return
    fi

    echo -e "${CYAN}Available ${type}s:${NC}"
    echo ""
    local i=1
    for item in "${items[@]}"; do
        echo "  $i) $item"
        ((i++))
    done
    echo "  a) Install all"
    echo "  s) Skip"
    echo ""

    read -p "Select (comma-separated numbers, 'a' for all, 's' to skip): " selection

    if [ "$selection" == "s" ] || [ "$selection" == "S" ]; then
        print_info "Skipping ${type}s"
        echo ""
        return
    fi

    echo ""

    if [ "$selection" == "a" ] || [ "$selection" == "A" ]; then
        for item in "${items[@]}"; do
            install_${type} "$item" "no"
        done
    else
        IFS=',' read -ra SELS <<< "$selection"
        for sel in "${SELS[@]}"; do
            sel=$(echo "$sel" | xargs)
            if [[ "$sel" =~ ^[0-9]+$ ]]; then
                local idx=$((sel - 1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#items[@]} ]; then
                    install_${type} "${items[$idx]}" "no"
                else
                    print_warning "Invalid selection: $sel"
                fi
            fi
        done
    fi
    echo ""
}

# --- MCP checks ---

check_greptile_mcp() {
    print_info "Greptile MCP Check"
    echo ""
    if ! command -v claude &>/dev/null; then
        print_warning "Claude CLI not found - skipping MCP check"
        echo ""
        return 0
    fi
    if claude mcp list 2>/dev/null | grep -q "greptile"; then
        print_success "Greptile MCP already installed"
    else
        print_warning "Greptile MCP not detected"
        echo ""
        print_info "The greptile-review-loop agent requires the Greptile MCP plugin."
        echo ""
        echo -e "${YELLOW}To install Greptile:${NC}"
        echo "  1. Install the Greptile GitHub app at https://app.greptile.com"
        echo "  2. Add the Greptile MCP plugin to Claude Code"
    fi
    echo ""
}

# --- Main ---

main() {
    print_header
    check_repository
    setup_directories

    print_info "Step 1: Agents"
    echo ""
    local agents=($(get_available_agents))
    select_items "agent" "${agents[@]}"

    print_info "Step 2: Commands"
    echo ""
    local commands=($(get_available_commands))
    select_items "command" "${commands[@]}"

    print_info "Step 3: Hooks"
    echo ""
    local hooks=($(get_available_hooks))
    select_items "hook" "${hooks[@]}"

    print_info "Step 4: Dependency Checks"
    echo ""
    check_greptile_mcp

    echo -e "${CYAN}========================================================${NC}"
    print_success "Installation complete!"
    echo ""
    print_info "Restart Claude Code to load new configurations."
    echo -e "${CYAN}========================================================${NC}"
}

main
