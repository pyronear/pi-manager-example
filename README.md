# pi-manager-example

Public **example** sister-repo for the
[`pi-manager-template`](../pi-manager-template) Ansible automation.

It is scoped to **engine stations only** — installing and updating the
wildfire-detection engine on a Raspberry Pi. Server roles (alert-api, platform,
annotation, mediamtx, openvpn…) are **out of scope**.

> ⚠️ **Everything in this repo is FAKE / placeholder data** — IPs, passwords,
> tokens, the vault password, the SSH keys. Use it to learn the layout, then
> create your own **private** `pi-manager-X` repo with real values.

---

## How it fits together

Two repos work as a pair:

| Repo | Role |
|------|------|
| `pi-manager-template` | the playbooks / roles / `make` targets (the engine code). You never edit it. |
| `pi-manager-example` (this repo) | the **inventory + vars + secrets** for *your* fleet. The template reads it through `REPO_PATH`. |

Provisioning one engine is **two steps**:

1. **Provision the Pi** with `scripts/setup_pi.sh` (runs *on* the Pi).
2. **Deploy the engine app** with `make deploy-one-engine` (runs from the
   template, pointed at this repo).

---

## Step 1 — Provision the Pi: `scripts/setup_pi.sh`

After flashing the SD card and booting the Pi, copy the script over and run it,
**passing the static IP** you want this Pi to have:

```bash
# from your laptop, <pi-dhcp-ip> = the address the freshly-flashed Pi got on DHCP
scp scripts/setup_pi.sh pi@<pi-dhcp-ip>:~

ssh pi@<pi-dhcp-ip>
sudo ./setup_pi.sh 192.168.1.99      # <- the static IP to assign to this Pi
```

This replaces the Ansible `rpi-init.yml` first-time init (which needs the
OpenVPN / mediamtx / reverse-ssh servers). It installs all the engine's system
dependencies — apt base, Docker + Compose, NetworkManager/Wi-Fi, OpenVPN
package, Grafana Alloy — and sets the static IP. The server-only steps (VPN
connection, stream registration, reverse-ssh tunnel) are skipped.

```bash
sudo ./setup_pi.sh 192.168.1.99                 # set static IP
sudo ./setup_pi.sh                              # use the default 192.168.1.99
sudo STATIC_IP="" WIFI_SSID="" ./setup_pi.sh    # keep DHCP, no Wi-Fi profile
sudo ./setup_pi.sh --help                       # all options
```

After it finishes, **reboot** the Pi — it comes back on the static IP you passed.
Put that same IP in `host_vars/example-station/vars.yml`
(`ansible_host` + `static_ip_address`) so Step 2 can reach it.

---

## Step 2 — Configure the API URL and credentials

On deploy, the engine logs in to the alert API and fetches one token per camera.
So before deploying you set **two things**:

### a) API URL — in *this* repo

`inventory/group_vars/envprod/vars.yml`:

```yaml
api_dns: "alertapi.example.org"      # <- your alert API host (no https://, no trailing /)
```

The engine role calls `https://<api_dns>/api/v1/login/creds`, so the API **must
be reachable over HTTPS** (put TLS in front of a local/test API).

### b) API admin credentials — in the *template* repo's `.env`

The admin login/password used to obtain the API token come from environment
variables, set in `pi-manager-template/.env`:

```bash
SUPERADMIN_LOGIN=<your api admin login>
SUPERADMIN_PWD=<your api admin password>
```

They must be valid on the API at `api_dns`.

### c) Camera & Pi credentials — vault files (this repo)

The camera and Pi passwords live in the (fake, encrypted) vault files:

- `inventory/group_vars/engine_servers/vars.vault.yml` → `CAM_USER`, `CAM_PWD`
- `host_vars/example-station/vars.vault.yml` → `ansible_password` (the Pi user's
  password), camera creds, etc.

Edit them with the vault password in `.vault_passwrd`:

```bash
ansible-vault edit host_vars/example-station/vars.vault.yml
ansible-vault view inventory/group_vars/engine_servers/vars.vault.yml
ansible-vault rekey <file>     # change the vault password
```

