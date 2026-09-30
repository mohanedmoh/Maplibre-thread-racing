# MapLibre startup race: minimal reproduction

A fresh React Native app that reaches MapLibre's offline module at startup on
Android. It renders no map and adds no workaround. It was built to answer one
question from the MapLibre maintainers: does the startup race we reported on
`@maplibre/maplibre-react-native` 10.1.5 still exist on the latest release?

| | |
|---|---|
| `@maplibre/maplibre-react-native` | 11.4.0 |
| MapLibre Native Android | 13.6.1 (opengl), the wrapper's default |
| React Native | 0.87.1, new architecture, Hermes |
| Device | Google Pixel 7, Android 17 (API 37) |
| Build | release APK, arm64-v8a, fresh install every round |

## The problem

On Android the wrapper only *posts* `MapLibre.getInstance` to the UI thread
(`MLRNMapViewModule.initialize`). The offline module needs that instance, and
nothing makes it wait:

- `MLRNOfflineModule.initialize` posts `runMigrations()` to the main thread as
  soon as JS first touches the module. It calls `FileSource.getInstance`.
- `MLRNOfflineModule.setTileCountLimit` and the other offline methods call
  `OfflineManager.getInstance` on the native-modules thread.

If either runs before `MapLibre.getInstance`, MapLibre throws
`MapLibreConfigurationException` and the app dies behind its splash screen.

## Result

Two variants, 30 fresh installs each. "Margin" is the time from `libmaplibre.so`
finishing its load to the first offline call; negative means the call came
first.

| Variant | Clean | Crashed | No answer | Margin |
|---|---|---|---|---|
| Offline call in the first effect (`App.tsx`) | 30 | 0 | 0 | +7 to +37 ms, median +13 ms |
| Offline call when the bundle loads (`index.js`, `EARLY_CALL = true`) | 0 | 29 | 1 | -30 to -9 ms; in 3 rounds the library had not loaded at all |

So the race is still there on 11.4.0. A call in the first effect wins it by
about a hundredth of a second on this phone. A call made any earlier loses it
every time.

The 29 crashes are all `MapLibreConfigurationException`:

- 28 on the main thread, in `MLRNOfflineModule.initialize` → `runMigrations` →
  `activateFileSource` ([trace](results/crash-main-thread-runMigrations.txt)).
- 1 on `mqt_v_native`, in `MLRNOfflineModule.setTileCountLimit`
  ([trace](results/crash-native-modules-thread-setTileCountLimit.txt)). This is
  the same stack we reported on 10.1.5.

One round neither crashed nor answered: no ANR, and the offline promise never
settled. The native-modules thread had loaded `libmaplibre.so` itself in that
round. We did not capture a thread dump for it.

Not seen on 11.4.0: the class-initialisation deadlock in `LibraryLoader` that
hit 2 of 5 fresh installs on 10.1.5. The code behind it is unchanged in MapLibre
Native 13.6.1, but it did not occur in these 60 rounds.

Per-round output is in [results/](results/).

## Run it

Use a physical device. An emulator did not reproduce the original bug.

```bash
npm install
cd android && ./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a && cd ..
./fresh-install-loop.sh android/app/build/outputs/apk/release/app-release.apk 30
```

For the second variant, set `EARLY_CALL = true` in `index.js` and rebuild.

`fresh-install-loop.sh` uninstalls the app, installs the APK and cold-launches
it each round, then reports a clean start, a crash or a hang. A fresh install
matters: the native library loads cold, which is when the race is widest.

The only change from the React Native template's toolchain is `ndkVersion`
(27.2.12479018 instead of 27.1.12297006).

## Workaround

Call `MapLibre.getInstance(this)` in `MainApplication.onCreate()`. It runs on the
main thread before React Native starts, so the instance exists and the library is
loaded before any JS can reach the offline module.
