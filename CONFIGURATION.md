# Local Configuration

Do not commit real RTC keys or registry URLs.

`IPTVPlayer` reads these values from Xcode build settings, scheme environment
variables, or `Info.plist` expansion:

```sh
RTC_APP_ID=your_volcengine_rtc_app_id
RTC_TOKEN_URL=https://iptv-rtc-token.iptv75390.workers.dev/rtc/token
LIVE_REGISTRY_URL=https://your-project-default-rtdb.firebaseio.com/live_channels
```

The token endpoint must generate formal RTC tokens on your application server
with the RTC AppKey. The client sends:

```json
{ "roomId": "room", "userId": "uid", "role": "viewer" }
```

and expects:

```json
{ "token": "formal_rtc_token", "appId": "optional_app_id" }
```

See `../cloudflare-rtc-token-worker` for a free-tier friendly deployment, or
`../rtc-token-server` for a minimal Node.js example.

For command-line builds:

```sh
xcodebuild ... RTC_APP_ID=... RTC_TOKEN_URL=... LIVE_REGISTRY_URL=...
```
