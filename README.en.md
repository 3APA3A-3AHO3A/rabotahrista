# rabotahrista

[Русский](README.md) | **English**

A Remnawave node installer for a VPS: admin account and SSH hardening, a
separate account for AI agents, firewall, fail2ban, kernel tuning, Docker, the
node container with Loyalsoldier geo databases and their daily update, egress
routes for Xray (WARP on port 6000, warp-native, Psiphon), a Let's Encrypt
certificate, nginx config and Telegram notifications.

One downloaded file covers the whole life of a node: installation, diagnostics,
targeted repair, domain change.

## Installation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/setup.sh -o /tmp/setup.sh
sudo bash /tmp/setup.sh
```

Root is required. Two common traps:

* `sudo bash <(curl ...)` **does not work**: sudo closes extra file
  descriptors, and process substitution is exactly such a descriptor. Already
  as root, `bash <(curl -fsSL .../setup.sh)` works: before moving into tmux the
  script saves itself to `/root/rabotahrista-setup.sh`, because inside tmux it
  cannot read itself back from the `/dev/fd/NN` pipe;
* `curl` without `sudo` fails with `Failure writing output to destination` if
  `/tmp/setup.sh` is left over from a root run. `/tmp` is sticky, someone
  else's file cannot be overwritten, and the **old** copy of the script runs.

The script asks all questions up front and then works silently. At the end it
prints a report and saves it to `/root/node-install-report.txt`:

* the login command (by IP — behind the Cloudflare orange cloud SSH via the
  domain does not work), the account password and the ED25519 host key
  fingerprint ssh will ask about on the first login;
* ready Xray outbounds for the routes actually working on the node
  (warp-native, WARP on 6000, Psiphon) — to paste into the node profile in the
  panel;
* a ready ssh-mcp profile (`config.toml`): IP, port, the agent account (or the
  admin one if there is no agent) and `trustedHostKey`. You fill in the key
  path yourself.

### What happens before the first question

Installation starts with server checks — no point asking questions if the work
is bound to fail:

* Debian or Ubuntu, kernel and OS version;
* free space on `/` (under 2 GB — refusal, under 5 GB — warning);
* memory, DNS and repository reachability, presence of `sshd`;
* the year on the clock — a skewed clock means Let's Encrypt refuses with an
  unclear error;
* whether `cloud-init` has finished and whether apt is held by another process.

The last one is the most common failure on fresh servers. On first boot
cloud-init installs updates itself and holds dpkg. The installer waits for it,
waits for the foreign apt, and runs all its own apt calls with
`DPkg::Lock::Timeout=600`, i.e. waiting for the lock instead of failing at once.
They also run with `--force-confdef --force-confold`: if a package's config
file was changed, dpkg keeps ours instead of asking a question nobody can
answer.

apt being busy is detected by the lock files themselves (`fuser`), not by
process names: Ubuntu always runs the `unattended-upgrade-shutdown` daemon,
which waits for shutdown, and a name search would consider apt busy forever.

If packages still fail, installation **stops at that step** without touching
SSH: without packages there will be no node, no certificate, no fail2ban, and
continuing would produce six failures with one cause and a report half of which
is untrue.

### A dropped ssh does not kill the installation

Installation takes minutes, and connections drop. The script restarts itself
inside `tmux` (installing it if missing) and says so. If ssh drops, the work
continues, and you can return to it:

```bash
sudo tmux attach -t rabotahrista
```

Questions work as usual: it is the same terminal. The restart does not happen in
a non-interactive run (`ssh server 'bash setup.sh ...'`, cron), inside an
already open tmux or screen, or with `RH_NO_TMUX=1`.

Exactly one installer runs on a server at a time — a second run is rejected with
a hint on how to attach to the first.

### What the output looks like

One live line per step on screen: what is being done and for how long. Detailed
output (apt with its two hundred packages, docker, certbot) goes to
`/var/log/node-setup.log`. On failure the last lines of output are printed
immediately — no need to dig in the log.

Colours switch off automatically when output is not a terminal, and with the
standard `NO_COLOR` variable.

Non-interactively, with an answers file (template — `config.example.conf`):

```bash
sudo bash /tmp/setup.sh /root/node.conf
```

In this mode an empty or invalid required value (`DOMAIN`, `SUBDOMAIN`,
`PANEL_IP`, `REMNA_SECRET`, `CF_API_TOKEN` with `SETUP_CF="y"`) stops the
installation with a clear message before anything is changed.

## Main menu

| Item | What it does | Changes the system |
|---|---|---|
| 1. Full installation | Installs the node from scratch: all steps in a row, reboot at the end | Yes, everything |
| 2. Components | One step of your choice — see below | Yes, the chosen one |
| 3. Diagnostics | Checks about forty things and prints a list of problems | No |
| 4. Repair | Shows a plan, asks, then fixes typical breakages | Yes, after confirmation |
| 5. Diagnostics + renewal | Same as 3 plus `certbot renew --dry-run` | No |

The same without the menu, when you have many nodes:

```bash
sudo bash /tmp/setup.sh --check     # diagnostics
sudo bash /tmp/setup.sh --repair    # repair without questions
```

A typical node round: **3** → look → **4** → **3**.

### How repair differs from installation

Full installation sets everything up again: resets ufw rules, recreates the
container, installs packages and reboots. There is no need to run it over a
working node.

Repair goes through a short list of typical breakages. From the menu it first
prints a plan — what exactly will be done and what is skipped — and waits for an
answer: `y` run everything, `s` go step by step and choose, `N` cancel. The
`--repair` flag prints the plan too but does not ask: it is meant for going
through a fleet of nodes.

The list is closed:

| Step | Condition |
|---|---|
| Mode 600 on files with secrets | Always |
| SSH hardening | Only if `sshd -T` shows root login or passwords open |
| `docker` group for the admin account | If missing |
| Notification scripts and systemd units | If Telegram is configured on the node |
| Panel watcher | If the node is on duty |
| Service script check | Always |

Repair **does not touch** the firewall, container, packages or nginx and **does
not reboot** the server. For nginx it prints a recommendation of what to fix and
how.

### Components menu (item 2)

| | | |
|---|---|---|
| 1. Cloudflare WARP | 2. Docker | 3. Node (redeploy) |
| 4. Web: certificate + nginx config | 5. UFW | 6. Sysctl tuning |
| 7. Swap | 8. User + SSH hardening | 9. Speedtest CLI |
| 10. Disable IPv6 (GRUB) | 11. Telegram notifications | 12. fail2ban |
| 13. Security auto-updates | 14. Disk protection (log rotation) | 15. Update node |
| 16. Node status | 17. bench.sh | 18. ipregion |
| 19. censorcheck | 20. Update system (+ reboot) | 21. Panel watcher on |
| 22. Panel watcher off | 23. Change node domain | 24. AI agent account |
| 25. Geo databases + daily update | 26. warp-native | 27. Psiphon |

Item 2 adds the admin account to the `docker` group even if Docker was installed
before the script — otherwise `docker ps` answers `permission denied`.
Membership is picked up only in a new SSH session. It grants no extra rights:
the account already has passwordless `sudo`.

Item 8 is the only one that performs the initial SSH hardening: it asks for a
public key, validates it with `ssh-keygen` and only then disables password
login. Item 4 shows the full nginx config before writing it and waits for
confirmation.

## nginx

The script treats nginx as foreign territory: another site may live next to the
node on the same server.

| Situation | Behaviour |
|---|---|
| Repair (item 4, `--repair`) | Touches nothing. Prints the state, the ready config, the diff against the current one and three commands |
| Manual edit (item 2 → 4, domain change) | Shows the same and waits for `y` |
| Installation on an empty nginx | Writes itself: no config, no sites |
| Installation where foreign configs already exist | Does not write, prints a recommendation |

Rules that always apply:

* the node domain is taken from an enabled nginx config that has its own
  certificate. If there are several certificates and no proof, the script
  picks nothing and names the candidates;
* there can be only one `default_server` stub on `127.0.0.1:8443`. If a
  neighbouring config holds it, the script does not add its own;
* its own files are marked with a marker line at the top. A file without the
  marker is copied to `*.bak.<date>` before being overwritten;
* if `nginx -t` fails, the config is restored from the copy, and without a copy
  it is unpublished so that nginx keeps working.

### The stock default site

The nginx package installs its own `default` site, and the script **removes**
it — from both `sites-available` and `sites-enabled`. This is the only thing
the script does in nginx on its own, for two reasons:

* `default` listens on `[::]:80`. The "Disable IPv6" step puts
  `ipv6.disable=1` into GRUB, after a reboot there is no IPv6 stack, and nginx
  does not start at all because of that line (`Address family not supported by
  protocol`). On a repeated installation this breaks even package installation:
  dpkg leaves nginx half-configured;
* it takes `default_server` on port 80 and serves "Welcome to nginx" on the bare
  IP.

`sites-available/default` is a package conffile, and dpkg does not put a deleted
conffile back on upgrades. The copy goes to `/etc/rabotahrista/backup` — outside
the nginx directories, otherwise nginx would read it as one more site.

`default` is removed right after package installation, when disabling IPv6 and
on a manual nginx edit (this is shown in the plan). Repair offers to remove it
only if nginx is actually down because of it. Your own sites with `listen [::]`
are not edited, but they are named and the IPv6 step turns red: after a reboot
nginx will not start because of them.

The domain from `install.conf` takes priority over detection. If the wrong
domain got there, fix it by hand:

```bash
sudo grep -E '^(DOMAIN|SUBDOMAIN)=' /etc/rabotahrista/install.conf
```

## Certificate

Issuing and renewal go through the webroot `/var/lib/letsencrypt`. The
certificate is issued only if `/.well-known/acme-challenge/` is already served
to the outside: the script places a random token there and requests it over the
internet. If it does not arrive, the script prints the needed piece of config
and stops without changing anything. The exception is an empty server: there
the HTTP part of the node config is published first, otherwise nobody would
serve the token.

The check is done this way rather than by comparing IPs because behind the
Cloudflare orange cloud the IP never matches, and that does not prevent issuing.
The TLS block of the config also has the ACME path — with "Always Use HTTPS" the
renewal check arrives over HTTPS, and without it renewal silently fails in about
60 days.

Early versions issued the certificate with the `--nginx` plugin, and such nodes
still renew with it: the plugin edits the config itself for the duration of the
check. Diagnostics reads `authenticator` from
`/etc/letsencrypt/renewal/<domain>.conf`. The quick run (item 3) warns in this
case that the method is not ours and not verified; item 5 runs a real
`certbot renew --dry-run` — and if it passes, the complaint is withdrawn: a
working renewal does not need changing.

## Node version

During installation the script asks for the `remnawave/node` image version
(`REMNANODE_VERSION` in the answers file). An empty answer means `latest`. A
specific version is needed when a fresh one breaks something and the node is
rolled back: with `latest` any reinstallation would bring the broken version
back.

* if the node already runs a pinned version, the script reads it from
  `docker-compose.yml` and offers it as the default — Enter does not undo the
  rollback;
* "Update node" (item 2 → 15) updates exactly the recorded version; to change
  the version use "Node (redeploy)" (item 2 → 3), which asks for it again;
* in the answers file an empty version means `latest`: to keep a rollback when
  reinstalling from the file, set the version explicitly.

## AI agent account

For Claude and other agents that come to the server over SSH via MCP — a
separate account, not yours. It is created only if an agent key is set
(`AGENT_SSH_KEYS` in the answers file or a question during installation; from
the menu — item 2 → 24). Default name is `agent` (`AGENT_USER`).

* key-only login, no password; passwordless `sudo` and the `docker` group —
  the agent fixes and installs the same things a human does;
* the account is a member of the `rh-agents` group. Because of it the login
  notification says "🤖 AI agent login" instead of the usual "SSH login" and
  arrives silently;
* the sudoers file is named `91-agent-<name>`: the installer finds the human
  admin account by `90-*`, and the agent will not replace it;
* to revoke the agent's access: `sudo deluser --remove-home <name>`, your own
  account is not affected.

Extra keys for **your own** account (a second computer) go to `SSH_EXTRA_KEYS`,
one per line.

## Geo databases

The node image ships its own `geoip.dat` and `geosite.dat`, but they are updated
only together with the image. The script places fresh
[Loyalsoldier](https://github.com/Loyalsoldier/v2ray-rules-dat) databases in
`/opt/remnanode/geodata/` and mounts them into the container over the built-in
ones. Enabled by default (`GEODATA="y"`), from the menu — item 2 → 25.

Once a day at night UTC (each node gets its own minute) cron runs
`/usr/local/bin/rh-geodata-update.sh`:

* it compares sha256 with the published checksum — no changes, nothing happens;
* new databases are downloaded to a temporary file and swapped in only after the
  checksum is verified: a broken or partial database never reaches the node;
* after the swap it restarts the node container and posts a silent Telegram
  message. The restart is marked as planned — no "node is down" alert fires.

Log — `/var/log/rh-geodata.log`. Diagnostics shows the age of the databases and
warns if they have not been updated for more than a week.

## Egress routes for Xray: WARP, warp-native, Psiphon

Three independent routes, each enabled by its own question during installation
or a variable in the answers file:

| Route | Variable | How it works | Menu |
|---|---|---|---|
| Cloudflare WARP | `INSTALL_WARP` | official `warp-cli` in proxy mode, SOCKS5 on `127.0.0.1:6000` | 2 → 1 |
| [warp-native](https://github.com/distillium/warp-native) | `INSTALL_WARP_NATIVE` | WARP as the `warp` interface over WireGuard; in Xray — `sockopt.interface: "warp"`, `mark: 51888` | 2 → 26 |
| [Psiphon](https://github.com/Chara-Freedom/vps-psiphon) | `INSTALL_PSIPHON` | SOCKS5 on port 1080 (the `docker0` gateway address, usually `172.17.0.1`) | 2 → 27 |

* WARP on 6000 is connected only after checking that the client is really in
  proxy mode: in the regular mode it would route all server traffic, SSH
  included, into the tunnel, and the server would drop off the network;
* warp-native and Psiphon are installed by their authors' installers straight
  from GitHub — the script answers their questions (warp-native: Russian
  language, no WARP+, watchdog every 5 minutes) and checks the result: traffic
  through the `warp` interface exits via Cloudflare (`warp=on`), a site opens
  through the Psiphon SOCKS;
* warp-native does not work on a server in Russia — the step is skipped with an
  explanation, RU nodes keep WARP on 6000;
* Psiphon is installed with `--no-http --bulk-test-mb 0` and
  `MIN_THROUGHPUT_KBPS=0` in `/etc/default/vps-psiphon`. The exit country is
  `PSIPHON_REGION`; empty means the server's country, which the script gets
  from Cloudflare. For countries vps-psiphon never exits in (RU, BY and others)
  no country is set — Psiphon picks one itself;
* a repeated installation leaves already working warp-native and Psiphon alone;
  menu items 26 and 27 reinstall them forcibly.

Diagnostics checks all three: the `warp` interface and the Cloudflare exit, the
`vps-psiphon` service and its port.

## Server host keys

Some hosting providers ship an image with ready-made SSH host keys — identical
on every server built from that image (example: keys signed
`root@ns31561980`, the name of the build machine). The "Server keys" step
notices such keys by a foreign host name in the key comment and generates new
ones; the old ones are copied to `/etc/rabotahrista/backup/`. This happens once
in the life of a server. After that ssh asks you to confirm the new fingerprint
on the first login — it is printed in the step output.

## Notifications and monitoring

Set up with item 11. They go to Telegram with a "node name and IP" header, so
that with several nodes it is clear which one is meant:

* the node went down or came back up (`rh-node-watch`, `rh-node-health`);
* the server booted;
* someone logged in over SSH (an AI agent login is labelled separately and
  arrives silently);
* geo databases were updated and the node restarted.

The **panel watcher** (item 21) is enabled on **one** node on duty, otherwise
all nodes write at once when the panel goes down. The connection is one-way:
the panel connects to the node itself and holds TCP connections. The node
watches for them to disappear and additionally knocks on the panel's port — this
catches the case when the panel is dead but the sockets hang in ESTABLISHED. The
alarm fires after three failures in a row, about 6 minutes: a panel restart
survives this, a real outage does not.

## Files on the server

| Path | Contents |
|---|---|
| `/root/node-install-report.txt` | Installation report: access, password, package versions |
| `/var/log/node-setup.log` | Full installation log |
| `/etc/rabotahrista/install.conf` | Saved answers for future runs |
| `/etc/rabotahrista/notify.env` | Telegram tokens and node name |
| `/etc/rabotahrista/panel.env` | Panel watcher settings (only on the node on duty) |
| `/opt/remnanode/docker-compose.yml` | Container configuration, contains SECRET_KEY |
| `/opt/remnanode/geodata/` | Loyalsoldier geo databases, mounted into the container |
| `/etc/cron.d/rh-geodata` | Daily geo database check |
| `/var/log/rh-geodata.log` | Geo database update log |

All of them have mode 600. The node directory is 750 with the `docker` group:
the admin account and the agent enter it without sudo, while
`docker-compose.yml` with the secret stays 600. Repair puts permissions back in
order.

## Development

`setup.sh` and `check.sh` in the root are **not edited by hand** — they are
built files. A single self-contained script must arrive on a clean server, so
the sources live in `lib/` and the builder concatenates them.

```
lib/00-header.sh      shell modes, error handler, all settings
lib/05-ui.sh          palette, headings, status icons
lib/06-spinner.sh     live step line with a timer (separate: writes a temp file)
lib/07-probes.sh      read-only probes shared by installation and diagnostics
lib/10-helpers.sh     step summary and final report
lib/20-prompts.sh     all user questions and input validation
lib/30-state.sh       saving answers between runs, sending to Telegram
lib/40-system.sh      swap, packages, sysctl, IPv6, log rotation, auto-updates
lib/45-preflight.sh   server checks, waiting for cloud-init and apt, tmux, lock
lib/50-security.sh    user, AI agent account, host keys, SSH hardening, UFW, fail2ban
lib/60-node.sh        Docker and the remnanode container
lib/62-geodata.sh     Loyalsoldier geo databases and their daily update
lib/70-web.sh         certificate, Cloudflare DNS, nginx config
lib/75-domain.sh      node domain change
lib/80-notify.sh      Telegram notifications and watcher services
lib/82-panel.sh       panel watcher on the node on duty
lib/85-extras.sh      WARP, speedtest, external diagnostics
lib/86-egress.sh      warp-native and Psiphon — egress routes for Xray
lib/90-install.sh     step order of a full installation
lib/92-repair.sh      repair
lib/94-check.sh       diagnostics
lib/95-menu.sh        menu
lib/99-main.sh        entry point (always last)

