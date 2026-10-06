#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

CONFIG_FILE="${C7S_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/c7s/config}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

PANEL_DIR="${PANEL_DIR:-}"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-$SCRIPT_DIR/extensions}"
GITHUB_USER="${GITHUB_USER:-}"
REPO_PREFIX="${REPO_PREFIX:-c7s_extension_}"
REPO_VISIBILITY="${REPO_VISIBILITY:-private}"
RUN_DIR="${RUN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/c7s/run}"
RUN_IMAGE="${RUN_IMAGE:-ghcr.io/calagopus/panel:heavy}"
RUN_BIND="${RUN_BIND:-127.0.0.1}"
RUN_PORT="${RUN_PORT:-8090}"
RUN_MEMORY="${RUN_MEMORY:-6g}"
RUN_JOBS="${RUN_JOBS:-2}"

die() { printf '%s\n' "$*" >&2; exit 1; }

PACKAGE_RE='^[a-z]{2,6}\.[a-z0-9-]{3,30}\.[a-z0-9-]{4,30}$'
is_package() { [[ "$1" =~ $PACKAGE_RE ]]; }

package_in() {
  [ -f "$1/Metadata.toml" ] || return 0
  sed -n 's/^package_name = "\(.*\)"/\1/p' "$1/Metadata.toml"
}

identifier_of() { printf '%s' "${1//./_}"; }
repo_of() { printf '%s%s' "$REPO_PREFIX" "${1##*.}"; }

repo_dir_of() { printf '%s/%s' "$EXTENSIONS_DIR" "$(repo_of "$1")"; }
panel_dir_of() { printf '%s/backend-extensions/%s' "$PANEL_DIR" "$(identifier_of "$1")"; }

is_panel() { [ -d "$1/backend-extensions" ] && [ -f "$1/Cargo.toml" ]; }

# PANEL_DIR is not guessable on someone else's machine, so it comes from the
# environment, the config file, or an upward walk from the current directory.
resolve_panel_dir() {
  if [ -n "$PANEL_DIR" ]; then
    [ -d "$PANEL_DIR" ] || die "PANEL_DIR is set to $PANEL_DIR, which does not exist"
    is_panel "$PANEL_DIR" ||
      die "$PANEL_DIR does not look like a panel checkout, it has no backend-extensions/"
    return
  fi

  local dir="$PWD"
  while [ "$dir" != / ]; do
    is_panel "$dir" && { PANEL_DIR="$dir"; return; }
    dir="$(dirname "$dir")"
  done

  die "no panel checkout found, run c7s from inside one or set PANEL_DIR:

  mkdir -p $(dirname "$CONFIG_FILE")
  echo 'PANEL_DIR=/path/to/calagopus' >> $CONFIG_FILE"
}

github_user() {
  [ -n "$GITHUB_USER" ] && { printf '%s' "$GITHUB_USER"; return; }
  command -v gh >/dev/null 2>&1 || die "set GITHUB_USER, or install gh, see https://cli.github.com"
  GITHUB_USER="$(gh api user --jq .login 2>/dev/null)" ||
    die "set GITHUB_USER, or authenticate gh with: gh auth login"
  [ -n "$GITHUB_USER" ] || die "set GITHUB_USER, gh returned no login"
  printf '%s' "$GITHUB_USER"
}

panel_rs() {
  local candidate
  for candidate in "$PANEL_DIR/target/heavy-release/panel-rs" "$PANEL_DIR/target/release/panel-rs" "$PANEL_DIR/target/debug/panel-rs"; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
  done
  command -v panel-rs >/dev/null 2>&1 && { printf 'panel-rs'; return; }
  die "panel-rs not found, build it with: cd $PANEL_DIR && SQLX_OFFLINE=true cargo build -p panel-rs"
}

RSYNC_EXCLUDES=(--exclude node_modules --exclude dist --exclude .git --exclude target)

# panel checkout -> repository. The panel keeps the crate at the extension root,
# the repository keeps it under backend/, matching the .c7s.zip layout.
cmd_pull() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s pull <package.name>"
  local repo panel
  repo="$(repo_dir_of "$package")"
  panel="$(panel_dir_of "$package")"
  [ -d "$panel" ] || die "no extension at $panel"

  mkdir -p "$repo/backend"
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" \
    --exclude frontend --exclude migrations --exclude Metadata.toml \
    "$panel/" "$repo/backend/"
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$panel/frontend/" "$repo/frontend/"
  cp "$panel/Metadata.toml" "$repo/Metadata.toml"
  [ -d "$panel/migrations" ] && rsync -a "$panel/migrations/" "$repo/migrations/"

  printf 'pulled %s into %s\n' "$package" "$repo"
}

