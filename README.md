# THexView

A from-scratch **Int64 virtual hex viewer / editor** for Free Pascal / Lazarus,
built for forensics and reverse-engineering work on Windows. Opens multi-gigabyte
memory dumps and whole physical disks instantly, edits non-destructively, and
carries a full on-board crypto toolset — checksums, HMAC, symmetric ciphers,
RSA, and a native port of **FindCrypt2** — with **zero external DLL
dependencies** (everything goes through the Windows CNG system libraries via a
direct binding).

Built and compiled with **FPC 3.2.2 / Lazarus** (tested against Lazarus 4.4 on
Windows). UI is constructed entirely in code — no `.lfm` files.

---

## Highlights

- **Virtual rendering** — only the visible rows are ever read, so a 2 GB DRAM
  dump or a 1 TB `\\.\PhysicalDrive0` opens and scrolls instantly.
- **Non-destructive editing** — a piece-table engine keeps edits in an in-memory
  add-buffer; the backing file is never touched until you save. Full undo/redo.
- **Device picker** — *Open device* lists the machine's physical drives (model,
  bus, size, removable, which letters sit on each) and volumes, plus a manual
  path field and a *File...* button for disk images. Drives are probed through a
  handle opened for **no access at all**, so the list needs no admin rights and
  reads nothing off the media.
- **In-place raw-device editing** — a device can be opened read-only (the
  default) or read/write. In write mode the length is nailed down (no insert,
  no delete, overwrite clipped at the end) and the commit goes through **two
  separate confirmations**: a warning listing the exact ranges, with *Cancel*
  focused, then a typed confirmation word. Only the edited bytes are written,
  via sector-aligned read-modify-write — unbuffered and write-through, at the
  device's **real** sector size. Volumes are **left alone by default**: locking
  one and letting it go makes Windows re-mount it, and that re-mount puts the
  old bytes back over areas outside the volume — the MBR gap most of all.
  Locking (plus dismount) is a separate, explicit open mode for edits that
  really live inside a mounted volume. Every
  written range is then **read back through a freshly opened handle and
  compared** — so neither Windows nor the drive's own controller can answer
  from a cache — and a write the device swallowed is reported as a failure,
  never as success.
- **Multi-file tabs**, overwrite/insert modes, find (hex & text), goto, and
  export (raw / C array / Pascal array).
- **Block operations** on a selection: XOR/AND/OR/ADD/SUB/MUL/DIV/MOD, ROL/ROR,
  SHL/SHR, NOT, NEG, byte-flip, case ops, fill — all single-undo.
- **Palette tool windows** (calculator, RSA, checksum, crypto) that stay above
  the editor, minimise with it, and carry no taskbar buttons.
- **Right-click context menu**: copy as hex/text, send selection to Crypto
  (as key / IV), send to RSA (as base / modulus / exponent), checksum selection.
- **Runtime localization** via an external `hexview.lng` file (BG / EN shipped).
- **Help → About** (F1) — version, the build stamp of the running binary (FPC
  version, target CPU/OS, compile date), the live FindCrypt2 database size, and
  a *Copy info* button that puts the whole technical block on the clipboard.

---

## Crypto toolset

All hashing and symmetric crypto is routed through **Windows CNG** (`bcrypt.dll`,
a system component) using a hand binding — no OpenSSL, no third-party DLLs.

### Checksums & hashes (`Ekstri → Checksum / hash`, F6)
Single-pass over the selection (or whole file):

| kind | source |
|------|--------|
| CRC16 (CCITT), CRC32 (IEEE), CRC64 (ECMA-182) | pure Pascal |
| MD5, SHA1, SHA256, SHA384, SHA512 | CNG |
| HMAC-MD5/SHA1/SHA256/SHA384/SHA512 | CNG (keyed, hex key) |

CRC values are verified against reference vectors and Python
(`"123456789"` → CRC16 `29B1`, CRC32 `CBF43926`, CRC64 `6C40DF5F0B497347`).

