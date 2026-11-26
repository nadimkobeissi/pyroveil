# Using Pyroveil on ARM64: Steam snap with FEX (NVIDIA DGX Spark)

On an ARM64 machine that runs Steam as a snap, the native build and install
steps do not work, and they fail silently: the layer appears installed but is
never loaded. This page covers what is different and how to get it working.

Verified on a NVIDIA DGX Spark (GB10, aarch64), Ubuntu 24.04, NVIDIA 580.178.04,
Steam snap 1.0.0.87, Proton Experimental.

## Why the native instructions do not apply

Games are x86_64. The snap extracts an x86_64 rootfs and runs Steam and Proton
through FEX, installing the x86_64 NVIDIA Vulkan ICD into it. Vulkan therefore
runs on an x86_64 loader with the x86_64 ICD, not on the host driver.

That breaks two assumptions:

1. **A native build is the wrong ABI.** The aarch64 `libVkLayer_pyroveil_64.so`
   cannot be `dlopen`ed by an x86_64 loader. Nothing loads it, and nothing
   complains in the game log.
2. **`~/.local/share/vulkan/implicit_layer.d` is never searched.** The snap sets
   `HOME=$SNAP_USER_COMMON` (`desktop-launch` exports it), and pressure-vessel
   then mounts its own `vulkan` directory over `$XDG_DATA_HOME/vulkan`. The
   layer manifest is invisible.

`VK_ADD_LAYER_PATH` does not work around point 2: pressure-vessel strips it and
substitutes its own `VK_LAYER_PATH` and `VK_IMPLICIT_LAYER_PATH`. The manifest
has to sit in a directory the guest loader already searches, which is the FEX
rootfs system layer directory alongside MangoHud, RenderDoc and the MESA layers.

Anything else that looks like a broken install is usually the same root cause:
paths outside `$SNAP_USER_COMMON` are not in the bind pressure-vessel makes of
`$HOME`, so they read as missing or empty.

## 1. Cross toolchain

```
sudo apt-get install g++-x86-64-linux-gnu gcc-x86-64-linux-gnu
```

These are meta-packages that depend on the release's default cross GCC, which
in turn pulls the matching target `libc6-dev-amd64-cross` and
`libstdc++-N-dev-amd64-cross`. Do not name a GCC version explicitly: it will
not exist on releases whose default toolchain is newer or older.

## 2. Build for x86_64

```
scripts/build-x86_64.sh
```

This configures with `cmake/toolchains/x86_64-linux-gnu.cmake` and installs to
`~/pyroveil-x86_64`. The build tree is `build-x86_64`, separate from a native
`build`, so both ABIs can coexist.

Check the result is really x86-64:

```
file ~/pyroveil-x86_64/lib/libVkLayer_pyroveil_64.so
```

## 3. Install

```
HACK=hacks/re-village-nvidia/pyroveil.json scripts/install-steam-snap-layer.sh
```

Places the library and the hack config under `$SNAP_USER_COMMON/pyroveil`, and
the manifest in the rootfs implicit layer directory. It refuses to install a
non-x86-64 library.

It also creates the `cache/` directory next to the config. A hack that declares
`roundtripCache` needs it to be writable: the layer writes patched SPIR-V there
and silently does nothing if the directory is absent, so without it every
launch re-runs the SPIRV-Cross to glslang roundtrip and nothing is persisted.

If the hack ships pre-patched SPIR-V next to its config, that `cache/*.spv` is
copied too. For those games the committed file is the fix, and an empty cache
means the layer quietly falls back to the roundtrip:

```
HACK=hacks/monster-hunter-wilds-benchmark-nv/pyroveil.json scripts/install-steam-snap-layer.sh
```

Re-running overwrites installed patches with the committed ones, but never
deletes. If a patch is renamed or removed under `hacks/<game>/cache`, delete
`$SNAP_USER_COMMON/pyroveil/<game>/cache` and re-run, or the layer keeps
serving the obsolete file. Close the game first: the copy is not atomic and the
guest reads that directory while it runs.

`tests/test-install-cache.sh` covers this install path and runs on any host:

```
bash tests/test-install-cache.sh
```

Only the manifest lives inside the rootfs, and the Steam snap deletes and
re-extracts `x86_rootfs` when it updates. Re-run the script after a snap update.

## 4. Launch options

Keep whatever the game already needs and add:

```
PYROVEIL=1 PROTON_LOG=1 PROTON_LOG_DIR=/home/USER/snap/steam/common/ %command%
```

`PYROVEIL_CONFIG` and `PROTON_LOG_DIR` must point inside `$SNAP_USER_COMMON`.
Pointing them at the real home directory looks reasonable and fails: the
directory does not exist inside the container, so the config is never read and
no Proton log is ever written. The installer prints both paths for you.

## 5. Verify

Without launching the game:

```
scripts/verify-vulkan-layer.sh
```

It builds `tests/vk_layer_probe.cpp` for x86_64 and runs it under FEX. The probe
forces `vkCreateInstance` with the layer enabled, which is what actually
separates "listed" from "loadable". Expected output:

```
pyroveil: Found config in /home/.../pyroveil/re-village-nvidia/pyroveil.json!
pyroveil: Adding match for spirvExecutionModel: 5 (GLCompute).
pyroveil: Configured roundtripCachePath to "/home/.../cache".
DISCOVERED VK_LAYER_pyroveil: YES
vkCreateInstance with VK_LAYER_pyroveil enabled = 0 (VK_SUCCESS - layer loaded)
```

During a real session:

```
scripts/check-ingame.sh <appid>
```

The authoritative check is that `libVkLayer_pyroveil_64.so` appears in
`/proc/<game pid>/maps`. The log and the cache corroborate it.

For a hack that ships pre-patched shaders, the log line that proves the
committed file is actually being served is:

```
pyroveil: Pulled /home/.../cache/97ccc02f3db80d2e.spv from roundtrip cache.
```

Without it the layer loaded and matched, but fell back to the roundtrip.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No `pyroveil:` lines in the Proton log at all | Layer not loaded, or `PROTON_LOG_DIR` outside `$SNAP_USER_COMMON` |
| `Found config` but no `Found match` | Config matched no shader, check the hack against the game build |
| `VK_ERROR_LAYER_NOT_PRESENT` | Wrong ABI, or manifest not in a searched directory |
| `DISCOVERED ... NO` | Manifest missing from the rootfs implicit layer directory |
| Cache stays empty though the layer is loaded | `cache/` missing or not writable next to the config |
| A pre-patched hack still misbehaves | No `Pulled ... from roundtrip cache` in the log - installed before the cache was copied, or `cache/*.spv` was overwritten. Re-run the installer and diff against `hacks/<game>/cache` |
| Works, then breaks after a Steam snap update | `x86_rootfs` was re-extracted, re-run the installer |
| `re8.exe` style `Xid 109 CTX SWITCH TIMEOUT` in `dmesg` | The driver fault the hack exists to work around |

## Residual risk

The manifest lives inside `x86_rootfs`, which the snap owns and replaces. The
scripts are idempotent, so re-running the installer after an update is the
whole workaround, but a Steam or snap change to how it assembles the guest
`vulkan` directories can break discovery again. `verify-vulkan-layer.sh` is the
fast way to tell whether that has happened.