# repository -> panel checkout. Use after reinstalling or updating the panel.
cmd_install() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s install <package.name>"
  local repo panel
  repo="$(repo_dir_of "$package")"
  panel="$(panel_dir_of "$package")"
  [ -d "$repo" ] || die "no repository at $repo"

  mkdir -p "$panel"
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" \
    --exclude frontend --exclude migrations --exclude Metadata.toml \
    "$repo/backend/" "$panel/"
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$repo/frontend/" "$panel/frontend/"
  cp "$repo/Metadata.toml" "$panel/Metadata.toml"
  [ -d "$repo/migrations" ] && rsync -a "$repo/migrations/" "$panel/migrations/"

  cd "$PANEL_DIR" && "$(panel_rs)" extensions resync >/dev/null
  printf 'installed %s into %s\n' "$package" "$panel"
}

cmd_install_all() {
  local dir package
  for dir in "$EXTENSIONS_DIR"/*/; do
    [ -f "$dir/Metadata.toml" ] || continue
    package="$(sed -n 's/^package_name = "\(.*\)"/\1/p' "$dir/Metadata.toml")"
    cmd_install "$package"
  done
  cd "$PANEL_DIR/frontend" && pnpm install
}

# extensions resync and pnpm install rewrite tracked panel files, which is
# enough for git pull to refuse. They are regenerated at the end of an update,
# so they are restored instead of being stashed.
GENERATED_PATHS=(Cargo.lock backend-extensions/internal-list frontend/pnpm-lock.yaml)

cmd_update() {
  local discard=0 build=0 arg
  for arg in "$@"; do
    case "$arg" in
      --discard) discard=1 ;;
      --build)   build=1 ;;
      *)         die "usage: c7s update [--discard] [--build]" ;;
    esac
  done

  cd "$PANEL_DIR"
  git rev-parse --git-dir >/dev/null 2>&1 || die "$PANEL_DIR is not a git checkout"

  local path
  for path in "${GENERATED_PATHS[@]}"; do
    git checkout -q HEAD -- "$path" 2>/dev/null || true
  done

  local dirty
  dirty="$(git status --porcelain --untracked-files=no)"
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty"
    if [ "$discard" -eq 1 ]; then
      git reset -q --hard
      printf 'discarded the panel changes above\n'
    else
      git stash push -q -m "c7s update $(date '+%Y-%m-%d %H:%M')"
      printf 'stashed the panel changes above, recover with: git -C %s stash pop\n' "$PANEL_DIR"
    fi
  fi

  local before after
  before="$(git rev-parse HEAD)"
  git pull --ff-only ||
    die "git pull failed, the panel checkout has diverged from origin, reset it with:

  git -C $PANEL_DIR reset --hard origin/$(git branch --show-current)"
  after="$(git rev-parse HEAD)"

  if [ "$before" = "$after" ]; then
    printf 'already up to date at %s\n' "$(git log -1 --format='%h %s')"
  else
    git --no-pager log --oneline "$before..$after"
  fi

  if [ "$build" -eq 1 ]; then
    SQLX_OFFLINE=true cargo build -p panel-rs
  fi

  "$(panel_rs)" extensions resync >/dev/null
  cd "$PANEL_DIR/frontend" && pnpm install

  if [ "$build" -eq 0 ]; then
    printf 'rebuild the panel with: cd %s && SQLX_OFFLINE=true cargo build -p panel-rs\n' "$PANEL_DIR"
  fi
}

cmd_export() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s export <package.name>"
  local repo identifier archive
  repo="$(repo_dir_of "$package")"
  identifier="$(identifier_of "$package")"
  [ -d "$(panel_dir_of "$package")" ] || die "no extension at $(panel_dir_of "$package")"

  cd "$PANEL_DIR"
  cargo fmt -p extension-internal-list
  "$(panel_rs)" extensions export "$package"

  archive="$PANEL_DIR/exported-extensions/$identifier.c7s.zip"
  [ -f "$archive" ] || die "export finished but $archive is missing"

  mkdir -p "$repo/dist"
  cp "$archive" "$repo/dist/"
  printf 'exported to %s/dist/%s.c7s.zip\n' "$repo" "$identifier"
}

cmd_new() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s new <package.name>"
  local repo panel
  repo="$(repo_dir_of "$package")"
  panel="$(panel_dir_of "$package")"
  [ -e "$repo" ] && die "$repo already exists"
  [ -e "$panel" ] && die "$panel already exists"

  cd "$PANEL_DIR" && "$(panel_rs)" extensions init "$package"

  mkdir -p "$repo"
  printf 'target/\nnode_modules/\ndist/\n*.c7s.zip\n' > "$repo/.gitignore"
  cmd_pull "$package"
  cd "$repo" && git init -b main -q && git add -A && git commit -q -m "feat: $package"
  printf 'edit it at %s\n' "$panel"
}

cmd_repo() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s repo <package.name> [repo-name]"
  local repo name user
  [ "$#" -le 2 ] || die "usage: c7s repo <package.name> [repo-name]"
  repo="$(repo_dir_of "$package")"
  name="${2:-$(repo_of "$package")}"
  [ -d "$repo" ] || die "no repository at $repo, run: c7s pull $package"

  command -v gh >/dev/null 2>&1 || die "gh is not installed, see https://cli.github.com"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated, run: gh auth login"
  user="$(github_user)"

  cmd_pull "$package"

  cd "$repo"
  [ -d .git ] || git init -b main
  git add -A
  git diff --cached --quiet || git commit -m "feat: $package"

  if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin HEAD
  else
    gh repo create "$name" "--$REPO_VISIBILITY" --source . --remote origin --push
  fi

  printf 'https://github.com/%s/%s\n' "$user" "$name"
}

cmd_commit() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s commit <package.name> [message]"
  local repo
  repo="$(repo_dir_of "$package")"

  cmd_pull "$package"

  cd "$repo"
  git add -A
  if git diff --cached --quiet; then
    printf 'nothing to commit\n'
    return
  fi
  git commit -m "${2:-chore: update $package}"
  git remote get-url origin >/dev/null 2>&1 && git push
}

cmd_release() {
  local package="${1:-}"
  [ -n "$package" ] || die "usage: c7s release <package.name> [tag]"
  local repo identifier tag version
  repo="$(repo_dir_of "$package")"
  identifier="$(identifier_of "$package")"
  version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$(panel_dir_of "$package")/Cargo.toml" | head -1)"
  tag="${2:-v$version}"

  command -v gh >/dev/null 2>&1 || die "gh is not installed, see https://cli.github.com"

  cmd_export "$package"
  cmd_commit "$package" "chore: release $tag"

  cd "$repo"
  gh release create "$tag" "$repo/dist/$identifier.c7s.zip" --title "$tag" --notes "$package $version"
}

cmd_clone() {
  local target="${1:-}"
  [ -n "$target" ] || die "usage: c7s clone <repo-name|owner/repo-name>"
  local name repo package
  name="${target##*/}"
  [ "$target" = "$name" ] && target="$(github_user)/$name"
  repo="$EXTENSIONS_DIR/$name"
  [ -e "$repo" ] && die "$repo already exists"

  mkdir -p "$EXTENSIONS_DIR"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo clone "$target" "$repo"
  else
    git clone "https://github.com/$target.git" "$repo"
  fi

  package="$(sed -n 's/^package_name = "\(.*\)"/\1/p' "$repo/Metadata.toml")"
  [ -n "$package" ] || die "$repo has no package_name in Metadata.toml"
  cmd_install "$package"
}

