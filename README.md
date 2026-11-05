# NotifCorner

A small macOS menu bar app that moves notifications to the screen corner you pick.
The default is bottom right. Newest notifications appear in the corner and push older ones up.

## Build and install

```
./build.sh
```

This builds `NotifCorner.app`, copies it to `~/Applications`, and starts it.

Then turn on **NotifCorner** in **System Settings → Privacy & Security → Accessibility**.
You need to do this again after each rebuild, because the app has a local signature
and each build gets a new one.

## Use

Click the bell icon in the menu bar, then **Settings…**:

- **Position**: click a cell in the 3×3 grid.
- **Distance from screen edge**: space between the notifications and the screen edge.
- **Move notifications**: turn the app on or off without quitting it.
- **Launch at login**: start the app when you log in.
- **Send a test notification**: check where notifications appear.

## How it works

macOS draws all notifications inside one Notification Center window. Apps cannot move
single notifications, only that window. NotifCorner uses the Accessibility API to watch
Notification Center. When notifications appear, it finds the notification list in the
window and moves the whole window so the list sits in the chosen spot.

Order: macOS always adds the newest notification at the bottom of the list. For the
bottom positions the app keeps the bottom of the list in place, so the newest one stays
in the corner.

The app leaves the Notification Center side panel and desktop widgets alone. It moves the
window back when you quit it.

Needs macOS 14 or later.
