# Verification: specification

`scripts/verify_plugin.sh` is the interface; this page is its specification and
`tests/test-verify-plugin.sh` checks every statement. It never loads or runs the file: it reads
the Mach-O headers and symbol tables with `lipo`, `otool` and `nm`, so it is safe on an untrusted
build.

```
scripts/verify_plugin.sh FILE --allow FILE [--imports-snapshot FILE] [--min-os V] [--print-imports]
```

## What it checks

For the file and for each of its `arm64` and `x86_64` slices:

| Rule | Passes when |
|---|---|
| Universal | the slices are exactly `arm64` and `x86_64` |
| Bundle | the Mach-O header's file type is `BUNDLE` (a loadable module, as `dlopen` needs) |
| X-Plane plugin | the slice exports `XPluginStart`, `XPluginStop`, `XPluginEnable`, `XPluginDisable` and `XPluginReceiveMessage` |
| Libraries | it links `XPLM.framework`, and every library it links is a `lib` line of the allow file |
| Denied calls | it imports none of `system`, `popen`, `fork`, `vfork`, `execl*`, `execv*`, `posix_spawn*`, `ptrace`; the allow file cannot permit these |
| Watched imports | any import of a network client (`connect`, `getaddrinfo`, `gethostbyname*`, `sendto`, `sendmsg`), the loader (`dlopen`, `dlsym`), the keychain (`SecItem*`, `SecKey*`) or CFNetwork HTTP (`CFHTTP*`, `CFURLConnection*`, ...) is a `symbol` line of the allow file |
| Deployment target | the macOS minimum version is `11.0` (`--min-os` changes it) |

Server sockets (`socket`, `bind`, `listen`, `accept`, used by the feel page) are not watched; an
outbound `connect` is, so a plugin that starts phoning home fails until the owner reads the change
and adds `symbol _connect` to `baselines/mesmer-allow.txt`.

`--imports-snapshot FILE` compares the arm64 slice's imports with the list from the last good build
(`baselines/mesmer-imports.txt`, made with `--print-imports`) and prints a `note:` line with any new
ones. It is information for the run summary and never fails: ordinary C++ changes add and remove
library imports all the time.

## Output and failures

Each rule prints `ok   <what>` or `FAIL <what>`. With any `FAIL` the script prints
`verify_plugin.sh: N check(s) failed for FILE` to stderr and exits non-zero. Usage errors print
`verify_plugin.sh: <reason>`: no file, more than one file, no `--allow`, an unknown option, a missing
file or allow file, a file that is not Mach-O, not running on macOS.

## What it does not do

It proves the file has the shape of a Mesmer plugin, not that the code is harmless. Deliberately
malicious code that uses only allowed libraries and imports passes. The other defences are the source
allowlist and ref rule ([source-rules.md](source-rules.md)), CodeQL and ClamAV in the workflow, and
Apple's notarization scan.
