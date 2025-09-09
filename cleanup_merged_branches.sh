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
RECURSIVE=false
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
        -r|--recursive)
            RECURSIVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-f|--force] [-l|--list|--dry-run] [-r|--recursive] [REPO_PATH]"
            echo "  -f, --force         Skip confirmation and delete all matching branches"
            echo "  -l, --list, --dry-run  Show matching branches without taking action"
            echo "  -r, --recursive     Recursively process all git repositories in the given path"
            echo "  REPO_PATH           Path to git repository or directory pattern (optional, defaults to current directory)"
            echo ""
            echo "Examples:"
            echo "  $0                 # Interactive mode in current repo"
            echo "  $0 /path/to/repo   # Interactive mode in specified repo"
            echo "  $0 -r ../*    # Recursively process all repos in ../*"
            echo "  $0 -f              # Force delete all matching branches in current repo"
            echo "  $0 -f /path/to/repo # Force delete all matching branches in specified repo"
            echo "  $0 -l              # List matching branches only in current repo"
            echo "  $0 -l -r ../* # List matching branches in all repos under ../*"
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
                # If recursive mode is enabled, collect all remaining arguments as part of the pattern
                if [ "$RECURSIVE" = true ]; then
                    REPO_PATH="$REPO_PATH $*"
                    break  # Process all remaining arguments as part of the pattern
                else
                    echo "Error: Multiple repository paths specified"
                    echo "Use -h or --help for usage information"
                    exit 1
                fi
            fi
            shift
            ;;
    esac
done

echo "🔍 Starting branch cleanup process..."
echo ""

# Function to discover git repositories in a directory pattern
discover_git_repos() {
    local pattern="$1"
    local repos=()
    
    # Expand the pattern to get all matching directories
    for dir in $pattern; do
        if [ -d "$dir" ]; then
            # Check if it's a git repository
            if [ -d "$dir/.git" ]; then
                repos+=("$dir")
            else
                # If it's a directory but not a git repo, search for git repos inside it
                while IFS= read -r -d '' repo; do
                    repos+=("$repo")
                done < <(find "$dir" -type d -name ".git" -print0 2>/dev/null | sed 's|/.git$||' | tr '\0' '\n' | sort -u)
            fi
        fi
    done
    
    # Return the array
    printf '%s\n' "${repos[@]}"
}

