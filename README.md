# nix-wormhole

`nix-copy-closure`, but over [croc](https://github.com/schollz/croc).
Send the full closure of a Nix store path to a friend with a short one-time
code: no SSH access, no binary cache, works through NAT.

## Usage

Sender:

```console
$ nix build nixpkgs#hello
$ nix run github:pinpox/nix-wormhole -- send ./result
Computing closure...
Exporting 42 store paths...
Compressed closure: 12M

Code is: nix-0549-4229-6918
On the other computer run:

    nix run github:pinpox/nix-wormhole -- receive nix-0549-4229-6918
```

Receiver:

```console
$ nix run github:pinpox/nix-wormhole -- receive nix-0549-4229-6918
Importing into Nix store...
Imported 42 store path(s). Root:
/nix/store/...-hello-2.12.2
```

`send` accepts one or more store paths, or symlinks to them (like `./result`).
The whole runtime closure is exported with `nix-store --export`, compressed
with `zstd -T0 --long=27`, sent through croc (parallel streams, LAN
discovery, relay fallback through NAT, croc's own compression disabled),
and imported on the other side with `nix-store --import`.

## Notes

- The transferred closure is unsigned. The nix-daemon only accepts unsigned
  imports from root or a `trusted-user` (on standard NixOS, `@wheel` is
  already trusted, no sudo needed). If the import fails with a signature
  error, run `sudo nix-wormhole receive` instead. There is no
  `--no-check-sigs` escape hatch: the daemon enforces this per-user,
  not per-invocation.
- The closure is staged as a compressed temp file before sending, so you
  need enough space in `$TMPDIR` for the compressed closure.
