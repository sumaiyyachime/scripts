#!/bin/bash

# Update main branches script
# This script updates the main branch in all git repositories under ~/work
# It handles both cases: when you're on main and when you're on feature branches

# Removed set -e to handle errors gracefully

# Parse command line arguments
REPO_PATH=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--path)
            REPO_PATH="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-p|--path PATH] [-d|--dry-run] [-v|--verbose] [-h|--help]"
            echo "  -p, --path PATH    Path to search for git repositories (default: ~/work)"
            echo "  -d, --dry-run      Show what would be done without making changes"
            echo "  -v, --verbose      Show detailed output for each repository"
            echo "  -h, --help         Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                           # Update all repos in ~/work"
            echo "  $0 -p ~/projects             # Update all repos in ~/projects"
            echo "  $0 -d                        # Show what would be updated"
            echo "  $0 -v                        # Verbose output"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Set default path if not provided
if [ -z "$REPO_PATH" ]; then
    REPO_PATH="$HOME/work"
fi

# Arrays to track results
SUCCESSFUL_REPOS=()
FAILED_REPOS=()
ERROR_MESSAGES=()

echo "🔍 Starting main branch update process..."
echo "📁 Searching for git repositories in: $REPO_PATH"
echo ""

# Check if the path exists
if [ ! -d "$REPO_PATH" ]; then
    echo "❌ Error: Path '$REPO_PATH' does not exist"
    exit 1
fi

# Find all git repositories
echo "🔍 Discovering git repositories..."
REPOS=()
while IFS= read -r -d '' repo; do
    REPOS+=("$repo")
done < <(find "$REPO_PATH" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | while IFS= read -r -d '' dir; do
    if [ -d "$dir/.git" ]; then
        printf '%s\0' "$dir"
    fi
done)