With no selection the range is the whole file — which on `\\.\PhysicalDrive0`
means the whole disk. The dialog therefore **opens first and hashes after**: it
streams in 1 MB chunks with a progress bar, live throughput and ETA, and a
working **Cancel**. Ranges up to 64 MB start on their own; anything larger waits
for **Compute**, so the size is on screen before hours of I/O begin. A cancelled
pass clears the fields (a digest of a partial pass is not a digest of the range);
a short read — a bad sector, a device that ends early — is reported with how much
was actually covered. The HMAC panel uses the same path.

### Symmetric crypto (`Kripto → Symmetric`, F7)
- Ciphers: **AES, 3DES, DES, RC4**
- Modes: **ECB, CBC, CFB, GCM** (GCM is AES-only)
- **PKCS7 padding** toggle for block ciphers (length changes on encrypt/decrypt)
- **AES-GCM**: nonce in the IV field, authenticated **Tag** field — encrypt
  fills the tag, decrypt verifies it (auth failure is reported, not silent)
- **PBKDF2** button (HMAC-SHA256) derives a key from a password + salt into the
  key field
- Encrypt/Decrypt **compute and show** the result (hex) first; a separate
  *"Put back into file"* button writes it to the selection (undoable). Works on
  read-only device views too (view/copy only); on a writable device it becomes
  an ordinary edit and reaches the disk only at commit time.

### RSA (`Ekstri → RSA modpow`, F4)
`base ^ exp mod n` on arbitrary-size hex operands, backed by a pure-Pascal
big-integer unit (Knuth Algorithm D division, square-and-multiply modpow).
Verified against Python `pow()` up to 4096-bit, including a real RSA-2048
sign/verify round-trip.

### FindCrypt (`Kripto → Find crypto constants`, F8)
A native port of Ilfak Guilfanov's **FindCrypt2** signature database:
**79 signatures across 36 algorithms** (AES/Rijndael, DES, Blowfish, Twofish,
Camellia, SHA-1/256/512, MD5, Whirlpool, GOST, and more). Scans for both
contiguous constant blocks and *sparse* constants (compiler-spread). Because
scanning every signature over a multi-GB file is pointless, the dialog lets you
**check one or more specific algorithms** (a single algorithm scans ~10× faster).
The scan runs in a **worker thread** with its own file handle, a **progress
bar**, and **Cancel**; double-click a hit to jump to and select it.

---

## File layout

| File | Purpose |
|------|---------|
| `uhexview.pas` | Core `THexView` control, byte sources, piece-table edit engine |
| `hexviewdemo.lpr` | Demo application (menus, tabs, wiring) built entirely in code |
| `uhexcalc.pas` | Programmer / hex calculator |
| `ubigint.pas` | Pure-Pascal big-integer arithmetic |
| `uhexrsa.pas` | RSA modpow dialog |
| `uhexhash.pas` | CRC16/32/64 + MD5/SHA* + HMAC (single-pass) |
| `uhexchk.pas` | Checksum / hash results dialog |
| `uhexcrypt.pas` | Symmetric CNG engine (AES/3DES/DES/RC4, ECB/CBC/CFB/GCM, PKCS7, PBKDF2) |
| `uhexcryptdlg.pas` | Symmetric crypto dialog |
| `ufcdb.pas` | FindCrypt2 signature database (base64 blob + metadata) |
| `ufindcrypt.pas` | FindCrypt scanner (streamed, filtered, cancellable) |
| `ufcform.pas` | FindCrypt dialog (multi-select, threaded, progress) |
| `uhexdev.pas` | Device enumeration + "Open device" picker dialog |
| `uhexabout.pas` | Help → About dialog (version, build stamp, credits) |
| `ulang.pas` | Runtime localization (`L('key','default')`, `\n` escapes) |
| `ucng.pas` | Minimal Windows CNG binding — only the 13 entry points in use |
| `hexview.bg.lng` / `hexview.en.lng` | Language files (Bulgarian / English) |

---

## Running

Raw access to `\\.\PhysicalDriveN` requires **administrator rights**; without
them `CreateFile` returns error 5 and HEXO offers to relaunch itself elevated.
Plain file editing needs nothing special, which is why the binary does not
carry a `requireAdministrator` manifest.

---

