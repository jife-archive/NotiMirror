<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="NotiMirror app icon">
</p>

<h1 align="center">NotiMirror</h1>

<p align="center">
  See your Mac's notifications on <b>every</b> monitor.<br>
  <b>English</b> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="docs/images/hero.png" alt="A notification on a MacBook also appears on two external monitors at the same time">
</p>

## Never miss a notification on your other screens

If you use a MacBook with external monitors, macOS shows notification banners on only one screen. That's often the MacBook you aren't looking at, so it's easy to miss a Slack message, a KakaoTalk reply, or a meeting reminder.

NotiMirror fixes that. When a banner appears, the same banner shows up in the top-right corner of every other monitor at the same moment.

## Features

- **Looks exactly like the original.** The copy shows the same app icon, profile photo, and text, because it's a live copy of the real banner.
- **Appears and disappears with the original.** There's no delay, and copies don't stay behind after the original is gone.
- **Works with every app.** Slack, KakaoTalk, Messages, Mail, Calendar, and any other app that sends notifications.
- **Follows your notification settings.** If Focus or an app's settings hide a banner, NotiMirror doesn't show it either.
- **Stays out of your way.** It lives in the menu bar and uses almost no CPU. Clicks pass through the copies.
- **Keeps your data private.** Nothing is saved or sent anywhere.

## Requirements

- A Mac with Apple silicon
- macOS 26 or later
- Xcode or the Xcode Command Line Tools. There's no ready-made download yet, so you build NotiMirror yourself with one command.

## Install

1. Download the source and build it:

   ```bash
   git clone <this-repo-url> NotiMirror
   cd NotiMirror
   ./build.sh --install
   ```

   If you see an error about `swiftc`, install the Command Line Tools first with `xcode-select --install`.

2. NotiMirror opens and asks for **Screen Recording** permission. Go to System Settings › Privacy & Security › Screen & System Audio Recording and turn on **NotiMirror**.
3. If macOS asks, choose **Quit & Reopen**.
4. A bell icon appears in the menu bar. From the next notification on, banners show up on all your monitors.

> **Tip:** If you have an Apple Development certificate set up in Xcode, the build is signed with it automatically. Then macOS won't ask for permission again each time you rebuild.

## Using NotiMirror

Click the bell icon in the menu bar. The menu is currently in Korean.

| Menu item | What it does |
|---|---|
| 일시 정지 (Pause) | Temporarily stop showing copies |
| 로그인 시 자동 실행 (Open at login) | Start NotiMirror automatically when you log in |
| 테스트 알림 보내기 (Send test notification) | Send a test notification to check that copies appear on your other monitors |
| 로그 보기 (Show log) | Open the log file, which is useful when reporting a problem |
| NotiMirror 종료 (Quit NotiMirror) | Quit the app |

## FAQ

**Why does NotiMirror need Screen Recording permission?**
To show an identical copy, NotiMirror needs to see the notification banner. It looks only at the banner, only while the banner is on screen, and never saves or sends anything.

**Nothing happens when I use only my MacBook.**
That's expected. NotiMirror adds copies to your *other* monitors, and the original is already on your MacBook.

**Can I click a copy?**
Not yet. Clicks pass through a copy to whatever is behind it. To open the notification, click the original banner.

**macOS asked me again whether to allow screen recording.**
macOS may check in on screen recording apps from time to time. Choose **Allow** to keep NotiMirror working.

**It stopped working after a macOS update.**
NotiMirror depends on how macOS shows notifications, which can change between versions. Please open an issue and attach the log (menu › 로그 보기).

## Uninstall

1. From the menu bar, turn off **로그인 시 자동 실행 (Open at login)** if it's on, then choose **NotiMirror 종료 (Quit)**.
2. Delete the app and its data:

   ```bash
   rm -rf ~/Applications/NotiMirror.app
   rm -f ~/Library/Logs/NotiMirror.log
   defaults delete local.notimirror
   ```

3. Remove NotiMirror from System Settings › Privacy & Security › Screen & System Audio Recording.

## Status

NotiMirror is an early prototype. It has been tested only on macOS 27.0.1 with an Apple silicon Mac. Feedback and bug reports are welcome.