# Determine repositories to process
if [ "$RECURSIVE" = true ]; then
    if [ -n "$REPO_PATH" ]; then
        # Discover all git repositories in the given pattern
        REPOS=($(discover_git_repos "$REPO_PATH"))
        if [ ${#REPOS[@]} -eq 0 ]; then
            echo "❌ Error: No git repositories found in pattern '$REPO_PATH'"
            exit 1
        fi
        echo "🔍 Found ${#REPOS[@]} git repositories to process:"
        for repo in "${REPOS[@]}"; do
            echo "   - $repo"
        done
        echo ""
    else
        echo "❌ Error: Recursive mode requires a directory pattern"
        echo "Use -h or --help for usage information"
        exit 1
    fi
else
    # Single repository mode
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
    REPOS=("$REPO_PATH")
    echo "📁 Working in repository: $REPO_PATH"
    echo ""
fi

# Function to process a single repository
process_repository() {
    local repo_path="$1"
    local repo_name=$(basename "$repo_path")
    
    echo "🏗️  Processing repository: $repo_name ($repo_path)"
    echo "═══════════════════════════════════════════════════════════════"
    
    # Get current user from git config for this repository
    local user=$(git -C "$repo_path" config user.name)
    if [ -z "$user" ]; then
        echo "❌ Could not determine git user for $repo_name. Please set with: git config user.name 'Your Name'"
        echo "⏭️  Skipping repository: $repo_name"
        echo ""
        return 1
    fi
    
    echo "👤 Checking for user: $user"
    echo ""
    
    # Get all local branches (excluding main/master)
    local local_branches=$(git -C "$repo_path" branch | grep -v "main\|master" | sed 's/^[ *]*//')
    
    if [ -z "$local_branches" ]; then
        echo "📋 No local branches found to check in $repo_name."
        echo ""
        return 0
    fi
    
    echo "📋 Local branches found in $repo_name:"
    echo "$local_branches"
    echo ""
    
    # First pass: identify branches that match criteria
    echo "🔍 Identifying branches that match deletion criteria in $repo_name..."
    echo ""
    
    local candidates=()
    local candidate_info=()
    
    for branch in $local_branches; do
        echo "🔍 Checking branch: $branch"
        
        # Check if branch exists on origin
        if branch_exists_on_origin "$branch" "$repo_path"; then
            echo "   ⏭️ Branch exists on origin - keeping"
        else
            echo "   👀 Branch doesn't exist on origin - checking for merged PR"
            
            # Try to find merged PR for this branch
            if pr_info=$(find_merged_pr_for_branch "$branch" "$repo_path"); then
                echo "   ✅ Found merged PR - CANDIDATE FOR DELETION"
                candidates+=("$branch")
                candidate_info+=("$pr_info")
            else
                echo "   ⚠️ No merged PR found - keeping branch (may be unmerged or different author)"
            fi
        fi
        echo ""
    done
    
    # Show summary of candidates for this repository
    if [ ${#candidates[@]} -eq 0 ]; then
        echo "🎉 No branches match the deletion criteria in $repo_name!"
        echo "📋 All branches are either:"
        echo "   - Still exist on origin (not merged yet)"
        echo "   - Don't have associated merged PRs"
        echo ""
        return 0
    fi
    
    echo "📋 Branches that match deletion criteria in $repo_name (${#candidates[@]} total):"
    echo ""
    
    for i in "${!candidates[@]}"; do
        branch="${candidates[$i]}"
        pr_info="${candidate_info[$i]}"
        
        echo "$((i+1)). $branch"
        if [ -n "$pr_info" ]; then
            echo "   $pr_info" | jq '.'
        fi
        echo ""
    done
    
    # If list-only flag is set, just show the candidates and return
    if [ "$LIST_ONLY" = true ]; then
        echo "📊 Summary for $repo_name:"
        echo "   - Branches that would be deleted: ${#candidates[@]}"
        echo ""
        return 0
    fi
    
    # If force flag is set, delete all candidates
    if [ "$FORCE" = true ]; then
        echo "🚀 Force mode enabled - deleting all ${#candidates[@]} branches in $repo_name..."
        echo ""
        
        for i in "${!candidates[@]}"; do
            branch="${candidates[$i]}"
            pr_info="${candidate_info[$i]}"
            delete_branch "$branch" "$pr_info" "$repo_path"
        done
        
        echo ""
        echo "🎉 Force cleanup complete for $repo_name!"
        echo "📊 Summary:"
        echo "   - Branches deleted: ${#candidates[@]}"
        echo ""
        echo "📋 Remaining branches in $repo_name:"
        git -C "$repo_path" branch | grep -v "main\|master" | sed 's/^[ *]*/- /' || echo "   (none)"
        echo ""
        return 0
    fi
    
    # Interactive mode: confirm each deletion
    echo "🤔 Interactive mode - confirm each deletion in $repo_name:"
    echo ""
    
    local merged_count=0
    local skipped_count=0
    
    for i in "${!candidates[@]}"; do
        branch="${candidates[$i]}"
        pr_info="${candidate_info[$i]}"
        
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
                    delete_branch "$branch" "$pr_info" "$repo_path"
                    ((merged_count++))
                    break
                    ;;
                [Nn])
                    echo "   ⏭️  Skipping: $branch"
                    break
                    ;;
                [Ss])
                    echo "   ⏭️  Skipping all remaining branches in $repo_name..."
                    skipped_count=$((skipped_count + ${#candidates[@]} - i))
                    break 2
                    ;;
                *)
                    echo "   ❓ Please enter y, n, or s"
                    ;;
            esac
        done
        echo ""
    done
    
    echo "🎉 Interactive cleanup complete for $repo_name!"
    echo "📊 Summary:"
    echo "   - Branches deleted: $merged_count"
    echo "   - Branches skipped: $skipped_count"
    echo ""
    echo "📋 Remaining branches in $repo_name:"
    git -C "$repo_path" branch | grep -v "main\|master" | sed 's/^[ *]*/- /' || echo "   (none)"
    echo ""
}

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

# Process each repository
TOTAL_REPOS=${#REPOS[@]}
TOTAL_DELETED=0
TOTAL_SKIPPED=0

for i in "${!REPOS[@]}"; do
    repo_path="${REPOS[$i]}"
    
    if [ $TOTAL_REPOS -gt 1 ]; then
        echo "📊 Processing repository $((i+1)) of $TOTAL_REPOS"
        echo ""
    fi
    
    # Process this repository
    process_repository "$repo_path"
    
    # Note: The process_repository function handles its own output and doesn't return counts
    # For now, we'll just track that we processed it
done

# Final summary for multiple repositories
if [ $TOTAL_REPOS -gt 1 ]; then
    echo "🎉 All repositories processed!"
    echo "📊 Final Summary:"
    echo "   - Repositories processed: $TOTAL_REPOS"
    echo ""
fi 