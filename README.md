# Fanny 3.0.0 — Apple Silicon Port
### Monitor your Mac's fan speed and CPU/GPU temperature from your Notification Center.

This fork is the native Apple Silicon port of Fanny. See [Apple Silicon port](#apple-silicon-port) below.
###### If you're looking to download this application, please visit https://FannyWidget.com/

![alt text](readme-assets/fanny-widget-screenshot.jpg "Screenshot of Fanny Widget")

#### Apple Silicon port

This branch builds natively for Apple Silicon and targets macOS 12 or later.

- The menu bar app reads fans and temperatures through AppleSMC with type-aware decoding. On Apple Silicon, fan RPMs and temperatures are typically `flt ` values instead of the Intel `fpe2`/integer encodings the original code assumed.
- Temperature sensors are discovered at runtime (`Tp`/`Te` for CPU clusters, `Tg` for GPU) rather than using a fixed Intel sensor list. The Preferences window lists the sensors found on your Mac.
- The legacy `NCWidgetProviding` Notification Center widget has been replaced with a WidgetKit widget. The app writes samples into an App Group shared container; the widget reads from it. WidgetKit reloads are clamped to at least 15 seconds even if the app refresh interval is shorter.
- The app and widget are built for `arm64` only. Set your Apple Developer Team ID in `Fanny/DEVELOPMENT_TEAM.xcconfig` before building in Xcode.

#### License
[MIT license](LICENSE)

#### References
- [SMC](https://github.com/DanielStormApps/SMC)
