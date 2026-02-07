# Wneen Scraper Automation Guide

Follow these steps to run the scraper without getting blocked by security or "Too Many Requests" errors.

---

## Step 1: Launch Chrome in Debug Mode

Open **PowerShell** and run the following command. This starts a real Chrome instance that the script can control.

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9223 --user-data-dir="C:\wneen_chrome_profile"

```

## Step 2: Manual Preparation

1. In the Chrome window that just opened, go to [wneen.com](https://www.wneen.com).
2. **Log in** to your account manually.
3. Keep this browser window **open** (do not close it).

## Step 3: Run the Scraper

Open a **new** terminal tab/window, activate your environment, and run:

```powershell
python wneen_scraper_profile.py

```

---

## Troubleshooting

- **Port Error:** Ensure `CDP_URL` in the Python file is set to `http://localhost:9223`.
- **Rate Limit:** If the site says "Too many requests," close Chrome, change your IP (Hotspot/VPN), and restart from Step 1.
- **Path Error:** If Chrome doesn't open, verify the path to `chrome.exe` on your C: drive.

# youtube

# Install yt-dlp

pip install yt-dlp

# Install FFmpeg (using winget on Windows)

winget install "FFmpeg (Essentials Build)"
