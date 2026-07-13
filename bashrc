alias gs='git status'
upload()
{
    local timestamp
    local destination

    rm -f -- blud-upload-20*.zip || return

    timestamp=$(date -u +'%Y%m%dT%H%M%S.%NZ') || return
    destination="blud-upload-${timestamp}.zip"

    cp -- ./blud.zip "$destination" || return
    echo -n "file://$(realpath $destination)" | xclip -selection clipboard -t text/uri-list
    printf '%s\n' "$destination"
}

# ==========================================
# PORTABLE GIT & PROMPT CONFIG (Cloud Synced)
# ==========================================

# 1. The Git Prompt Logic
set_bash_prompt() {
  local Cyan="\[\033[0;36m\]"
  local Green="\[\033[0;32m\]"
  local Red="\[\033[0;31m\]"
  local Reset="\[\033[0m\]"
  
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$(git status --porcelain --ignore-submodules=all 2>/dev/null)" ]; then
      export PS1="${Cyan}\w${Red} ($branch ✗)${Reset} \$ "
    else
      export PS1="${Cyan}\w${Green} ($branch ✓)${Reset} \$ "
    fi
  else
    export PS1="${Cyan}\w${Reset} \$ "
  fi
}
export PROMPT_COMMAND=set_bash_prompt

# 2. The Automation Macros
accept() {
  local patch_branch=$(git branch --show-current)
  if [ "$patch_branch" = "main" ]; then
    echo "❌ Error: You are already on main."
    return 1
  fi
  git switch main && git merge "$patch_branch" && git branch -d "$patch_branch"
}

reject() {
  local patch_branch=$(git branch --show-current)
  if [ "$patch_branch" = "main" ]; then
    echo "❌ Error: You are already on main."
    return 1
  fi
  git switch main && git branch -D "$patch_branch"
}

echo "🚀 Project environment loaded successfully!"