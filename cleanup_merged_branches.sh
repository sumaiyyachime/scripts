#!/bin/bash

# Cleanup merged branches script
# This script finds local branches that have had their PRs merged by checking:
# 1. Look at local branches
# 2. Check if branch exists on origin
# 3. If branch doesn't exist on origin, find merged PR authored by me with that branch as head
# 4. If found, assume branch was merged and delete it

set -e

# Parse command line arguments
FORCE=false
LIST_ONLY=false
REPO_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -l|--list|--dry-run)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-f|--force] [-l|--list|--dry-run] [REPO_PATH]"
            echo "  -f, --force         Skip confirmation and delete all matching branches"
            echo "  -l, --list, --dry-run  Show matching branches without taking action"
            echo "  REPO_PATH           Path to git repository (optional, defaults to current directory)"
            echo ""
            echo "Examples:"
            echo "  $0                 # Interactive mode in current repo"
            echo "  $0 /path/to/repo   # Interactive mode in specified repo"
            echo "  $0 -f              # Force delete all matching branches in current repo"
            echo "  $0 -f /path/to/repo # Force delete all matching branches in specified repo"
            echo "  $0 -l              # List matching branches only in current repo"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            if [ -z "$REPO_PATH" ]; then
                REPO_PATH="$1"
            else
                echo "Error: Multiple repository paths specified"
                echo "Use -h or --help for usage information"
                exit 1
            fi
            shift
            ;;
    esac
done

echo "🔍 Starting branch cleanup process..."
echo ""

# Validate repository path if provided
if [ -n "$REPO_PATH" ]; then
    if [ ! -d "$REPO_PATH" ]; then
        echo "❌ Error: Repository path '$REPO_PATH' does not exist"
        exit 1
    fi
    if [ ! -d "$REPO_PATH/.git" ]; then
        echo "❌ Error: '$REPO_PATH' is not a git repository"
        exit 1
    fi
else
    REPO_PATH="$(pwd)"
fi
echo "📁 Working in repository: $REPO_PATH"
echo ""

# Get current user from git config
USER=$(git -C "$REPO_PATH" config user.name)
if [ -z "$USER" ]; then
    echo "❌ Could not determine git user. Please set with: git config user.name 'Your Name'"
    exit 1
fi

echo "👤 Checking for user: $USER"
echo ""

# Get all local branches (excluding main/master)
LOCAL_BRANCHES=$(git -C "$REPO_PATH" branch | grep -v "main\|master" | sed 's/^[ *]*//')

if [ -z "$LOCAL_BRANCHES" ]; then
    echo "📋 No local branches found to check."
    exit 0
fi

echo "📋 Local branches found:"
echo "$LOCAL_BRANCHES"
echo ""

# Function to check if branch exists on origin
branch_exists_on_origin() {
    local branch=$1
    local repo_path="${2:-.}"
    if git -C "$repo_path" ls-remote --heads origin "$branch" | grep -q "$branch"; then
        return 0  # Branch exists on origin
    else
        return 1  # Branch doesn't exist on origin
    fi
}

# Function to get current repository in owner/repo format
get_current_repo() {
    local repo_path="${1:-.}"
    # Get remote URL and extract owner/repo
    local remote_url=$(git -C "$repo_path" config --get remote.origin.url)
    # ssh format
    if [[ "$remote_url" =~ git@github\.com[:/]([^/]+)/([^/]+)\.git$ ]] || \
        # https format
       [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/]+)\.git$ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "Error: Could not determine repository from remote URL: $remote_url"
        return 1
    fi
}

# Function to find merged PR for a branch
find_merged_pr_for_branch() {
    local branch=$1
    local repo_path="${2:-.}"
    
    # Get current repository
    local repo=$(get_current_repo "$repo_path")
    if [ $? -ne 0 ]; then
        echo "Error: $repo" >&2
        return 1
    fi
    
    # Use GitHub API to search for merged PRs with this branch as head
    # Note: This requires GitHub CLI or curl with token
    if command -v gh &> /dev/null; then
        # Use GitHub CLI if available

        
        # Try exact branch name first
        local pr_info=$(gh pr list --repo "$repo" --head "$branch" --state merged --author "@me" --json title,url --limit 1)
        if [ "$pr_info" != "[]" ]; then
            # Pretty print the JSON if jq is available, otherwise output as-is
            if command -v jq &> /dev/null; then
                echo "$pr_info" | jq '.'
            else
                echo "$pr_info"
            fi
            return 0
        fi
    fi
    
    # commenting out but leaving in for posterity
    # else
    #     # Fallback: check if commit message appears in main
    #     local commit_msg=$(git -C "$repo_path" log --oneline "$branch" -1 | cut -d' ' -f2-)
    #     if git -C "$repo_path" log --oneline main | grep -q "$commit_msg"; then
    #         echo "{\"number\": \"found\", \"title\": \"$commit_msg\", \"url\": \"merged\"}"
    #         return 0
    #     fi
    # fi
    
    return 1
}

