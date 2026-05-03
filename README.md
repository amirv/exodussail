# Tracker Updater

This repository contains a small data-refresh pipeline:

- `update.sh` fetches a configured public KML feed.
- `convert.py` converts the KML into GeoJSON, CSV, and GPX.
- The GeoJSON file is published to a GitHub Gist through the GitHub REST API.
- `install-systemd.sh` installs a systemd service and timer to run the updater every 15 minutes.

The updater does not require the `gh` CLI. It uses a GitHub token read from a credential file.

## Requirements

- Linux system with `systemd`
- `bash`
- `curl`
- `python3`
- A GitHub token with permission to create and update gists

## Manual Run

`update.sh` expects a token file path in `EXODUSSAIL_GITHUB_TOKEN_FILE`.

Example:

```bash
export EXODUSSAIL_GITHUB_TOKEN_FILE=/path/to/github-token
./update.sh
```

The token file may contain either:

- A raw token on a single line
- `GITHUB_TOKEN=<token>`
- `GH_TOKEN=<token>`

On first run, the script creates a public gist and stores its ID in `.gist_id`. Later runs update that same gist only when `exodussail.geojson` changed.

## systemd Installation

Install the service and timer as root:

```bash
sudo ./install-systemd.sh --user "$USER"
```

This installs:

- `/etc/systemd/system/exodussail-update.service`
- `/etc/systemd/system/exodussail-update.timer`
- `/etc/exodussail/exodussail.env`
- `/etc/exodussail/github-token`

Then add the GitHub token:

```bash
sudoedit /etc/exodussail/github-token
```

If the file is empty during installation, the timer is enabled but not started. After adding the token, start the timer:

```bash
sudo systemctl start exodussail-update.timer
```

## Timer Behavior

The installed timer is configured to:

- Start a couple of minutes after boot
- Run every 15 minutes after the previous successful activation
- Catch up after downtime with `Persistent=true`

## Configuration

The service reads `/etc/exodussail/exodussail.env`. Supported variables:

- `EXODUSSAIL_GITHUB_TOKEN_FILE`
- `EXODUSSAIL_GIST_ID_FILE`
- `EXODUSSAIL_FEED_URL`
- `EXODUSSAIL_START`
- `EXODUSSAIL_END`
- `EXODUSSAIL_GITHUB_API`
- `EXODUSSAIL_GIST_DESCRIPTION`

The default environment file created by the installer sets the token file path and leaves the rest optional.

## Operations

Check timer status:

```bash
systemctl status exodussail-update.timer
```

Run once immediately:

```bash
systemctl start exodussail-update.service
```

Follow logs:

```bash
journalctl -u exodussail-update.service -f
```
