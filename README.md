# MapLibre startup race: minimal reproduction

A fresh React Native app that reaches MapLibre's offline module at startup on
Android. It renders no map and adds no workaround. It was built to answer one
question from the MapLibre maintainers on
[maplibre-native#4697](https://github.com/maplibre/maplibre-native/issues/4697):
does the startup race we reported on `@maplibre/maplibre-react-native` 10.1.5
still exist on the latest release? It does.

| | |
|---|---|
| `@maplibre/maplibre-react-native` | 11.4.0 |
| MapLibre Native Android | 13.6.1 (opengl), the wrapper's default |
| React Native | 0.87.1, new architecture, Hermes |
| Device | Google Pixel 7, Android 17 (API 37), build CP3A.260905.009 |
| Build | release APK, arm64-v8a, fresh install every round |

The app calls `OfflineManager.setTileCountLimit`, `setProgressEventThrottle` and
`setMaximumAmbientCacheSize` in its first `useEffect` ([App.tsx](App.tsx)). With
`EARLY_CALL = true` in [index.js](index.js) it makes one more call when the
bundle loads, which is the earliest point a JS app can reach the offline module.

## Result

Session 2, 2026-09-30. Per-round logs are in
[results/session-2/](results/session-2/).

| Build | First offline call | Runs | Clean | Exception | Hang | Native abort |
|---|---|---|---|---|---|---|
| 11.4.0 | first `useEffect` | 30 | 24 | 1 | 5 | 0 |
| 11.4.0, instrumented | first `useEffect` | 20 | 14 | 0 | 5 | 1 |
| 11.4.0 | bundle load | 20 | 0 | 20 | 0 | 0 |
| 11.4.0, instrumented | bundle load | 10 | 0 | 10 | 0 | 0 |
| 11.4.0 + workaround | bundle load | 20 | 20 | 0 | 0 | 0 |
| 11.4.0 + wrapper fix | bundle load | 20 | 20 | 0 | 0 | 0 |
| 11.4.0 + wrapper fix | first `useEffect` | 20 | 20 | 0 | 0 | 0 |

The rows map to these folders:
[first-effect](results/session-2/first-effect/),
[first-effect-instrumented](results/session-2/first-effect-instrumented/),
[bundle-load](results/session-2/bundle-load/),
[bundle-load-instrumented](results/session-2/bundle-load-instrumented/),
[bundle-load-workaround](results/session-2/bundle-load-workaround/),
[bundle-load-fix](results/session-2/bundle-load-fix/) and
[first-effect-fix](results/session-2/first-effect-fix/).

"Instrumented" is the wrapper with
[patches/instrumentation.patch](patches/instrumentation.patch): log lines with
thread and time around `MapLibre.getInstance` and the offline calls, and a
watchdog that dumps every thread if the offline promise has not settled after
6 s. "Workaround" is [patches/workaround.patch](patches/workaround.patch) and
"wrapper fix" is [patches/wrapper-fix.patch](patches/wrapper-fix.patch).

Session 1 was the first run on 11.4.0, on the same phone. Its logs are in
[results/session-1/](results/session-1/).

| First offline call | Runs | Clean | Exception | No answer |
|---|---|---|---|---|
| first `useEffect` | 30 | 30 | 0 | 0 |
| bundle load | 30 | 0 | 29 | 1 |

The first-`useEffect` call was clean 30 of 30 times in session 1 and 24 of 30
times in session 2, on the same phone with the same code. It is a race whose
odds change from one session to the next, so a clean run does not show that the
call is safe.

## The three ways it fails

- **Exception.** `MapLibreConfigurationException`, either on `main` in
  `MLRNOfflineModule.initialize` → `runMigrations` → `activateFileSource` →
  `FileSource.getInstance`, or on `mqt_v_native` in `setTileCountLimit` →
  `OfflineManager.getInstance`. Example traces:
  [main](results/session-1/crash-main-thread-runMigrations.txt),
  [mqt_v_native](results/session-1/crash-native-modules-thread-setTileCountLimit.txt).
- **Deadlock.** The cycle from #4697. `main` is inside `System.loadLibrary` →
  `JNI_OnLoad`, which waits for `OfflineManager`'s class initialisation, and
  `mqt_v_native` is inside `OfflineManager.<clinit>`, which waits for the
  `LibraryLoader` lock that `main` holds. 8 of the 10 hangs have thread dumps,
  and all 8 show it: 3 ANR traces (first-effect rounds
  [4](results/session-2/first-effect/round-4-anr.txt),
  [6](results/session-2/first-effect/round-6-anr.txt) and
  [25](results/session-2/first-effect/round-25-anr.txt)) and 5 watchdog dumps
  (`round-{2,5,14,15,17}-repro.log` in
  [first-effect-instrumented](results/session-2/first-effect-instrumented/)).
  Round 14 is the mirror image: `mqt_v_native` does the load, and `main` waits
  for `LibraryLoader` in `NativeConnectivityListener.<clinit>`. The other 2
  hangs (first-effect rounds 2 and 23) went silent right after the library
  load, with no crash and no dump.
- **Native abort.** Seen once, in
  [first-effect-instrumented round 1](results/session-2/first-effect-instrumented/round-1-app.log):
  `JNI DETECTED ERROR IN APPLICATION: obj == null`, in a call to
  `GetObjectField` from `FileSource.initialize`, then SIGABRT on
  `mqt_v_native`. `MapLibre.getInstance` sets `INSTANCE` before it loads the
  library and before it sets `tileServerOptions`
  ([MapLibre.java#L113-L121](https://github.com/maplibre/maplibre-native/blob/android-v13.6.1/platform/android/MapLibreAndroid/src/main/java/org/maplibre/android/MapLibre.java#L113-L121)),
  and `getTileServerOptions()` is not synchronized
  ([#L163-L166](https://github.com/maplibre/maplibre-native/blob/android-v13.6.1/platform/android/MapLibreAndroid/src/main/java/org/maplibre/android/MapLibre.java#L163-L166)).
  A second thread in that window passes `validateMapLibre()` and builds
  `FileSource` with null options. The window is the same without the
  instrumentation.

## Why it happens

`MLRNMapViewModule` is registered with `needsEagerInit = true`
([MLRNPackage.kt#L86](https://github.com/maplibre/maplibre-react-native/blob/v11.4.0/package/android/src/main/java/org/maplibre/reactnative/MLRNPackage.kt#L86)).
Its `initialize()` runs on `mqt_v_native` and only posts `MapLibre.getInstance`
to the UI queue
([MLRNMapViewModule.kt#L25-L29](https://github.com/maplibre/maplibre-react-native/blob/v11.4.0/package/android/src/main/java/org/maplibre/reactnative/components/mapview/MLRNMapViewModule.kt#L25-L29)).
`MLRNOfflineModule` never waits for it:

- Its `initialize()` runs on `mqt_v_js` when JS first touches the module, and
  posts `runMigrations()` → `FileSource.getInstance` to the main looper
  ([MLRNOfflineModule.kt#L41-L45](https://github.com/maplibre/maplibre-react-native/blob/v11.4.0/package/android/src/main/java/org/maplibre/reactnative/modules/MLRNOfflineModule.kt#L41-L45)).
- Its methods, such as `setTileCountLimit`, call `OfflineManager.getInstance`
  directly on `mqt_v_native`
  ([MLRNOfflineModule.kt#L411-L414](https://github.com/maplibre/maplibre-react-native/blob/v11.4.0/package/android/src/main/java/org/maplibre/reactnative/modules/MLRNOfflineModule.kt#L411-L414)).

The instrumented runs show where each call lands. Times are relative to the JS
offline call; `./thread-timeline.sh` prints them per round.

- **Bundle load.** The offline module's post reaches the main queue 3–12 ms
  before the eager module's post, so `runMigrations` always runs first and
  throws. `getInstance` did not start in any of the 10 runs. This is a fixed
  ordering, not a race.
- **First `useEffect`.** `MLRNMapViewModule.initialize()` runs 36–98 ms before
  the JS call. `main` starts `getInstance` between 68 ms before and 15 ms after
  it, and needs 10–28 ms. The native offline call lands 0–6 ms after the JS
  call. Where it lands decides the outcome:
  - before `INSTANCE` is set: exception;
  - while `libmaplibre.so` loads: deadlock;
  - after the load, before `tileServerOptions` is set: native abort;
  - after `getInstance` returns: clean. 3 of the 14 clean runs won by 6 ms or
    less.

So there are two layers. The missing ordering is a bug in maplibre-react-native.
Two things in MapLibre Native turn that race into a hang or a native abort
instead of an exception: the `LibraryLoader` / class-initialisation cycle
(#4697), and `MapLibre.getInstance` exposing `INSTANCE` before it is fully set
up. Reading the code, an app without React Native that touches `OfflineManager`
(or another class that loads the library in a static initializer) from a second
thread while `getInstance` runs on main could hit them too. We have not tested
that.

## Workaround

Call `MapLibre.getInstance(this)` in `MainApplication.onCreate()`, before
`loadReactNative(this)`. It runs on the main thread before React Native starts,
so the instance exists and the library is loaded before any JS can reach the
offline module.

The app also needs its own MapLibre dependency, because the wrapper declares it
as `implementation`. Without it `MainApplication.kt` does not compile (`MapLibre`
is an unresolved reference). Use the wrapper's `nativeVariant` and
`nativeVersion`:

```groovy
// android/app/build.gradle
implementation("org.maplibre.gl:android-sdk-opengl:13.6.1")
```

Both changes are in [patches/workaround.patch](patches/workaround.patch). With
the bundle-load call it was clean 20 of 20 times.

## Fix in the wrapper

[patches/wrapper-fix.patch](patches/wrapper-fix.patch) adds one helper,
`MapLibreInitializer.ensureInitialized(context)`. On the main thread it calls
`MapLibre.getInstance`; on any other thread it posts that call to main and
waits. `MLRNMapViewModule.initialize`, `MLRNOfflineModule.activateFileSource`
and all 15 `OfflineManager.getInstance` call sites go through it. It was clean
in 40 of 40 runs, including 30 where the offline call came before the library
had loaded (by up to 192 ms). Reading the code, `MLRNStaticMapModule.createImage`
and `MLRNNetworkModule.setConnected` have the same gap and should use it too.

The first offline call on `mqt_v_native` now blocks until `main` has run
`getInstance`. That would deadlock only if `main` were waiting on
`mqt_v_native` at that moment, which did not happen in these runs.

## Run it

Use a physical device. An emulator did not reproduce the original bug.

```bash
npm install
cd android && ./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a && cd ..
./fresh-install-loop.sh android/app/build/outputs/apk/release/app-release.apk 30 results/my-run
./summarize-run.sh results/my-run
```

`fresh-install-loop.sh` uninstalls the app, installs the APK and cold-launches
it each round, then reports a clean start, a crash, a hang or no answer. A fresh
install matters: the native library loads cold, which is when the race is
widest.

Variants (rebuild after each change):

- **Bundle-load call:** set `EARLY_CALL = true` in [index.js](index.js).
- **Workaround:** `git apply patches/workaround.patch`.
- **Instrumented or fixed wrapper:** after `npm install`, run
  `patch -p1 -d node_modules/@maplibre/maplibre-react-native < patches/instrumentation.patch`
  (or `wrapper-fix.patch`). `npm ci` puts the original back. For an
  instrumented run, `./thread-timeline.sh results/my-run` prints the per-round
  timeline.

Notes:

- The only change from the React Native template's toolchain is `ndkVersion`
  (27.2.12479018 instead of 27.1.12297006).
- Set `SERIAL` when `adb devices` lists more than one entry. With wireless
  debugging on, the same phone is listed twice.
- Google Play Protect can hold `adb install` behind a "Send app for a security
  check?" prompt on the phone. The loop waits until someone answers it.
- On Windows, the native build can hit the 260-character path limit (`ninja:
  ... Filename longer than 260 characters`). Clone to a short path and move
  CMake's build folder with
  `externalNativeBuild { cmake { buildStagingDirectory "C:/b" } }` in
  `android/app/build.gradle`. Session 2 was built that way.

## Reading the logs

- **NO-ANSWER** means no crash, no reply and no input ANR. Check
  `round-N-app.log`. In session 2 it was either a deadlock (4 of the 5 hangs in
  `first-effect-instrumented`, all with watchdog dumps) or a crash that React
  Native killed with SIGKILL before the system logged `am_crash`
  (`bundle-load-instrumented` round 7). `./summarize-run.sh` does this check.
- **A native abort** counts as CRASH, but `round-N-crash.txt` stays empty
  because it only holds Java exceptions. The abort and every thread's stack are
  in `round-N-app.log`.
- **The margin** is measured from the `nativeloader` line for `libmaplibre.so`,
  which is logged when `dlopen` returns, before `JNI_OnLoad` runs. A positive
  margin does not mean the call was safe: first-effect round 4 deadlocked at
  +30 ms.
- **`first-effect-instrumented` round 7:** logcat was not cleared before it, so
  its logs start with round 6's lines (PID 13106) and its recorded margin
  (+40 ms) is round 6's. Its own process shows +44 ms and a clean start.
- **ANR traces** are trimmed to the app's own process. The per-process CPU list
  and the dumps of other processes (system_server and others) are removed.
- **`first-effect-fix`** ran in two parts (9 + 11 rounds) because the phone was
  needed in between.