> The cameras in `host_vars/example-station/vars.yml` (`config_json`) must
> already exist in the API DB with the **same IDs** (`"1"`, `"2"`). Seed them
> with the `init_script/` helpers in the template repo, run against your API.

---

## Step 3 — Deploy the engine from the template

Point the template at this repo. In `pi-manager-template/.env`:

```bash
REPO_PATH=../pi-manager-example
VAULT_PASSWORD_FILE=../pi-manager-example/.vault_passwrd
SSH_PRIVATE_KEY_FILE=../pi-manager-example/id_rsa
LIMIT=example-station

SUPERADMIN_LOGIN=<your api admin login>
SUPERADMIN_PWD=<your api admin password>
```

Drop the SSH **private** key that can reach the Pi at
`pi-manager-example/id_rsa` (gitignored — never commit it).

Then, from the template repo:

```bash
cd ../pi-manager-template

make prepare                              # copies this repo's inventory/host_vars/group_vars in
cp -r group_vars/* inventory/group_vars/  # see "group_vars quirk" below
make deploy-one-engine SITE=example-station
```

> **group_vars quirk** — `make prepare` copies this repo's
> `inventory/group_vars/` into the template's **root** `./group_vars/`, but
> `ansible-playbook -i inventory/hosts_prod` (used by `deploy-one-engine`) reads
> group_vars from `inventory/group_vars/`. So after `make prepare` you must sync
> them: `cp -r group_vars/* inventory/group_vars/`. Otherwise stale group_vars
> are used and `check_vars` fails with "variable is empty".

`deploy-one-engine` runs `playbooks/deploy-engines.yml` (roles `check_vars`,
cron, `engine`, `engine_cron`). It does **not** touch the VPN / mediamtx /
reverse-ssh servers, so you only need:

1. **A network route to the Pi** — without the VPN, be on the same LAN and set
   `ansible_host` to its local IP.
2. **A reachable HTTPS alert API** at `api_dns` with the cameras seeded.
3. **Internet on the Pi** — to `git clone` pyro-engine and pull Docker images.

> Note: the template's `ansible.cfg` sets `check_mode = yes`, so runs are dry-run
> by default — remove that line for a real apply.

---

## Layout

```
pi-manager-example/
├── .vault_passwrd                  # vault password (FAKE — committed so the example runs)
├── id_rsa                          # SSH PRIVATE key to your Pi — NOT committed, you provide it
├── ansible.cfg
├── scripts/
│   └── setup_pi.sh                 # Step 1 — standalone Pi provisioning (takes the static IP)
├── ssh_keys/                       # public keys (only used by the full rpi-init path, not the example flow)
│   ├── mateo_to_pyrobastion.pub
│   └── felix_to_pyrobastion.pub
├── inventory/
│   ├── hosts_prod                  # one engine + minimal backing-server stubs
│   ├── host_vars/                  # (kept empty — host_vars live at repo root, see prepare)
│   └── group_vars/
│       ├── all/{vars.yml,vars.vault.yml}
│       ├── engine_servers/{vars.yml,vars.vault.yml}
│       └── envprod/vars.yml        # api_dns, S3, OpenVPN, mediamtx
└── host_vars/
    └── example-station/            # the example engine station
        ├── vars.yml                # config_json (cameras) + static IP
        └── vars.vault.yml          # credentials (FAKE)
```

> `make prepare` (in the template) copies `inventory/hosts*` → `./inventory/`,
> `host_vars` → `./host_vars`, and `inventory/group_vars` → `./group_vars`. That
> is why `host_vars/` lives at the repo root and `group_vars/` lives under
> `inventory/`.

## The example engine

`example-station`:
- `ansible_host: 192.168.1.42` (change to your Pi's address)
- `static_ip_address: 192.168.1.99` (the IP you passed to `setup_pi.sh`)
- two example PTZ cameras at `192.168.1.11` / `192.168.1.12` (IDs `1` / `2`)