## Building

Requires **FPC 3.2.2** and **Lazarus**. Add all `*.pas` units above to the
project and build `hexviewdemo.lpr`. There are no third-party units to fetch —
the CNG binding is `ucng.pas`, part of this source tree.

The CNG-backed features (MD5/SHA/HMAC, symmetric crypto, PBKDF2) are guarded with
`{$IFDEF WINDOWS}`; on other platforms they return `(Windows CNG only)` while
CRC and FindCrypt still work. `ucng.pas` is empty outside Windows, so the tree
compiles clean on any target.

---

## Localization

At startup the app loads `hexview.lng` from the executable's directory if
present. It's a UTF-8 `key=value` file (`;` starts a comment); edit the
right-hand side, keep the keys. A value may carry `\n` (new line), `\t` and
`\\`, so multi-line prompts survive a one-line file. Two ready translations ship:

- rename **`hexview.bg.lng`** → `hexview.lng` for Bulgarian
- rename **`hexview.en.lng`** → `hexview.lng` for English

`Ekstri → Save language template` writes out every string currently in use;
`Reload language file` re-reads it (restart to rebuild the menus). With no file
present the built-in defaults are used.

---

## Design notes

- **Zero external DLLs, zero third-party units.** Crypto uses `bcrypt.dll` (a
  Windows system component) through `ucng.pas` — a hand binding that declares
  exactly the 13 entry points, 4 handle types, the GCM auth-info record and the
  ~20 constants this project calls, and nothing else.
- **Volumes are not locked unless asked.** Measured on a real stick: with the
  volume locked, a write to the MBR gap is visible from every handle and then
  gone once the last one closes — Windows restores the region when it re-mounts
  the volume. Without locking, the same write survives a full close/reopen
  cycle. So the default is hands off, and `Extras → Write diagnostics` can
  demonstrate the difference on any machine.
- **On removable media, only a power cycle proves anything.** A verified read
  back — even through a fresh unbuffered handle, even seconds later, even after
  every handle is closed — only proves the bytes are in the drive's controller.
  A stick whose NAND has given up will acknowledge writes, serve them from its
  own RAM for as long as it stays powered, and lose them on unplug, with a
  clean `SYNCHRONIZE CACHE` in between. `Extras → Safely eject the device` does
  the stop-unit dance; if the bytes are gone after replugging, the media is
  finished and no program can write to it.
- **A write is not done until it reads back — from a new handle.** Raw-device
  writes can report success and change nothing: a cached write Windows drops, a
  sector a mounted file system guards, a write-protected stick, or a failing
  controller that acknowledges writes and serves them from its own RAM while
  the flash keeps the old bytes. `CommitToBacking` verifies every range through
  `VerifyReadAt`, which opens a fresh unbuffered handle, and raises
  `EHexVerify` with the exact offset on a mismatch, keeping the edits in memory.
- **Write-back is opt-in three times over.** The device handle is opened
  without write access unless asked for; the edit layer refuses any length
  change; and the commit needs two confirmations. Between them, the piece table
  holds every edit in memory, so nothing reaches the platter by accident.
- **Self-positioning reads.** Every byte source positions itself on each read, so
  the FindCrypt worker thread runs on its **own** file handle to avoid racing the
  UI's reads; non-file/edited views fall back to a responsive main-thread scan.
- **Verified where possible.** CRC, big-integer/RSA, and the FindCrypt scanner
  (including chunk-boundary matches) are tested headless against Python and
  known vectors. The CNG paths (MD5/SHA/HMAC, AES/GCM, PBKDF2) are
  compile-verified against `ucng.pas`; confirm their runtime output on Windows.

### Suggested runtime checks on Windows
- **PBKDF2**: password `password`, salt hex `73616C74` (= "salt"), 1 iteration,
  32 bytes → `120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b`
- **AES-GCM**: encrypt a block, then decrypt with the same key/nonce/tag → the
  original; flip one tag byte → decrypt must fail with an auth error.

---

## Credits

FindCrypt2 signature data derives from Ilfak Guilfanov's public-domain
findcrypt2 constant tables. Everything else is original.