build.py              builds setup.sh and check.sh
.githooks/pre-commit  build and tests before every commit
tests/                checks that need no server
```

Files are concatenated in alphabetical order of names — hence the numbering.
`setup.sh` is built from all modules, `check.sh` from `94-check.sh`, the
`05-ui.sh` styling, the `07-probes.sh` probes and the settings block of
`00-header.sh`, so the same code runs in the menu and in the standalone file.
The spinner lives in a separate module for exactly this reason: it creates a
temp file, and `check.sh` must not write anything to disk, which is enforced by
a test.

### Workflow

Once per repository:

```powershell
git config core.hooksPath .githooks
```

Then:

```powershell
# edit the module you need in lib/
git add -A
git commit -m "..."     # the hook builds setup.sh and check.sh and runs the tests
git push
```

The hook adds the rebuilt files to the same commit. Red tests cancel the
commit. To bypass in an emergency: `git commit --no-verify`.

CI on GitHub does the same but **commits nothing**, so no `git pull` is needed
after a push.

Build and check by hand:

```powershell
python build.py
bash tests/run-tests.sh
```

### Tests

`bash tests/run-tests.sh` — 32 groups, 134 checks, no server needed.

Besides syntax and `shellcheck`, it checks that:

1. Built files match `lib/`, line endings are LF, generated scripts have their
   shebangs.
2. No function ends with a bare condition.
3. Installation steps ask no questions — all questions are asked up front.
4. Prompt functions return 0 when there is nothing to ask.
5. Garbage in `ADMIN_USER` and `SSH_PORT` falls back to defaults.
6. Node and WARP ports are never hard-coded around the variables.
7. A failure inside a function prints the command and function name; a failing
   component does not kill the menu.
8. Saved answers are not executed as commands on the next run.
9. Ports are compared exactly, not by substring (22220 is not 2222).
10. A broken SSH key is rejected before password login is disabled.
11. Diagnostics changes nothing and does not disarm the installer's error
    handler.
12. Repair touches SSH exactly when hardening has been lost.
13. The node domain is not chosen as "first alphabetically".
14. Repair does not edit nginx; a manual edit writes nothing without
    confirmation.
15. A certificate is not issued until the ACME path is served to the outside.
16. The admin account gets into the `docker` group even if Docker was there
    before.
17. Repair prints the plan and does nothing without `y`; `--repair` does not
    ask.
18. Step output ends up in the log, and step variables survive to the report.
19. A package installation failure stops the installation without touching SSH.
20. The Docker step turns red if docker never appeared on the system.
21. Step labels are truncated by characters, not bytes (Cyrillic is not torn).
22. A successful step's output is visible only in the log; the screen stays
    clean.
23. Server checks do not let installation proceed without apt, disk space or
    DNS.
24. The tmux restart does not fire without a terminal, inside tmux or with
    `RH_NO_TMUX=1`; a second concurrent installer is rejected.
25. The double-run lock is taken after moving into tmux and does not swallow
    stderr.
26. apt busyness is detected by lock files: the permanent
    `unattended-upgrade-shutdown` daemon does not count as busy.
27. A stopped installation does not draw the crash frame and does not kill the
    menu.
28. A step under the spinner does not wait for terminal input.
29. The stock nginx `default` site is removed from both directories and breaks
    neither package installation nor nginx after a reboot; foreign sites are not
    edited.
30. Panel watcher: five scenarios from "all good" to "server alive, node not
    connected".
31. Geo databases: the first download places the files, nothing is re-downloaded
    without changes, a database with a mismatching checksum does not replace
    the working one.
32. The agent account name cannot be root or the admin account, its sudoers file
    is not confused with the admin one, an agent login is labelled separately;
    `SETUP_CF=y` without a token in the answers file stops the installation
    instead of hanging it.

Each check catches a bug that has already happened on a live node or was found
in code review before release. Tests do not depend on the machine they run on:
Windows has neither `apt-get` nor root, and the suite must be green there too —
otherwise the hook will not let the commit through.

## If something went wrong

The script prints crash details: command, function, line and exit code. Each
step is isolated — one failing step does not bring down the others, it is marked
`[СБОЙ]` (failed) in the final summary.

The output of every step goes both to the screen and to
`/var/log/node-setup.log`. This matters: the final report clears the screen,
and earlier the failure explanation disappeared with it — the summary said "see
the log", and the log had nothing about that step.

**SSH hardening** is protected separately. After restarting sshd the script
checks the effective values (`sshd -T`) and distinguishes three outcomes:
everything applied; the config was accepted but the port will work after a
reboot (UFW keeps the old port open meanwhile); the config is not read at all —
then the hardening is rolled back while the current session is still alive. On
Ubuntu 22.10+ with socket-activated SSH (`ssh.socket`) the `/run/sshd`
directory exists only while the service runs; the script creates it before
`sshd -t`/`sshd -T`, otherwise the check would fail on a valid config.

Worth knowing: sshd takes the **first** value of a directive it meets, and
drop-ins in `/etc/ssh/sshd_config.d/` are read alphabetically. A hosting file
named like `00-*.conf` overrides our `01-hardening.conf` — after a server
rebuild root login may be open again. Diagnostics names such files, repair
comments them out with a backup and restarts sshd.
