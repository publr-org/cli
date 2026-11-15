---
name: build-on-publr
description: Build on Publr (a site and app platform driven by the `publr` command): content types, plugins with operations and roles, apps with .publr templates, on a project here or on a Publr elsewhere (self-hosted or Publr Cloud). Use whenever the task is to make something with Publr rather than to work on Publr itself, including when the work seems to need a change in Publr core: this skill decides whether core may change and how (only generic extension points, always as a pull request to publr-org/publr).
---

# Building on Publr

Publr is a small core plus everything else as plugins on the same SDK a third party uses.
A project is **content** people manage in the admin, **plugins** (content types,
operations, roles: what is stored and done) and **apps** (what people use at an address:
templates read at runtime, never compiled). It is never a modified core.

## Start here, every time

1. **Find the site.** Run the `publr` command on the PATH (Homebrew
   `brew install publr-org/tap/publr`, `curl -fsSL https://publr.dev/install.sh | sh`, or the
   one Publr Studio installs). Never `./publr` or a binary inside a site's folder.
   - A folder with `publr.zon` (or a folder below one) is a site on this computer. Every
     command that is not the `publr` command's own (`new`, `ls`, `start`, `open`, …) goes to
     the Publr release that site runs, in the site's folder: `publr content list` from there
     is all it takes.
   - A folder with `.publr/site` builds the Publr that file names, running elsewhere (a
     server, Publr Cloud): every command from the folder goes to that site, no address or
     flag needed.
   - Neither: `publr ls` lists the sites on this computer; ask which one, or make one with
     `publr new <name>`.
2. **Read the guide the site's Publr carries:** `publr agents`. It describes
   exactly the Publr in front of you (its SDK, its permissions, how plugins and apps are
   built), so where it and this skill differ, it wins. Read it whole before changing
   anything.
3. **Find where the project runs.**
   - Here: `publr agents` ends by saying whether this site's server runs and at which
     address (what to open in a browser). If none runs, `publr start` runs it in the
     background (`publr open` opens its admin, signed in). While it runs, every other command
     from this folder goes to it: no address or flag needed.
   - Elsewhere (a server, Publr Cloud): a folder set up from the site's Overview is signed
     in and names it in `.publr/site`. Any other: `publr login <address>` prints a link its
     owner approves in that Publr's admin; then `publr --site <address> <command>`. Never
     ask for a password or a token.
   - To build on a site elsewhere (Publr Cloud or another server), work in a copy of it:
     `publr clone <address>` brings it down into a folder of its own, you work there, and
     `publr push` sends the work up as a branch for review. When done, give the person the
     review link `push` prints. Change the live site only when they ask, adding
     `--production` to that call.
4. **Plan before code.** Say what the people running the site will see in the admin and
   what visitors will see. Agree it with the person you work for.

## Decide where each need goes

Walk this ladder for every requirement. Stop at the first rung that works.

1. **It already exists.** `publr --help`, `publr <namespace> --help`, `publr <namespace>
   <verb> --help`, and the plugins installed (`publr --as-admin plugin list`; on a site
   elsewhere `publr plugin list`, since your device is who you are there).
   **Or Publr's marketplace has it.** Before building a feature, ask:
   `publr plugin find --request "<what your person asked, in their words>"`, then
   `publr plugin install --name <name>` for each plugin it answers (its requirements come
   with it). Each answers at once with an id; `publr job answer --id <id>` reads what
   landed, `waiting` until it does. Use what they bring; build only what none of them gives.
2. **It is content.** A content type, a field, a settings type: declared in a plugin (a
   `publr.record.define` in its one `publr.plugin.define` registration) and
   edited in the admin. Never a table of your own.
3. **It is a page.** A template in an app, a dynamic island for what is per visitor. A new
   frontend is a new app in the same project.
4. **It is behaviour.** An operation in a plugin (`publr.operation.define`, its words in
   doc comments), built with `publr plugin build` after `publr plugin check --dir
   plugins/<name>` passes. An operation is `<plugin>.<verb>`; one an app's visitors call
   says `.untrusted_callers = true`, and the app's pages reach it at
   `<mount>/_actions/app.<plugin>.<verb>`.
5. **Only core can make it possible.** A missing capability or extension point, never a
   missing feature of your project. Name the gap to the person, then follow
   [references/core-changes.md](references/core-changes.md).

Most needs stop at 2, 3 or 4. Reaching rung 5 is rare and must be justified in writing.

## Never

- Edit Publr core to make the project work, or ship a patched copy of it.
- Grant a plugin a permission yourself, or approve anything for the person: they approve
  in the admin. Finish by saying what waits and where.
- Delete anything for good on someone's behalf (a content type, a user, a plugin, records
  purged). A device is refused it anyway; say what should go.
- Keep a secret in the database, an app, a plugin's source or the repository.
- Weaken a check, a test or a permission to make something pass.

## Checklist before finishing

- [ ] Every requirement sits on the lowest rung of the ladder that works.
- [ ] No file of Publr core changed, or each change is a pull request per
      [references/core-changes.md](references/core-changes.md).
- [ ] The rules in `publr agents` ("How to build well") hold for every plugin and app.
- [ ] Every operation and field has its doc comment words; a call without permission is
  denied and changes nothing.
- [ ] `publr plugin check --dir plugins/<name>` passes for every plugin.
- [ ] The admin and the pages match what was agreed, checked in a browser.
- [ ] What waits for the person (permissions, drafts to publish, a branch to merge) is listed for them.
