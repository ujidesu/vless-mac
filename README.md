# vless-macos
Shell script to run xray from a subscription link

```markdown
# Xray Reality Auto-Setup Script (macOS)

Simple bash script that:
- Fetches a vless+reality subscription
- Generates an Xray config with ad-blocking + anti-leak
- Sets system SOCKS proxy automatically
- Starts Xray and waits for `q` to quit

Made for lazy tech people who hate manual config bullshit.

## Features

- Saves subscription URL to `config.ini` (remembers it next time)
- Optional ad & tracker blocking (`geosite:category-ads-all`)
- Optional private IP blocking (anti-leak protection)
- Auto installs xray + jq if missing
- Enables SOCKS proxy on Wi-Fi / Ethernet / iPhone USB
- Press `q` to cleanly stop everything

```
# How to use
### 1. Install
```bash
### 1. Clone the repo

git clone https://github.com/ujidesu/vless-mac
cd xray-reality-setup
chmod +x setup.sh
```

### 2. Run the script

```bash
./setup.sh
```

Or pass subscription URL directly:

```bash
./setup.sh "https://your-subscription-link.com"
```

### First Run

The script will ask you:

1. **Subscription URL** → Enter once, it will be saved to `config.ini`
2. **Block ads and trackers?** → [enabled by default]
3. **Block private IPs (anti-leak)?** → [enabled by default]

On next runs it will reuse the saved subscription URL (use --reset flag to clear config).

### Stop the proxy

Just press `q` in the terminal.

## Requirements

- macOS
- [Homebrew](https://brew.sh)

## Notes

- Works only with **vless + reality** nodes from your subscription
```
