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

die() { printf '%s\n' "$*" >&2; exit 1; }

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

cmd_status() {
  local dir package panel state
  [ -d "$EXTENSIONS_DIR" ] || die "no repositories at $EXTENSIONS_DIR"
  for dir in "$EXTENSIONS_DIR"/*/; do
    [ -f "$dir/Metadata.toml" ] || continue
    package="$(sed -n 's/^package_name = "\(.*\)"/\1/p' "$dir/Metadata.toml")"
    panel="$(panel_dir_of "$package")"

    if [ ! -d "$panel" ]; then
      state='missing from panel'
    elif diff -rq --exclude node_modules --exclude dist --exclude .git \
      "$dir/frontend" "$panel/frontend" >/dev/null 2>&1 &&
      diff -rq "$dir/backend/src" "$panel/src" >/dev/null 2>&1; then
      state='in sync'
    else
      state='panel has changes, run: c7s commit'
    fi

    printf '%-28s %s\n' "$package" "$state"
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
}

usage() {
  cat <<'USAGE'
c7s - git, export and import for Calagopus panel extensions

You develop inside the panel checkout, at backend-extensions/<identifier>.
c7s only moves that code in and out of git and builds archives.

  c7s status                            what the panel has that git does not
  c7s new     <package.name>            scaffold an extension and its repository
  c7s commit  <package.name> [message]  pull from the panel, commit and push
  c7s export  <package.name>            build the .c7s.zip into <repo>/dist
  c7s release <package.name> [tag]      export, commit and attach to a GitHub release
  c7s repo    <package.name> [name]     create the GitHub repo and push
  c7s pull    <package.name>            panel -> repository, without committing
  c7s install <package.name>            repository -> panel (after a panel update)
  c7s install-all                       reinstall every extension into the panel
  c7s clone   <repo-name>               clone a repo and install it into the panel
  c7s config                            show where c7s thinks everything is

Configuration, read from the environment or from
$XDG_CONFIG_HOME/c7s/config (default ~/.config/c7s/config):

  PANEL_DIR       panel checkout, defaults to the nearest one above $PWD
  EXTENSIONS_DIR  where repositories live (default <script dir>/extensions)
  GITHUB_USER     repo owner (default: the account gh is logged in as)
  REPO_PREFIX     repo name prefix (default c7s_extension_)
  REPO_VISIBILITY private or public, for repos c7s creates (default private)
USAGE
}

case "${1:-}" in
  pull|install|install-all|export|new|repo|commit|release|clone|status|list)
    resolve_panel_dir ;;
esac

case "${1:-}" in
  pull)        shift; cmd_pull "$@" ;;
  install)     shift; cmd_install "$@" ;;
  install-all) shift; cmd_install_all "$@" ;;
  export)      shift; cmd_export "$@" ;;
  new)         shift; cmd_new "$@" ;;
  repo)        shift; cmd_repo "$@" ;;
  commit)      shift; cmd_commit "$@" ;;
  release)     shift; cmd_release "$@" ;;
  clone)       shift; cmd_clone "$@" ;;
  status|list) shift; cmd_status "$@" ;;
  config)      shift; cmd_config "$@" ;;
  *)           usage ;;
esac