state_of() {
  local repo panel
  repo="$(repo_dir_of "$1")"
  panel="$(panel_dir_of "$1")"
  if [ ! -d "$repo" ]; then
    printf 'no repository'
  elif [ ! -d "$panel" ]; then
    printf 'missing from panel'
  elif diff -rq --exclude node_modules --exclude dist --exclude .git \
    "$repo/frontend" "$panel/frontend" >/dev/null 2>&1 &&
    diff -rq "$repo/backend/src" "$panel/src" >/dev/null 2>&1 &&
    { [ ! -d "$panel/migrations" ] || diff -rq --exclude .gitkeep "$repo/migrations" "$panel/migrations" >/dev/null 2>&1; }; then
    printf 'in sync'
  else
    printf 'panel has changes'
  fi
}

# Packages a command can act on: "panel" lists what is in the panel checkout,
# "repo" lists what has a repository, for commands that copy the other way.
packages_from() {
  local dir
  if [ "$1" = repo ]; then
    for dir in "$EXTENSIONS_DIR"/*/; do package_in "$dir"; printf '\n'; done
  else
    for dir in "$PANEL_DIR"/backend-extensions/*/; do package_in "$dir"; printf '\n'; done
  fi | grep -E "$PACKAGE_RE" | sort -u
}

# Scrollable multi-select. fzf when it is installed, whiptail otherwise.
# Prints one selected package per line.
pick() {
  local title="$1" source="$2" preselect="$3"
  local packages=() package state
  mapfile -t packages < <(packages_from "$source")
  [ "${#packages[@]}" -gt 0 ] || die "no extensions found to pick from"
  [ -t 0 ] && [ -t 2 ] || die "no package given, and no terminal to pick from. Pass the package names instead."

  if command -v fzf >/dev/null 2>&1; then
    for package in "${packages[@]}"; do
      printf '%-32s %s\n' "$package" "$(state_of "$package")"
    done | fzf --multi --reverse --height=80% --prompt="$title > " \
      --header='tab selects, enter confirms' --bind 'ctrl-a:select-all' |
      awk '{print $1}'
    return
  fi

  command -v whiptail >/dev/null 2>&1 || die "install fzf or whiptail to pick extensions, or pass the package names"

  local items=() on
  for package in "${packages[@]}"; do
    state="$(state_of "$package")"
    on=OFF
    [ "$preselect" = changed ] && [ "$state" = 'panel has changes' ] && on=ON
    items+=("$package" "$state" "$on")
  done

  local rows cols list
  rows="$(tput lines 2>/dev/null || printf 24)"
  cols="$(tput cols 2>/dev/null || printf 80)"
  list=$(( rows - 8 ))
  [ "$list" -gt "${#packages[@]}" ] && list="${#packages[@]}"
  [ "$list" -lt 1 ] && list=1

  whiptail --title "c7s $title" --separate-output \
    --checklist 'space selects, enter confirms, esc cancels' \
    "$(( list + 8 ))" "$(( cols < 90 ? cols : 90 ))" "$list" "${items[@]}" \
    3>&1 1>&2 2>&3 || die "cancelled"
}

