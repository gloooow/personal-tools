#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
python_env_manager.sh

Sets up pyenv + uv on Debian/WSL2 and creates per-project Python environments.

USAGE:
  # 1) Install system deps + pyenv + uv and configure ~/.bashrc
  ./python_env_manager.sh --install-tools

  # After --install-tools, open a new shell and use:
  venvup            # activate nearest .venv (searches parent dirs)
  venvdown          # deactivate (if active)
  venvwhich         # show the python being used

  # 2) Create/update one project's pinned Python + .venv
  ./python_env_manager.sh --project /path/to/app --python 3.10.14

  # 3) Optionally install dependencies after creating .venv
  ./python_env_manager.sh --project /path/to/app --python 3.12.3 --requirements requirements.txt
  ./python_env_manager.sh --project /path/to/app --python 3.12.3 --sync

OPTIONS:
  --install-tools          Install build deps, pyenv, uv; update ~/.bashrc
  --project PATH           Project directory (will be created if missing)
  --python VERSION         Python version for this project (e.g., 3.10.14)
  --requirements FILE      Install deps from requirements file (relative to project or absolute)
  --sync                   Run "uv sync" (for pyproject.toml workflows)
  --help                   Show this help

NOTES:
  - Creates/updates: PROJECT/.python-version and PROJECT/.venv/
  - Does NOT commit anything; add ".venv/" to your project's .gitignore
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

ensure_pyenv_in_current_shell() {
  # Make pyenv available in this script process even if the user hasn't
  # reloaded their shell rc yet (common on zsh/WSL).
  export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv >/dev/null 2>&1; then
    # We're in bash, but pyenv init output is POSIX-y enough for our usage.
    # shellcheck disable=SC1091
    eval "$(pyenv init - bash)" >/dev/null 2>&1 || true
  fi
}

append_if_missing() {
  local file="$1"
  local marker="$2"
  local content="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -Fqs "$marker" "$file"; then
    {
      echo ""
      echo "$content"
    } >>"$file"
  fi
}

install_tools() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
      echo "warning: This script is tuned for Debian. Detected: ${PRETTY_NAME:-unknown}" >&2
    fi
  fi

  need_cmd sudo
  need_cmd apt
  sudo apt update
  sudo apt install -y \
    ca-certificates curl git \
    build-essential make \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncursesw5-dev xz-utils tk-dev libffi-dev liblzma-dev \
    libgdbm-dev libgdbm-compat-dev uuid-dev

  need_cmd curl
  need_cmd git

  if [[ ! -d "${HOME}/.pyenv" ]]; then
    curl -fsSL https://pyenv.run | bash
  fi

  [[ -x "${HOME}/.pyenv/bin/pyenv" ]] || die "pyenv install did not create ${HOME}/.pyenv/bin/pyenv"

  # Ensure pyenv is available for future shells (bash + zsh).
  local pyenv_rc_block
  pyenv_rc_block='# >>> pyenv init >>>
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"
# <<< pyenv init <<<'

  append_if_missing "${HOME}/.bashrc" "# >>> pyenv init >>>" \
'# >>> pyenv init >>>
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"
# <<< pyenv init <<<'

  # zsh doesn't source ~/.bashrc; configure ~/.zshrc too.
  append_if_missing "${HOME}/.zshrc" "# >>> pyenv init >>>" "$pyenv_rc_block"

  # Make pyenv available in this shell too (if possible).
  ensure_pyenv_in_current_shell

  if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi

  # Ensure uv is on PATH for future shells (uv installer typically does this, but be safe).
  append_if_missing "${HOME}/.bashrc" "# >>> uv path >>>" \
'# >>> uv path >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< uv path <<<'
  append_if_missing "${HOME}/.zshrc" "# >>> uv path >>>" \
'# >>> uv path >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< uv path <<<'

  # Add convenience functions for activating per-project .venv.
  append_if_missing "${HOME}/.bashrc" "# >>> python venv helpers >>>" \
