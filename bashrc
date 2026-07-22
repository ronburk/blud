alias gs='git status'
shopt -s nullglob

GLOBIGNORE=bludlua.c
ZIP_FILES=(
*.{awk,c,h,lua,cpp,org,sh,json}
builtin.blud
CHATGPT_NOTES.md
test.blud
test/*
bludfile
.gitignore
./luajit/src/libluajit.a
./luajit/src/lua*.h
./luajit/src/lauxlib.h
*.py
)
unset GLOBIGNORE
upload()
{
    # generate meta-info for ChatGPT
    PYTHON="$HOME/.venvs/blud-lua-index/bin/python"

    if [ ! -x "$PYTHON" ]; then
        echo "error: Lua index Python environment not found: $PYTHON" >&2
        exit 1
    fi

    echo "$PYTHON" ./generate_lua_index.py
    "$PYTHON" ./generate_lua_index.py

    zip -FS blud.zip "${ZIP_FILES[@]}"
    local slop="${1:-5 minutes}"
    local timestamp
    local destination
    rm -f -- blud-upload-*.zip || return
    timestamp=$(date -u -d "now + $slop" +%s) || return
    printf -v timestamp '%012d' "$timestamp"
    destination="blud-upload-${timestamp}.zip"
    cp -- ./blud.zip "$destination" || return
    printf 'file://%s' "$(realpath -- "$destination")" |
        xclip -selection clipboard -t text/uri-list
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