if [ ${#REPOS[@]} -eq 0 ]; then
    echo "❌ No git repositories found in '$REPO_PATH'"
    exit 1
fi

echo "📊 Found ${#REPOS[@]} git repositories to process:"
for repo in "${REPOS[@]}"; do
    echo "   - $(basename "$repo")"
done
echo ""

# Function to process a single repository
process_repository() {
    local repo_path="$1"
    local repo_name=$(basename "$repo_path")
    local error_msg=""
    
    if [ "$VERBOSE" = true ]; then
        echo "🏗️  Processing repository: $repo_name"
        echo "═══════════════════════════════════════════════════════════════"
    fi
    
    # Check if it's actually a git repository
    if ! git -C "$repo_path" rev-parse --git-dir > /dev/null 2>&1; then
        error_msg="Not a git repository"
        FAILED_REPOS+=("$repo_name")
        ERROR_MESSAGES+=("$error_msg")
        if [ "$VERBOSE" = true ]; then
            echo "❌ $error_msg"
        fi
        return 1
    fi
    
    # Check if there's a remote origin
    if ! git -C "$repo_path" remote get-url origin > /dev/null 2>&1; then
        error_msg="No remote origin configured"
        FAILED_REPOS+=("$repo_name")
        ERROR_MESSAGES+=("$error_msg")
        if [ "$VERBOSE" = true ]; then
            echo "❌ $error_msg"
        fi
        return 1
    fi
    
    # Check if main branch exists on origin
    if ! git -C "$repo_path" ls-remote --heads origin main > /dev/null 2>&1; then
        error_msg="No main branch on origin (might be 'master' or different name)"
        FAILED_REPOS+=("$repo_name")
        ERROR_MESSAGES+=("$error_msg")
        if [ "$VERBOSE" = true ]; then
            echo "❌ $error_msg"
        fi
        return 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "🔍 [DRY RUN] Would update main branch in: $repo_name"
        SUCCESSFUL_REPOS+=("$repo_name")
        return 0
    fi
    
    # Fetch latest changes
    if [ "$VERBOSE" = true ]; then
        echo "📥 Fetching latest changes..."
    fi
    
    if ! git -C "$repo_path" fetch > /dev/null 2>&1; then
        error_msg="Failed to fetch from remote"
        FAILED_REPOS+=("$repo_name")
        ERROR_MESSAGES+=("$error_msg")
        if [ "$VERBOSE" = true ]; then
            echo "❌ $error_msg"
        fi
        return 1
    fi
    
    # Get current branch
    current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "unknown")
    
    if [ "$VERBOSE" = true ]; then
        echo "📍 Current branch: $current_branch"
    fi
    
    # Update main branch based on current branch
    if [ "$current_branch" = "main" ]; then
        if [ "$VERBOSE" = true ]; then
            echo "🔄 On main branch, pulling changes..."
        fi
        
        # Check for uncommitted changes
        if ! git -C "$repo_path" diff --quiet || ! git -C "$repo_path" diff --cached --quiet; then
            error_msg="Local changes would be overwritten by merge"
            FAILED_REPOS+=("$repo_name")
            ERROR_MESSAGES+=("$error_msg")
            if [ "$VERBOSE" = true ]; then
                echo "❌ $error_msg"
            fi
            return 1
        fi
        
        if ! git -C "$repo_path" pull > /dev/null 2>&1; then
            error_msg="Failed to pull changes (merge conflict or other error)"
            FAILED_REPOS+=("$repo_name")
            ERROR_MESSAGES+=("$error_msg")
            if [ "$VERBOSE" = true ]; then
                echo "❌ $error_msg"
            fi
            return 1
        fi
    else
        if [ "$VERBOSE" = true ]; then
            echo "📝 On feature branch ($current_branch), updating main branch..."
        fi
        
        if ! git -C "$repo_path" branch -f main origin/main > /dev/null 2>&1; then
            error_msg="Failed to update main branch (might be checked out elsewhere)"
            FAILED_REPOS+=("$repo_name")
            ERROR_MESSAGES+=("$error_msg")
            if [ "$VERBOSE" = true ]; then
                echo "❌ $error_msg"
            fi
            return 1
        fi
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo "✅ $repo_name updated successfully"
    fi
    
    SUCCESSFUL_REPOS+=("$repo_name")
    return 0
}

# Process each repository
TOTAL_REPOS=${#REPOS[@]}
PROCESSED=0

for repo_path in "${REPOS[@]}"; do
    ((PROCESSED++))
    
    repo_name=$(basename "$repo_path")
    
    if [ $TOTAL_REPOS -gt 1 ] && [ "$VERBOSE" = false ]; then
        echo -n "Processing $repo_name ($PROCESSED/$TOTAL_REPOS)... "
    fi
    
    # Process the repository and capture the return code
    process_repository "$repo_path"
    repo_success=$?
    
    if [ $TOTAL_REPOS -gt 1 ] && [ "$VERBOSE" = false ]; then
        if [ $repo_success -eq 0 ]; then
            echo "✅"
        else
            echo "❌"
        fi
    else
        # If verbose mode or single repo, just add a newline for clean output
        echo ""
    fi
done

echo ""
echo "🎉 Update process complete!"
echo ""

# Print summary
echo "📊 SUMMARY"
echo "═══════════════════════════════════════════════════════════════"

if [ ${#SUCCESSFUL_REPOS[@]} -gt 0 ]; then
    echo "✅ Successfully updated repositories (${#SUCCESSFUL_REPOS[@]}):"
    for repo in "${SUCCESSFUL_REPOS[@]}"; do
        echo "   - $repo"
    done
    echo ""
fi

if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    echo "❌ Failed to update repositories (${#FAILED_REPOS[@]}):"
    for i in "${!FAILED_REPOS[@]}"; do
        repo="${FAILED_REPOS[$i]}"
        error="${ERROR_MESSAGES[$i]}"
        echo "   - $repo: $error"
    done
    echo ""
fi

echo "📈 Total: $TOTAL_REPOS repositories processed"
echo "   - Successful: ${#SUCCESSFUL_REPOS[@]}"
echo "   - Failed: ${#FAILED_REPOS[@]}"

# Exit with error code if any repositories failed
if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    exit 1
fi