'# >>> python venv helpers >>>
# Activate the nearest ".venv" by searching current dir and parents.
venvup() {
  local dir="${PWD}"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.venv/bin/activate" ]]; then
      # shellcheck disable=SC1090
      source "$dir/.venv/bin/activate"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "No .venv found in this directory or parents." >&2
  return 1
}

# Deactivate if a venv is active.
venvdown() {
  if declare -F deactivate >/dev/null 2>&1; then
    deactivate
  else
    echo "No active virtual environment to deactivate." >&2
    return 1
  fi
}

# Show which Python is currently active.
venvwhich() {
  command -v python || true
  python --version 2>/dev/null || true
}
# <<< python venv helpers <<<'

  # zsh doesn't source ~/.bashrc; install helpers there too.
  append_if_missing "${HOME}/.zshrc" "# >>> python venv helpers >>>" \
'# >>> python venv helpers >>>
# Activate the nearest ".venv" by searching current dir and parents.
venvup() {
  local dir="${PWD}"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.venv/bin/activate" ]]; then
      source "$dir/.venv/bin/activate"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "No .venv found in this directory or parents." >&2
  return 1
}

# Deactivate if a venv is active.
venvdown() {
  if declare -F deactivate >/dev/null 2>&1; then
    deactivate
  else
    echo "No active virtual environment to deactivate." >&2
    return 1
  fi
}

# Show which Python is currently active.
venvwhich() {
  command -v python || true
  python --version 2>/dev/null || true
}
# <<< python venv helpers <<<'

  echo "Installed tools. Open a new shell or run: source ~/.bashrc"
}

create_project_env() {
  local project_dir="$1"
  local py_ver="$2"
  local requirements_path="${3:-}"
  local do_sync="${4:-false}"

  mkdir -p "$project_dir"
  pushd "$project_dir" >/dev/null

  if ! command -v pyenv >/dev/null 2>&1; then
    # If pyenv is installed but user's shell hasn't reloaded rc yet, load it now.
    ensure_pyenv_in_current_shell
  fi
  if ! command -v pyenv >/dev/null 2>&1; then
    die "pyenv not found. Run: $0 --install-tools (then restart your shell, or run: source ~/.zshrc)"
  fi
  if ! command -v uv >/dev/null 2>&1; then
    die "uv not found. Run: $0 --install-tools"
  fi

  # Install Python version if missing.
  if ! pyenv versions --bare | grep -Fxq "$py_ver"; then
    pyenv install "$py_ver"
  fi

  pyenv local "$py_ver"  # writes .python-version

  # Create .venv using this project's pinned python.
  uv venv --python "$(pyenv which python)"

  # Optional dependency install.
  if [[ -n "$requirements_path" ]]; then
    local req="$requirements_path"
    if [[ ! -f "$req" ]]; then
      # allow passing paths relative to project
      if [[ -f "$project_dir/$requirements_path" ]]; then
        req="$project_dir/$requirements_path"
      else
        die "requirements file not found: $requirements_path"
      fi
    fi
    uv pip install -r "$req"
  fi

  if [[ "$do_sync" == "true" ]]; then
    uv sync
  fi

  echo "Done."
  echo "Project: $project_dir"
  echo "Pinned Python: $py_ver (in .python-version)"
  echo "Venv: $project_dir/.venv"
  echo "Activate with: source \"$project_dir/.venv/bin/activate\""

  popd >/dev/null
}

main() {
  local install=false
  local project=""
  local py_ver=""
  local requirements=""
  local sync=false

  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-tools) install=true; shift ;;
      --project) project="${2:-}"; shift 2 ;;
      --python) py_ver="${2:-}"; shift 2 ;;
      --requirements) requirements="${2:-}"; shift 2 ;;
      --sync) sync=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *)
        die "Unknown argument: $1 (use --help)"
        ;;
    esac
  done

  if [[ "$install" == "true" ]]; then
    install_tools
  fi

  if [[ -n "$project" || -n "$py_ver" || -n "$requirements" || "$sync" == "true" ]]; then
    [[ -n "$project" ]] || die "--project is required to create a project env"
    [[ -n "$py_ver" ]] || die "--python is required to create a project env"
    create_project_env "$project" "$py_ver" "$requirements" "$sync"
  fi
}

main "$@"