# Runs a per-package command for every package given, or for every package
# picked when none is given. Arguments that are not package names are passed
# on to each run, so `c7s commit a.b.cdef x.y.zzzz "fix: thing"` works.
run_many() {
  local fn="$1" title="$2" source="$3" preselect="$4"
  shift 4
  local packages=() rest=() arg
  for arg in "$@"; do
    if is_package "$arg"; then packages+=("$arg"); else rest+=("$arg"); fi
  done

  if [ "${#packages[@]}" -eq 0 ]; then
    local picked
    picked="$(pick "$title" "$source" "$preselect")" || exit 1
    [ -n "$picked" ] && mapfile -t packages <<<"$picked"
  fi
  [ "${#packages[@]}" -gt 0 ] || die "nothing selected"

  local failed=() package status
  for package in "${packages[@]}"; do
    [ "${#packages[@]}" -gt 1 ] && printf '\n== %s %s\n' "$title" "$package"
    set +e
    ( set -e; "$fn" "$package" "${rest[@]}" )
    status=$?
    set -e
    [ "$status" -eq 0 ] || failed+=("$package")
  done

  if [ "${#packages[@]}" -gt 1 ]; then
    printf '\n%s: %d done, %d failed%s\n' "$title" \
      "$(( ${#packages[@]} - ${#failed[@]} ))" "${#failed[@]}" \
      "$([ "${#failed[@]}" -gt 0 ] && printf ' (%s)' "${failed[*]}")"
  fi
  [ "${#failed[@]}" -eq 0 ]
}

cmd_status() {
  local package
  [ -d "$EXTENSIONS_DIR" ] || die "no repositories at $EXTENSIONS_DIR"
  for package in $(packages_from repo); do
    printf '%-28s %s\n' "$package" "$(state_of "$package" | sed 's/^panel has changes$/panel has changes, run: c7s commit/')"
  done
}

cmd_config() {
  local panel
  panel="$(resolve_panel_dir >/dev/null 2>&1 && printf '%s' "$PANEL_DIR")" || panel='(not found)'
  PANEL_DIR="${PANEL_DIR:-$panel}"

  printf 'config file     %s%s\n' "$CONFIG_FILE" "$([ -f "$CONFIG_FILE" ] || printf ' (not present)')"
  printf 'PANEL_DIR       %s\n' "$panel"
  printf 'EXTENSIONS_DIR  %s\n' "$EXTENSIONS_DIR"
  printf 'GITHUB_USER     %s\n' "${GITHUB_USER:-$(github_user 2>/dev/null || printf '(unresolved)')}"
  printf 'REPO_PREFIX     %s\n' "$REPO_PREFIX"
  printf 'REPO_VISIBILITY %s\n' "$REPO_VISIBILITY"
  printf 'panel-rs        %s\n' "$(panel_rs 2>/dev/null || printf '(not found)')"
  printf 'RUN_DIR         %s (port %s:%s, %s RAM)\n' "$RUN_DIR" "$RUN_BIND" "$RUN_PORT" "$RUN_MEMORY"
}

# A throwaway panel with only the picked extensions, in its own compose
# project, so an extension can be tried without anything else installed.
run_compose() { docker compose -p c7s-run -f "$RUN_DIR/compose.yml" "$@"; }

# The existing archive is reused unless the extension changed after it was built.
archive_for() {
  local package="$1" identifier archive panel
  identifier="$(identifier_of "$package")"
  archive="$(repo_dir_of "$package")/dist/$identifier.c7s.zip"
  panel="$(panel_dir_of "$package")"

  if [ ! -f "$archive" ] || [ -n "$(find "$panel" -path "$panel/frontend/node_modules" -prune -o -newer "$archive" -type f -print -quit)" ]; then
    ( cmd_export "$package" ) >&2 || return 1
  fi
  printf '%s' "$archive"
}

write_run_compose() {
  mkdir -p "$RUN_DIR"/{extensions,binaries,translations,extension-migrations,data,logs,postgres,cache}
  [ -f "$RUN_DIR/.key" ] || head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "$RUN_DIR/.key"

  cat > "$RUN_DIR/compose.yml" <<EOF
services:
  web:
    image: $RUN_IMAGE
    mem_limit: $RUN_MEMORY
    environment:
      - REDIS_URL=redis://cache
      - DATABASE_URL=postgresql://panel:panel@db/panel
      - DATABASE_MIGRATE=true
      - PORT=8004
      - APP_PRIMARY=true
      - APP_ENCRYPTION_KEY=$(cat "$RUN_DIR/.key")
      - CARGO_BUILD_JOBS=$RUN_JOBS
      - NODE_OPTIONS=--max-old-space-size=3072
    volumes:
      - ./data:/var/lib/calagopus
      - ./logs:/var/log/calagopus
      - ./binaries:/app/binaries
      - ./translations:/app/translations
      - ./extensions:/app/extensions
      - ./extension-migrations:/app/repo/database/extension-migrations
    ports:
      - $RUN_BIND:$RUN_PORT:8004
    depends_on:
      - db
      - cache
  db:
    image: ghcr.io/calagopus/pgautoupgrade:18-alpine
    environment:
      - POSTGRES_USER=panel
      - POSTGRES_PASSWORD=panel
      - POSTGRES_DB=panel
      - PGDATA=/data
    volumes:
      - ./postgres:/data
  cache:
    image: ghcr.io/calagopus/valkey:latest
    command: --protected-mode no
    volumes:
      - ./cache:/data
EOF
}

cmd_run() {
  command -v docker >/dev/null 2>&1 || die "c7s run needs docker"

  case "${1:-}" in
    --stop)
      [ -f "$RUN_DIR/compose.yml" ] || die "no test panel at $RUN_DIR"
      run_compose stop
      return ;;
    --logs)
      [ -f "$RUN_DIR/compose.yml" ] || die "no test panel at $RUN_DIR"
      run_compose logs -f --tail 100 web
      return ;;
    --destroy)
      [ -f "$RUN_DIR/compose.yml" ] && run_compose down -v --remove-orphans
      rm -rf "$RUN_DIR"
      printf 'removed the test panel and all of its data at %s\n' "$RUN_DIR"
      return ;;
  esac

  local packages=() arg
  for arg in "$@"; do
    is_package "$arg" || die "usage: c7s run [package.name...] | --stop | --logs | --destroy"
    packages+=("$arg")
  done
  if [ "${#packages[@]}" -eq 0 ]; then
    local picked
    picked="$(pick "run" panel none)" || exit 1
    [ -n "$picked" ] && mapfile -t packages <<<"$picked"
  fi
  [ "${#packages[@]}" -gt 0 ] || die "nothing selected"

  local archives=() package archive
  for package in "${packages[@]}"; do
    archive="$(archive_for "$package")" || die "could not build an archive for $package"
    archives+=("$archive")
  done

  write_run_compose
  rm -f "$RUN_DIR"/extensions/*.c7s.zip
  cp "${archives[@]}" "$RUN_DIR/extensions/"

  run_compose up -d db cache
  run_compose up -d --force-recreate web

  printf '\ntest panel starting with only:\n'
  printf '  %s\n' "${packages[@]}"
  printf '\nurl      http://%s:%s\n' "$RUN_BIND" "$RUN_PORT"
  printf 'build    the first start compiles the panel with these extensions, follow it with: c7s run --logs\n'
  printf 'limits   %s RAM, %s compile jobs (RUN_MEMORY, RUN_JOBS)\n' "$RUN_MEMORY" "$RUN_JOBS"
  printf 'stop     c7s run --stop    remove everything: c7s run --destroy\n'
}

usage() {
  cat <<'USAGE'
c7s - git, export and import for Calagopus panel extensions

You develop inside the panel checkout, at backend-extensions/<identifier>.
c7s only moves that code in and out of git and builds archives.

  c7s status                              what the panel has that git does not
  c7s new     <package.name>              scaffold an extension and its repository
  c7s commit  [package.name...] [message] pull from the panel, commit and push
  c7s export  [package.name...]           build the .c7s.zip into <repo>/dist
  c7s release [package.name...] [tag]     export, commit and attach to a GitHub release
  c7s repo    [package.name...] [name]    create the GitHub repo and push
  c7s pull    [package.name...]           panel -> repository, without committing
  c7s install [package.name...]           repository -> panel (after a panel update)
  c7s install-all                         reinstall every extension into the panel

Commands that take [package.name...] accept several packages. Leave them out
to pick from a scrollable list instead (fzf if installed, otherwise whiptail).
commit ticks the extensions that have uncommitted panel changes for you.
  c7s update  [--discard] [--build]     git pull the panel, around your local changes
  c7s clone   <repo-name>               clone a repo and install it into the panel
  c7s run     [package.name...]           start a throwaway panel with only these extensions
  c7s run     --stop | --logs | --destroy stop it, follow its build, or delete it and its data
  c7s config                            show where c7s thinks everything is

Configuration, read from the environment or from
$XDG_CONFIG_HOME/c7s/config (default ~/.config/c7s/config):

  PANEL_DIR       panel checkout, defaults to the nearest one above $PWD
  EXTENSIONS_DIR  where repositories live (default <script dir>/extensions)
  GITHUB_USER     repo owner (default: the account gh is logged in as)
  REPO_PREFIX     repo name prefix (default c7s_extension_)
  REPO_VISIBILITY private or public, for repos c7s creates (default private)
  RUN_DIR         where the test panel lives (default ~/.local/share/c7s/run)
  RUN_PORT        its port (default 8090), RUN_BIND its address (default 127.0.0.1)
  RUN_MEMORY      its memory cap (default 6g), RUN_JOBS compile jobs (default 2)
  RUN_IMAGE       panel image (default ghcr.io/calagopus/panel:heavy)
USAGE
}

case "${1:-}" in
  pull|install|install-all|update|export|new|repo|commit|release|clone|status|list|run)
    resolve_panel_dir ;;
esac

case "${1:-}" in
  pull)        shift; run_many cmd_pull pull panel none "$@" ;;
  install)     shift; run_many cmd_install install repo none "$@" ;;
  install-all) shift; cmd_install_all "$@" ;;
  update)      shift; cmd_update "$@" ;;
  export)      shift; run_many cmd_export export panel none "$@" ;;
  new)         shift; cmd_new "$@" ;;
  repo)        shift; run_many cmd_repo repo panel none "$@" ;;
  commit)      shift; run_many cmd_commit commit panel changed "$@" ;;
  release)     shift; run_many cmd_release release panel none "$@" ;;
  clone)       shift; cmd_clone "$@" ;;
  status|list) shift; cmd_status "$@" ;;
  run)         shift; cmd_run "$@" ;;
  config)      shift; cmd_config "$@" ;;
  *)           usage ;;
esac
