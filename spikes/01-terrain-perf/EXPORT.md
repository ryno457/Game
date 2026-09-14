# Running Spike A on a phone

The number that decides risk item 1 has to come off real hardware. Two ways to
get there — neither needs anything from the Claude session.

---

## Path A — Godot's Android editor (no PC, no APK)

Best if you want the answer tonight from the phone alone.

Godot ships an official **Android build of the editor itself**
(godotengine.org → Download → Android; check the page for the current 4.6
link). It runs the Vulkan mobile renderer natively, which is the thing the
browser probe cannot do.

1. Install the Godot Android editor on the phone.
2. Get this folder onto the phone — download the branch as a ZIP from GitHub
   and unzip it, or copy `spikes/01-terrain-perf/` across.
3. Open the editor, **Import**, point it at `project.godot` in this folder.
4. Press Play. Tap **SOAK 10 MIN**, put the phone face-up on a desk, leave it.

**One caveat:** running inside the editor carries overhead an exported APK does
not, so absolute frame times come out slightly *pessimistic*. That is the safe
direction to be wrong in — a PASS here is a real PASS. Thermal drift is
unaffected either way.

---

## Path B — export an APK from a PC

The proper measurement, and what you would ship.

**One-time setup.** Godot needs the Android SDK's `build-tools` to sign the
APK. Easiest route is to install Android Studio, then in Godot:
*Editor → Editor Settings → Export → Android* and set the **Android SDK path**.
Then *Editor → Manage Export Templates* and download the 4.6 templates.

**Export.**

1. Open `spikes/01-terrain-perf/project.godot` in Godot 4.6.
2. *Project → Export*. The **Android** preset is already configured here —
   arm64 only, immersive mode, wake-lock permission, Gradle build off.
3. **Export Project**, untick *Export With Debug* if you want a release build,
   and write it to `build/sentinel_spike_a.apk`.
4. Install on the phone (`adb install -r build/sentinel_spike_a.apk`, or copy
   it across and open it).

Or skip the GUI once the SDK is configured:

```
godot --headless --path spikes/01-terrain-perf --export-debug "Android" build/sentinel_spike_a.apk
```

The committed preset carries **no keystore and no passwords** — Godot uses your
own debug keystore, and a release keystore stays on your machine. Never commit
one.

---

## Running the soak

Same protocol either way, and it matters:

- **Put the phone down, screen up.** A hand is a heatsink and will flatter the
  result. The whole point of ten minutes is reaching thermal steady state.
- Don't switch apps. Backgrounding stops the measurement.
- Start at **150 units**, then repeat at 300 and 600 to get the scaling curve.

## Reading the result

The verdict prints on screen and a CSV lands in `user://`, which on Android is:

```
/sdcard/Android/data/io.rubustech.sentinel.spikea/files/
```

The on-screen path is authoritative. One row per second, per-minute buckets,
and a PASS/FAIL line per criterion in the header comments.

Criteria, thresholds, and what each failure mode means for the design are in
[README.md](README.md). Read the failure section *before* you look at the
number — deciding the fallback after seeing it is how a spike gets argued into
a pass.
