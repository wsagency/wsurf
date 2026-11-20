# Optional WSurf sync on one Apple Account

**Design for review, 20 November 2026.** The Mac and iPhone should be able to edit one shared Space. Existing installations start with independent local data. Implementation and live device verification are pending.

WSurf on Studio and Air should work independently until the owner of each installation enables a category in Settings → Sync. Keep each device’s active Space, focused tab and window selection local. In a shared Space, tabs have persistent IDs across devices. The existing Other Devices list remains available to open a local copy of a tab.

## Approaches

The existing Other Devices list works well for opening a local copy of a remote tab. A copied tab has an independent lifetime. The owner chose editable shared Spaces so closing or moving a shared tab reaches the other devices, and chose a native iPhone browser with the same Space switcher. Keeping the snapshot list alongside the shared catalog preserves the copy workflow. Host the catalog in the Apple Account’s private CloudKit database and keep each device’s local Spaces and active selection in local storage.

## Mac and iPhone scope

The first iPhone app is a native SwiftUI and WebKit browser that can open a URL, select a Space and create, close, move, pin and favorite tabs. It can use its own local Space or join the same shared Space as the Mac. The two apps use the same CloudKit records, vault formats and device-side conflict tests from WSurfCore. An iPhone running WebKit retains the saved Mac engine preference as shared website metadata. The first mobile release covers website settings, vault access and saved AI provider configuration in Settings → Sync. TestFlight or an App Store release is a separate distribution decision.

## User choices

- Choose the Spaces to share or join. Choosing a computer Space on a phone should leave the computer in its current Space. The current repo has a macOS browser and a shared library targeting macOS and iOS.
- Shared tabs carry their URL, title, pin or favorite state, parent folder and relative order. Closing or moving a tab updates the same shared Space on every participating device. Device-only Spaces keep their own tabs.
- Separate opt-ins control shared Spaces, pins and favorites, credential vaults, website settings, AI provider configurations, and saved provider API keys. A device can share selected pins and favorites while keeping its ordinary tabs local. Give each category its own last sync result and allow pausing on one device. Disabling local sync keeps the local copy. A separate explicit operation removes cloud data.
- In the first run, show local and cloud Spaces before joining. Both devices may already have similar sessions. Join stable IDs and preserve different local content; keep conflicts for review. Private windows stay local.

On each Mac or iPhone, **Share this Space** publishes the selected local Space after loading the cloud catalog. **Join a shared Space** adds a local view of an existing shared ID. Equal names, URLs or the built-in Personal profile ID alone cannot identify copies. Preserve both devices’ existing tabs and let the owner choose which existing profile pins and favorites to include. A shared pin uses its persistent pin ID across the separate windows that display it.

Moving a tab between shared Spaces keeps its ID and changes its membership. Moving it to a local Space removes the remote membership and keeps the destination on that device. Closing an individual shared tab records a deletion. Closing a window, unloading a page or selecting a tab changes only that device. A received close of the selected tab uses that device’s usual neighboring-tab selection.

## Storage and trust

Keep the existing per-device sessions for Other Devices. A shared catalog needs its own records per profile, Space and tab, including explicit deletion markers, stable order keys and per-item change tracking. Apply remote edits to the live model without changing the local focus or resending the same update. Persist an offline outbox. When opting in, fetch the category baseline before publishing defaults, including when other categories already advanced a CloudKit checkpoint.

The existing vault format syncs encrypted passwords, WSurf passkeys, verification codes, notes and secure fields. Extending it to all stored credentials needs authenticated encrypted assets for attachments and large entries, safe resumption, a deliberate retention policy for revision history and Trash, and handling local-only exclusions and separate autofill stores. An unrelated vault on the same profile stays separate. Opening a shared vault still requires its synced unlock passkey and matching key check. A logical sync must preserve encryption keys, local journals, device authorization and recovery independently on each device.

Website settings are stored by several components. Sync typed settings using each setting's actual scope. Stored camera, microphone, location or assistant permission must respect the destination device's OS permission and local approval policy. Store explicit changes and resets, not a copy of the entire defaults domain.

Provider configurations can sync without secrets. A separately enabled key channel uses end-to-end encryption such as iCloud Keychain or vault-sealed records, and binds each saved key to a stable provider and approved endpoint. Read only the saved provider secret that the user selected. Other secrets from environment variables, MCP, website sessions and OAuth tokens have a different purpose.

Provider definitions are global, while model selection belongs to each profile. Removing a provider on one device must respect the independent key opt-in and local key retention. Receiving an endpoint change requires a new local approval before using an existing key there. A camera rule travels with its origin, assistant access with its site, and tracker exceptions with their host. Sensitive permissions require local consent.

Import each shared vault by its own identifier and preserve unrelated existing vaults. Rewrap attachment keys for the destination store and retain encrypted assets while a live entry, revision or Trash entry references them. Empty Trash keeps its existing device-local effect. When the Apple Account changes, isolate queued writes and require fresh opt-in before publishing data to the new account.

## Acceptance

Exercise two independent local stores with a simulated cloud: first enable, late opt-in, offline edits/deletes/reordering, separate or shared Spaces, reload and account switch. Check that a local opt-out keeps local and remote copies, private tabs stay private, and keys never appear in CloudKit metadata, logs or provider configuration records. Prove the live path with a disposable Space, vault and provider credential after signing is provisioned. The signed 0.1.30 patch ships independently of the live trial. Test the iOS target in a simulator and use a development-signed device for the live CloudKit and Keychain checks.

Start the integration fixture with two populated Macs and a late-joining iPhone. Exercise interrupted attachment transfer, competing close and move operations, and account changes with pending uploads. Deliver compatible shared records in WSurfCore first, then connect the macOS and iOS apps. Check the transport with isolated synthetic records on two signed devices and the user-facing workflows with a disposable vault and Space.
