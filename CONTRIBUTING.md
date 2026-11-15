# Contributing to OPDS Plus

First off, thank you for considering contributing to OPDS Plus! It's people like you that make OPDS Plus such a great tool for the KOReader community.

## Table of Contents

- [Contributing to OPDS Plus](#contributing-to-opds-plus)
	- [Table of Contents](#table-of-contents)
	- [Code of Conduct](#code-of-conduct)
	- [How Can I Contribute?](#how-can-i-contribute)
		- [Reporting Bugs](#reporting-bugs)
		- [Suggesting Enhancements](#suggesting-enhancements)
		- [Your First Code Contribution](#your-first-code-contribution)
		- [Pull Requests](#pull-requests)
			- [Pull Request Process](#pull-request-process)
	- [Style Guidelines](#style-guidelines)
		- [Lua Code Style](#lua-code-style)
		- [Git Commit Messages](#git-commit-messages)
		- [Documentation Style](#documentation-style)
		- [Wiki](#wiki)
	- [Development Setup](#development-setup)
		- [Prerequisites](#prerequisites)
		- [Setting Up Development Environment](#setting-up-development-environment)
		- [File Structure Understanding](#file-structure-understanding)
		- [Key Components](#key-components)
		- [Release Archive](#release-archive)
	- [Testing](#testing)
		- [Automated Tests](#automated-tests)
		- [Continuous Integration](#continuous-integration)
		- [Manual Testing](#manual-testing)
	- [Questions?](#questions)
	- [Recognition](#recognition)

## Code of Conduct

This project and everyone participating in it is governed by a code of respect and professionalism. By participating, you are expected to uphold this code. Please report unacceptable behavior to the repository owner.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates. When you create a bug report, include as many details as possible:

**Use the bug report template** (if available) and include:

- **Clear, descriptive title** for the issue
- **Exact steps to reproduce** the problem
- **Expected behavior** and what actually happened
- **Screenshots** if applicable
- **KOReader version** and device information
- **OPDS Plus version** (found in Settings → About)
- **OPDS catalog** you were browsing when the issue occurred
- **Log files** if available (enable Debug Mode in Developer settings)

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear, descriptive title**
- **Provide a detailed description** of the suggested enhancement
- **Explain why this enhancement would be useful** to most OPDS Plus users
- **List any similar features** in other applications if applicable
- **Include mockups or examples** if you have them

### Your First Code Contribution

Unsure where to begin? Look for issues labeled:

- `good first issue` - Simple issues that are good for newcomers
- `help wanted` - Issues where we need community assistance
- `documentation` - Documentation improvements

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Make your changes** following our style guidelines
3. **Test your changes**: run `luacheck .` and `scripts/test.sh` (see [Testing](#testing)); if you changed what runs in KOReader, try it there once
4. **Update documentation** only if you changed user-facing behavior
5. **Write clear commit messages** following our guidelines
6. **Submit a pull request** with a clear description

#### Pull Request Process

1. Ensure your code follows the [Lua style guidelines](#lua-code-style)
2. Run `luacheck .` (it must report 0 warnings and 0 errors) and `scripts/test.sh`
3. Test the behavior you changed: `scripts/test.sh` must pass. A bug fix gets the failing test first. Wiring, copy, label or docs changes get no spec — say why in the PR. Size the test to the change; fixes and refactors aim for a net-neutral diff
4. Update README.md/CHANGELOG.md only if user-facing behavior changed: a line under `## [Unreleased]`, existing format, maintainers raise the version
5. Fill in the pull request template. CI runs luacheck, the tests and a build of the release archive, and all of them must pass
6. Your PR will be reviewed by maintainers
7. Address any requested changes
8. Once approved, your PR will be merged

## Style Guidelines

### Lua Code Style

Follow KOReader's conventions: indent like the file you're editing (don't re-indent untouched lines), `snake_case` locals, `PascalCase` modules, `local` where possible. Wrap user-visible strings in `_("...")`. Keep `utils/` pure. `luacheck .` must report 0/0. Delete before you add; don't abstract ahead of a second call site.

### Git Commit Messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

- Start the subject with a type: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `perf:`, `ci:` or `chore:`
- Use the present tense and the imperative mood ("fix: keep the sync point", not "fixed" or "fixes")
- Keep the subject line to 50 characters or less
- Wrap the body at 72 characters, and use it to say what was wrong and why the change fixes it
- Reference issues and pull requests after the first line

**Example:**
```
fix: keep the sync point when editing a catalog

Saving the edit dialog dropped last_download, so the next sync went
through the whole feed again instead of reporting "Up to date!". Keep
it unless the address changed.

Fixes #123
```

### Documentation Style

- Say what you need to say, then stop
- Examples only where they clarify
- Update docs only for user-facing changes; don't document internals nobody asked about

### Wiki

The [wiki](https://github.com/t4rra/opds_plus.koplugin/wiki) is generated from `docs/wiki/`: when a change
there reaches `main`, `.github/workflows/wiki-sync.yml` replaces the wiki's pages with those files. Edit the
pages in `docs/wiki/` with a pull request, as with code; edits made in the wiki's web editor are overwritten by
the next sync. Link between pages by their file name without `.md` (`[Updating](Updating)`), and to images by
their `raw.githubusercontent.com` address on `main`.

## Development Setup

### Prerequisites

- KOReader installed on a device or emulator
- Basic understanding of Lua programming
- Text editor (VS Code, Sublime, vim, etc.)
- Git for version control
- For the automated tests: `python3`, `git`, `make`, a C compiler and `curl`
- [luacheck](https://github.com/lunarmodules/luacheck) for linting

### Setting Up Development Environment

1. **Clone your fork:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/opds_plus.koplugin.git
   cd opds_plus.koplugin
   ```

2. **Create a development branch:**
   ```bash
   git checkout -b feature/my-new-feature
   ```

3. **Link to KOReader plugins directory:**
   ```bash
   # Linux example
   ln -s $(pwd) ~/.config/koreader/plugins/opds_plus.koplugin

   # Or copy the directory
   cp -r . ~/.config/koreader/plugins/opds_plus.koplugin
   ```

4. **Enable Debug Mode:**
   - In KOReader: OPDS Plus → Settings → Developer → Debug Mode
   - This enables detailed logging for development

5. **Set up the test tools** (once; see [Automated Tests](#automated-tests)):
   ```bash
   scripts/setup_test_env.sh
   ```

6. **Make your changes** with a spec for the behavior they change (or a note on why not), and run `scripts/test.sh` and `luacheck .`

7. **Try it in KOReader**

8. **View logs:**
   - Check KOReader's crash.log for errors
   - Debug output appears in the log when debug mode is enabled

### File Structure Understanding

```
opds_plus.koplugin/
├── _meta.lua                 # Plugin metadata; the version comes from opds_plus_version.lua
├── main.lua                  # Plugin entry point and KOReader menu registration
├── opds_plus_version.lua     # Version number (single source of truth)
├── config/                   # Persistent settings (settings.lua) and the settings menu (settings_menu.lua)
├── core/                     # Catalogs, feeds, navigation, downloads, sync and shared state
│   ├── parsers/              # Feed parsers: Atom (OPDS 1) and JSON (OPDS 2.0)
│   └── mappers/              # Turn either parsed feed into the same menu items
├── models/                   # Constants
├── services/                 # HTTP client, cover cache and loaders, Kavita streaming, the self-updater
├── ui/                       # The browser (browser.lua), dialogs/ and the list, grid and cover menus/
├── utils/                    # Pure helpers: URLs, files, catalogs, headers, JSON, URI templates, versions
├── spec/                     # Automated tests (not part of the release archive)
├── scripts/                  # Test tooling and the release build (not part of the release archive)
├── tools/e2e/                # End-to-end kits in a headless KOReader (not part of the release archive)
├── docs/wiki/                # Source of the GitHub wiki (not part of the release archive)
└── .github/workflows/        # CI, release and wiki sync workflows
```

### Key Components

- **main.lua**: Plugin lifecycle and menu registration
- **core/parser.lua**: Tells Atom (OPDS 1) and JSON (OPDS 2.0) feeds apart by their content and hands them to `core/parsers/`
- **core/mappers/**: Turn a parsed Atom or OPDS 2.0 feed into the same menu items; `spec/integration/mapper_contract_spec.lua` holds both to one model
- **core/navigation_handler.lua**: Builds the menu from a feed's items, links, facets and search
- **core/feed_fetcher.lua**: Fetches feeds and OpenSearch descriptions, and keeps a cache of pages
- **core/download_manager.lua** and **core/sync_manager.lua**: Downloads and catalog sync
- **core/catalog_manager.lua** and **core/state_manager.lua**: The list of catalogs and the shared state behind the settings
- **services/http_client.lua**: HTTP requests and their redirects, including a catalog's custom headers
- **services/ota_updater.lua** and **ui/dialogs/update_dialog.lua**: The self-updater and its menu (see [SECURITY.md](SECURITY.md) for its trust model)
- **services/cover_cache.lua**, **cover_loader.lua** and **image_loader.lua**: Cover downloading and caching
- **ui/menus/**: List, grid and cover rendering
- **ui/dialogs/**: Book info, download, search and settings dialogs

### Release Archive

`scripts/build_release.py` builds `dist/opds_plus.koplugin.zip` (and a `.sha256` file) from an allow-list: the plugin files at the top level and the `config/`, `core/`, `models/`, `services/`, `ui/` and `utils/` directories. Tests, scripts and docs are left out. The script refuses to build when it finds Lua code outside its lists, so a new file can't be forgotten by accident:

- New plugin code in a new top-level file or directory: add it to `SHIPPED` in `scripts/build_release.py`
- A new top-level directory that is not plugin code, such as a tools directory: add it to `NON_RUNTIME` in `scripts/build_release.py` and in `spec/helper.lua`

```bash
python3 scripts/build_release.py               # writes dist/opds_plus.koplugin.zip
python3 scripts/build_release.py --tag v1.7.0-t4rra.1  # also checks the version and writes dist/RELEASE_NOTES.md
python3 -m unittest discover -s scripts        # the build script's own tests
```

**Cutting a release** (maintainers): raise `VERSION` in `opds_plus_version.lua` and the **Version** line near the top of README.md, turn `## [Unreleased]` in CHANGELOG.md into `## [X.Y.Z] - date` (with a new empty `[Unreleased]` above it and a link definition at the bottom), merge, then push an annotated `vX.Y.Z` tag. `release.yml` refuses a tag that does not match `VERSION` and the newest CHANGELOG entry, and publishes that entry as the release notes, which is also what **Check for updates** shows in KOReader. Write it for users.

## Testing

### Automated Tests

The tests are written for [busted](https://lunarmodules.github.io/busted/) and run under LuaJIT, the Lua that KOReader uses. They need neither KOReader nor a network connection: `spec/helper.lua` and `spec/support/` stand in for the parts of KOReader that the plugin calls (`UIManager`, `socket.http`, `DataStorage` and so on). Size tests to the change — a fix should not carry hundreds of lines of new spec; prefer deleting over adding.

**Set up once.** This builds a toolchain inside the repository (`.lua_env/` and `.tools/`, both ignored by git). Nothing is installed globally.

```bash
scripts/setup_test_env.sh
```

**Run:**

```bash
scripts/test.sh                              # unit and integration specs, what CI runs
scripts/test.sh spec/unit/url_utils_spec.lua # one file
scripts/test.sh --filter="parseFiletypes"    # tests whose name matches
scripts/test.sh --contract                   # only the contract specs, see below
scripts/test.sh --all                        # luacheck, then every spec
```

**Layout:**

```
spec/
├── unit/          one spec per module, with its dependencies replaced
├── integration/   several modules together, against fixture feeds and a fake HTTP layer
├── contract/      opt-in checks of the stand-ins against a real KOReader
├── fixtures/      sample OPDS feeds
├── support/       stand-ins for KOReader modules (UIManager, socketutil, DataStorage, ...)
├── vendor/        unmodified copies of KOReader's socket/url.lua and its XML parser (luxl)
└── helper.lua     helper.load(), helper.stub(), helper.reset() and friends
```

**Writing a test.** Match the test to the change. A bug fix gets the failing test first; changed behavior gets a spec of that behavior; wiring, copy, label or docs changes get none — say why in the PR. Load modules through `helper.load`, call `helper.reset()` around each test, and reuse the stand-ins in `spec/support/` instead of copying them into a spec. `spec/unit/url_utils_spec.lua` is the small example; the integration specs show the fake HTTP layer. Tabs, like most of the plugin. Fixture credentials are plain words like `secret` — GitGuardian flags anything else that looks like a password. Never a real credential.

**Contract tests.** The stand-ins are small, so they could drift from what KOReader really does. `scripts/test.sh --contract` checks them against a real KOReader in `KOREADER_DIR` (default `/usr/lib/koreader`). CI does not run these, because KOReader is not installed there, and they skip themselves when it is not found.

**End-to-end kits.** `tools/e2e/` drives the plugin inside a real, headless KOReader: catalog browsing against a mock OPDS server (`tools/e2e/catalog/run.sh`), the self-updater against a mock of GitHub (`tools/e2e/ota/run.sh`) and a smoke run against real catalogs (`tools/e2e/opds/live.sh`). CI does not run them either; see [tools/e2e/README.md](tools/e2e/README.md) for what each one checks and when to run it. `tools/e2e/catalog/screenshots.sh` regenerates the README screenshots.

### Editor Diagnostics (LuaLS)

The tracked `.luarc.json` configures LuaJIT, exact module roots and the bundled
Busted/Luassert metadata. Supplemental declarations in `tools/lua-ls/` describe
missing assertion aliases, callable assertions and the binary LuaSec X509 API;
they are editor-only and never enter the release archive. Tests and E2E drivers
remain checked. A few intentional test replacements have documented,
single-line diagnostic exceptions; production warnings are not disabled.

Use LuaLS 3.19.2 or newer (the Lua VS Code extension includes an executable).
Point `LUA_LANGUAGE_SERVER` at that executable if it is not on `PATH`:

```bash
LUA_LANGUAGE_SERVER=/path/to/lua-language-server scripts/check_lua.sh
# Optional: include informational/unused-local hints in the report
LUA_LANGUAGE_SERVER=/path/to/lua-language-server scripts/check_lua.sh --hints
```

The checker uses `KOREADER_DIR` (default `/usr/lib/koreader`) and creates the
ignored `.lua_env/koreader` symlink, which is also the editor's library path.
It refuses to replace an existing, differently configured path. This avoids
committing machine-specific editor settings or modifying `.vscode/settings.json`.
Run it once after cloning, then restart the Lua language server if the editor
has not picked up the libraries. Configuration is passed by absolute path so
CLI and editor checks use the same settings.

Generated reports and logs stay in `.tools/luals/`. The normal check fails for
errors/warnings; `--hints` also exits nonzero when hints exist. Unused parameters
in callback signatures are expected hints, not runtime failures. Do not disable
whole diagnostic categories to reduce the Problems count.
This is a local gate: CI does not currently install KOReader or LuaLS.

### Continuous Integration

`.github/workflows/ci.yml` runs on every pull request and every push to `main`:

| Job | What it does |
|-----|--------------|
| `lint` | `luacheck . --config .luacheckrc` |
| `test` | `scripts/setup_test_env.sh`, then `scripts/test.sh` |
| `package` | Tests `scripts/build_release.py`, builds the release archive with it, extracts it and runs the specs against the extracted copy, so a file missing from the archive fails the build |

All three must pass. `release.yml` runs the same workflow for a `v*` tag and publishes the archive that passed. `wiki-sync.yml` mirrors `docs/wiki/` to the wiki after a push to `main` (see [Wiki](#wiki)).

### Manual Testing

If your change alters what runs in KOReader, try it there once: browse a feed, download a book, check `crash.log`. Touch browsing or feed parsing? Try two or three catalogs (Gutenberg, Standard Ebooks, a local Calibre). Enable Debug Mode when you need logs. No fixed checklist — test what you changed, and say in the PR what you skipped and why.

## Questions?

Feel free to:
- Open an issue for discussion
- Ask questions in pull requests
- Reach out to the maintainer

## Recognition

Contributors will be recognized in:
- Git commit history
- Release notes
- README credits (for significant contributions)

---

Thank you for contributing to OPDS Plus! 📚✨
