# publr

One command for Publr sites on this computer and on Cloud. It makes, runs, clones and
deploys sites; each site runs the Publr release it pins (`.publr = "0.6.4"` in its
`publr.zon`), fetched and checked by the command when first needed. Inside a site's folder
every other command goes to that site's Publr, so `./publr` is never typed.

```
publr new shop            a site in ~/Publr, started, the admin opened signed in
publr ls                  every site in every listed folder, and where each stands against Cloud
publr start|stop|restart  one or more sites (stop --all)
publr open shop [path]    the admin in your browser, signed in (--print: just the link)
publr logs shop           the end of its server log
publr rm shop [--yes]     stop it and move it to its folder's .trash
publr upgrade shop        moved to the Publr Cloud runs, repaired first when it must be
publr init [<path>]       a folder made a site, or an existing one listed
publr config              the default folder and the other folders
publr versions            the Publr releases kept, which site runs which
cd ~/Publr/shop && publr content list    handed on to the site's Publr
```

Install: `brew install publr-org/tap/publr`, `curl -fsSL https://publr.dev/install.sh | sh`,
or Publr Desktop, which carries the same command and puts it on the PATH when it starts.

Config lives in `~/Library/Application Support/Publr` (macOS) or `~/.config/publr`
(`$PUBLR_CONFIG` overrides): `config.zon`, the releases kept (`versions/`), the sign-on key
every local site trusts, the helper's log. Each site keeps what this computer knows of it
(port, process) in its own `.publr/local.json`.

## Building

`zig build` (Zig 0.17.0) puts the command in `zig-out/bin/publr`; `zig build test` runs the
tests and the options rule of Publr's tidy (it reads `../publr/scripts/tidy.zig`). Desktop
links the core as the `publr_cli` module, which carries no compiler.

The command carries Zig's compiler for `plugin build` and `publr zig` (`publr_zig`,
`../lib/zig`: no LLVM, wasm32 only, about 8 MB packed). Building it takes minutes, so for
this computer the build takes `../lib/zig/zig-out/toolchain.tar.gz` when it is there
(`zig build toolchain` in lib/zig makes it); `-Dtoolchain-archive=<file>` names another, for
another target. It is written out once into `~/Library/Caches/Publr` (macOS) or
`~/.cache/publr` (`$PUBLR_CACHE_DIR` overrides).

`publr plugin build --name <n>` asks the Publr the site runs for the build (`plugin
prepare`: its SDK, the plugin's docs, views and the interfaces it builds against, and the
compiler's arguments), compiles, then has that Publr check the module (`plugin check
--file`) and install it. For a site elsewhere (`--site`) that Publr is a copy of the release
the site runs, and the module goes up in pieces.

Releases: Actions → Release (`.github/workflows/release.yml`) publishes the four binaries,
`install.sh` and `SHA256SUMS`, then rewrites the Homebrew formula
(`packaging/homebrew/publr.rb`) in `publr-org/homebrew-tap`.