# Function to safely delete a branch
delete_branch() {
    local branch=$1
    local pr_info=$2
    local repo_path="${3:-.}"
    
    echo "🗑️  Deleting merged branch: $branch"
    if [ -n "$pr_info" ]; then
        echo "   📝 Associated PR: $pr_info"
    fi
    git -C "$repo_path" branch -D "$branch"
}

# First pass: identify branches that match criteria
echo "🔍 Identifying branches that match deletion criteria..."
echo ""

CANDIDATES=()
CANDIDATE_INFO=()

for branch in $LOCAL_BRANCHES; do
    echo "🔍 Checking branch: $branch"
    
    # Check if branch exists on origin
    if branch_exists_on_origin "$branch" "$REPO_PATH"; then
        echo "   ⏭️ Branch exists on origin - keeping"
    else
        echo "   👀 Branch doesn't exist on origin - checking for merged PR"
        
        # Try to find merged PR for this branch
        
        if pr_info=$(find_merged_pr_for_branch "$branch" "$REPO_PATH"); then
            echo "   ✅ Found merged PR - CANDIDATE FOR DELETION"
            CANDIDATES+=("$branch")
            CANDIDATE_INFO+=("$pr_info")
        else
            echo "   ⚠️ No merged PR found - keeping branch (may be unmerged or different author)"
        fi
    fi
    echo ""
done

# Show summary of candidates
if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "🎉 No branches match the deletion criteria!"
    echo "📋 All branches are either:"
    echo "   - Still exist on origin (not merged yet)"
    echo "   - Don't have associated merged PRs"
    exit 0
fi

echo "📋 Branches that match deletion criteria (${#CANDIDATES[@]} total):"
echo ""

for i in "${!CANDIDATES[@]}"; do
    branch="${CANDIDATES[$i]}"
    pr_info="${CANDIDATE_INFO[$i]}"
    
    echo "$((i+1)). $branch"
    if [ -n "$pr_info" ]; then
        echo "   $pr_info" | jq '.'
    fi
    echo ""
done

# If list-only flag is set, just show the candidates and exit
if [ "$LIST_ONLY" = true ]; then
    echo "📊 Summary:"
    echo "   - Branches that would be deleted: ${#CANDIDATES[@]}"
    echo "   - Use './cleanup_merged_branches.sh' to delete them interactively"
    echo "   - Use './cleanup_merged_branches.sh -f' to delete them all at once"
    exit 0
fi

# If force flag is set, delete all candidates
if [ "$FORCE" = true ]; then
    echo "🚀 Force mode enabled - deleting all ${#CANDIDATES[@]} branches..."
    echo ""
    
    for i in "${!CANDIDATES[@]}"; do
        branch="${CANDIDATES[$i]}"
        pr_info="${CANDIDATE_INFO[$i]}"
        delete_branch "$branch" "$pr_info" "$REPO_PATH"
    done
    
    echo ""
    echo "🎉 Force cleanup complete!"
    echo "📊 Summary:"
    echo "   - Branches deleted: ${#CANDIDATES[@]}"
    echo ""
    echo "📋 Remaining branches:"
    git branch | grep -v "main\|master" | sed 's/^[ *]*/- /' || echo "   (none)"
    exit 0
fi

# Interactive mode: confirm each deletion
echo "🤔 Interactive mode - confirm each deletion:"
echo ""

MERGED_COUNT=0
SKIPPED_COUNT=0

for i in "${!CANDIDATES[@]}"; do
    branch="${CANDIDATES[$i]}"
    pr_info="${CANDIDATE_INFO[$i]}"
    
    echo "Branch: $branch"
    if [ -n "$pr_info" ]; then
        echo "PR: $pr_info"
    fi
    echo ""
    
    while true; do
        read -p "Delete this branch? (y/n/s=skip all remaining): " -n 1 -r
        echo
        case $REPLY in
            [Yy])
                delete_branch "$branch" "$pr_info" "$REPO_PATH"
                ((MERGED_COUNT++))
                break
                ;;
            [Nn])
                echo "   ⏭️  Skipping: $branch"
                break
                ;;
            [Ss])
                echo "   ⏭️  Skipping all remaining branches..."
                SKIPPED_COUNT=$((SKIPPED_COUNT + ${#CANDIDATES[@]} - i))
                break 2
                ;;
            *)
                echo "   ❓ Please enter y, n, or s"
                ;;
        esac
    done
    echo ""
done

echo "🎉 Interactive cleanup complete!"
echo "📊 Summary:"
echo "   - Branches deleted: $MERGED_COUNT"
echo "   - Branches skipped: $SKIPPED_COUNT"
echo ""
echo "📋 Remaining branches:"
git -C "$REPO_PATH" branch | grep -v "main\|master" | sed 's/^[ *]*/- /' || echo "   (none)" 