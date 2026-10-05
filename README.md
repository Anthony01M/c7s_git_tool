# c7s

Tooling for developing [Calagopus](https://github.com/calagopus/panel) panel extensions.
It moves an extension between the panel checkout you have to build it in and the git
repository you actually want to keep it in, and it builds the shippable archive.

## The golden rule

**You edit inside the panel checkout**, at `<panel>/backend-extensions/<identifier>/`.
The git repositories under `extensions/` are storage, not a workspace. `c7s commit` copies
the panel's version into the repository; nothing is ever edited in `extensions/` by hand.

This is not a style preference, it is forced by the panel's build. See
[Why the source has to live in the panel](#why-the-source-has-to-live-in-the-panel).

## Requirements

`bash`, `rsync`, `git`, and a Calagopus panel checkout with `panel-rs` built. `cargo` and
`pnpm` for `export`, [`gh`](https://cli.github.com) for anything touching GitHub.

## Install

```bash
git clone https://github.com/Anthony01M/c7s_git_tool.git
ln -s "$PWD/c7s/c7s.sh" /usr/local/bin/c7s
```

Then point it at your panel:

```bash
mkdir -p ~/.config/c7s
echo 'PANEL_DIR=/path/to/calagopus' >> ~/.config/c7s/config
c7s config
```

## Configuration

Read from the environment, or from `$XDG_CONFIG_HOME/c7s/config` (default
`~/.config/c7s/config`), which is sourced as shell. `C7S_CONFIG` overrides its location.

| Variable | Default |
| --- | --- |
| `PANEL_DIR` | the nearest panel checkout at or above `$PWD` |
| `EXTENSIONS_DIR` | `extensions/` next to `c7s.sh` |
| `GITHUB_USER` | the account `gh` is logged in as |
| `REPO_PREFIX` | `c7s_extension_` |
| `REPO_VISIBILITY` | `private`, for repositories `c7s` creates |

`c7s config` prints what all of these resolved to, which is the first thing to run when a
command cannot find something.

## What is where

| Path | What it is |
| --- | --- |
| `$PANEL_DIR` | The panel checkout. Third-party code, cloned from `pterodactyl-rs/panel`. **Never commit to it, never edit panel source.** |
| `$PANEL_DIR/backend-extensions/<identifier>/` | The working copy of an extension. This is where you write code. |
| `$EXTENSIONS_DIR/<repo>/` | The git repository for one extension. Written by `c7s pull`, read by `c7s install`. Not part of this repository. |
| `<repo>/dist/<identifier>.c7s.zip` | The built archive. Gitignored, this is what you install or distribute. |
| `$PANEL_DIR/exported-extensions/` | Where the panel drops archives. `c7s export` copies from here into `<repo>/dist`. |

Identifiers, packages and repository names are three views of the same thing:

| Form | Example | Used by |
| --- | --- | --- |
| Package name | `com.example.autologin` | `Metadata.toml`, every `c7s` command, route paths |
| Identifier | `com_example_autologin` | directory under `backend-extensions/`, crate name, archive name |
| Repository | `c7s_extension_autologin` | GitHub |

## Commands

| Command | What it does |
| --- | --- |
| `c7s status` | Per extension: in sync, panel has uncommitted changes, or missing from the panel. |
| `c7s new <package>` | Scaffolds via `panel-rs extensions init`, creates the repository, makes the first commit. |
| `c7s commit <package> [msg]` | **The one you use most.** Pulls the panel's version into the repository, commits, pushes if a remote exists. |
| `c7s export <package>` | Runs the panel's export (all its checks) and copies the archive to `<repo>/dist`. |
| `c7s release <package> [tag]` | Export, commit, then attach the archive to a GitHub release. Tag defaults to `v<version from Cargo.toml>`. |
| `c7s repo <package> [name]` | Creates the GitHub repo and pushes. Needs `gh` authenticated. |
| `c7s pull <package>` | Panel → repository, no commit. `commit` calls this for you. |
| `c7s install <package>` | Repository → panel, then `extensions resync`. |
| `c7s install-all` | Every extension back into the panel, then `pnpm install`. |
| `c7s update [--discard] [--build]` | `git pull` the panel past whatever you changed inside it. |
| `c7s clone <repo-name>` | Clone from GitHub and install into the panel. Takes `owner/name` too. |
| `c7s config` | Show where c7s thinks everything is. |

## Workflows

**I changed an extension, how do I get it into git?**

```bash
c7s commit com.example.autologin "fix: whatever changed"
```

That pulls from the panel, commits, and pushes. Run `c7s status` first if you want to see
what differs. Editing a file in `extensions/` directly is wrong — `c7s pull` overwrites it.

**I want a new extension.**

```bash
c7s new com.example.something
```

Then edit `<panel>/backend-extensions/com_example_something/` and `c7s commit` when done.

**I updated or reinstalled the panel and my extensions are gone.**

```bash
c7s install-all
```

Every extension is copied back and resynced. This is the reason the repositories exist —
you never have to hand-restore `backend-extensions/` after wiping the panel.

**The panel is out of date, and `git pull` says "Please commit your changes or stash them
before you merge".**

```bash
c7s update
```

Most of the time that message is not about anything you wrote. `extensions resync` and
`pnpm install` rewrite `Cargo.lock`, `backend-extensions/internal-list/` and
`frontend/pnpm-lock.yaml` every time you touch an extension, and those four files are the
whole reason the pull refuses. `c7s update` restores them from `HEAD`, fast-forwards, then
regenerates them with `extensions resync` and `pnpm install` — nothing is lost, because
nothing there was written by hand.

Panel source you did edit is **stashed**, listed before it goes, and comes back with:

```bash
git -C <panel> stash pop
```

`--discard` throws those edits away instead of stashing them, for when the panel is dirty
because you were poking at it and you know you want none of it. `--build` also runs
`SQLX_OFFLINE=true cargo build -p panel-rs`; without it you get the command printed at the
end to run yourself.

Your extensions are untracked in the panel's git repository, so neither the pull nor the
stash can touch `backend-extensions/<identifier>/`. If a pull ever does clobber one,
`c7s install-all` puts it back.

Only a fast-forward is attempted. If it fails, the checkout has local commits — you were
not supposed to commit to the panel, and the error tells you how to reset it.

**I want a shippable archive.**

```bash
c7s export com.example.autologin     # -> <repo>/dist/com_example_autologin.c7s.zip
c7s release com.example.autologin    # same, plus a GitHub release
```

Install it on a panel with:

```bash
panel-rs extensions add com_example_autologin.c7s.zip
panel-rs extensions apply --profile balanced
```

`panel-rs extensions add` and `update` take a **file path only** — never a URL. To install
from GitHub you download the release asset first.

## Layout

The panel wants the crate at the extension root. The repository (and the `.c7s.zip`) put it
under `backend/`. `c7s pull` and `c7s install` translate between the two:

```
panel: backend-extensions/<identifier>/    repo: extensions/<repo>/
├── Cargo.toml                             ├── backend/Cargo.toml
├── src/                                   ├── backend/src/
├── Metadata.toml                          ├── Metadata.toml
├── frontend/                              ├── frontend/
└── migrations/                            ├── migrations/
                                           └── dist/
```

## Why the source has to live in the panel

Three separate mechanisms break if the real path of an extension is outside the panel checkout.
All three were tested; this is not theoretical.

- **Vite resolves symlinks to their real path.** A symlinked extension is compiled as if it
  lived at its real location, so `node_modules` resolution fails for `react`, `@fortawesome/*`
  and `@mantine/*`.
- **The `@/…` alias** is scoped to the panel's tsconfig. An importer outside the tree loses it,
  so `@/elements/…` stops resolving even after `node_modules` is fixed.
- **pnpm's workspace** (`packages: ['extensions/*', '../backend-extensions/*/frontend']`) links
  `shared` with a relative path that breaks when the directory moves.

Symlinking the other way does not work either: `panel-rs extensions export` does not follow a
symlinked `src`, and fails with *"unable to find file `backend/src/lib.rs`"*.

Hence: copy in, copy out.

## Gotchas

- **`cargo fmt --check` fails after any `extensions init`, `remove` or `resync`.** The generated
  `backend-extensions/internal-list/src/lib.rs` is written unformatted (rustfmt collapses a
  single-element `vec!`). `c7s export` runs `cargo fmt -p extension-internal-list` first.
- **`panel-rs extensions init` is interactive.** With no TTY it panics on the template prompt.
  Drive it with `printf '\n' | script -qec "…" /dev/null`.
- **Package names are validated strictly:** exactly three dot-separated segments, tld 2–6 chars,
  author 3–30, identifier **4+** — `com.example.sso` is rejected, `com.example.autologin` is fine.
- **`extensions export` runs `cargo fmt --check`, `pnpm biome:validate` and `pnpm build:ci`.**
  All three must pass. Answer the "check before exporting" prompt with yes.
- **Code style: no comments, no semicolons in TypeScript.** Semicolons are off via a nested
  `frontend/biome.json` (`"root": false`, `semicolons: asNeeded`) that ships inside each
  extension, so the panel's own biome config is untouched. Rust keeps semicolons — the language
  requires them.
- **Never edit panel source.** Extensions attach through the registry and hookable components.

## License

MIT, see [LICENSE](LICENSE).
