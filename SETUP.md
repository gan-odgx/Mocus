# Locus — install & first teleport

## 1. Sideload the IPA

Install the latest IPA from [Releases](https://github.com/ChrisMack32/Locus/releases) (or build from source) with Feather, SideStore, AltStore, Sideloadly, or LiveContainer.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often break inside LiveContainer. Do one of the following:

1. Long-press **Locus** in LiveContainer → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share / open the pairing file **into LiveContainer → Locus** (iOS share sheet).
3. Copy the RPPairing plist contents, open Locus → **Paste RPPairing from clipboard** (setup or Settings).

## 2. Pairing

### On iOS 27 — no computer

1. Open Locus → **Settings → Pair on this iPhone** → **Start pairing**.
2. Allow **Local Network** (and Location / Notifications if asked).
3. Leave Locus open. Go to **Settings › Privacy & Security › Developer Mode › Pair with Host**.
4. Pick **Locus** → **Pair**.
5. Enter your **iPhone unlock passcode** first (authorizes pairing).
6. When the second prompt appears, type the **6-digit code** Locus shows (also sent as a notification).
7. Done — RPPairing file is saved on-device.

### On iOS 18–26

1. On a computer, download [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).
2. Plug in your iPhone, unlock, Trust.
3. Generate an **RPPairing** file (not lockdown / SideStore `.mobiledevicepairing`).
4. AirDrop / Share → Open in **Locus**, **Import**, or **Paste from clipboard**.

## 3. LocalDevVPN

Install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044), connect it (default tunnel IP `10.7.0.1`).

## 4. Teleport

On Wi‑Fi: drop a pin → **Teleport**. Then joystick / routes / GPX work; the session can continue on cellular.

### No Wi‑Fi: Mobile data mode

1. Mocus → **Settings → Connection mode → Mobile data**.
2. Turn **Wi‑Fi off** and connect **LocalDevVPN**.
3. Turn **mobile data off** (Control Center). iOS won't open the developer tunnel while LocalDevVPN rides on mobile data.
4. Tap the status bar on the map (**Connect with mobile data**) → **Connect**. If data is still on, Mocus waits up to a minute and connects as soon as you turn it off.
5. Turn **mobile data back on**: the open tunnel keeps working, and the map and search load again.
6. Drop a pin → **Teleport**. **Stop** keeps the connection, so you can teleport again any time.

If the connection drops, turn mobile data off briefly and tap **Connect** again; the last spoofed spot is restored.
