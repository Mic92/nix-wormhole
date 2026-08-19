# nix-wormhole

`nix-copy-closure` without SSH: the sender serves a signed
[harmonia](https://github.com/nix-community/harmonia) binary cache over a
[dumbpipe](https://github.com/n0-computer/dumbpipe) tunnel; the receiver
fetches with a plain `nix copy`. Works through NAT via iroh's hole punching.

## Usage

Sender:

```console
$ nix build nixpkgs#hello
$ nix run github:pinpox/nix-wormhole -- send ./result
Starting harmonia binary cache on 127.0.0.1:23456...

On the other computer run:

    nix run github:pinpox/nix-wormhole -- receive \
        nodeadvertisement... \
        'nix-wormhole-1234-1:...' \
        /nix/store/...-hello-2.12.2

Serving; press Ctrl-C when the receiver is done.
```

Receiver: paste the printed command. It opens the tunnel on a local port and
substitutes the closure with the tunnel as an *extra* substituter, so
anything available on your normal caches (cache.nixos.org, ...) is fetched
from there and only private paths travel through the tunnel.

## How it works

- `send` generates a one-shot ed25519 signing key (`nix key
  generate-secret`) and starts harmonia on localhost with `sign_key_paths`,
  so narinfos are signed on the fly - no `nix store sign`, no store writes.
- The cache is exposed with `dumbpipe listen-tcp`; the printed ticket encodes
  the sender's node address.
- `receive` runs `dumbpipe connect-tcp` and realises the requested paths via
  `nix-store --realise` with `extra-substituters` / `extra-trusted-public-keys`.
  Harmonia advertises priority 50, so cache.nixos.org (40) wins for public
  paths; already-present paths are skipped. NARs are zstd-compressed on the
  fly (level 1 + long-distance matching).

## Notes

- Overriding `extra-trusted-public-keys` is restricted to root and
  `trusted-users` (on standard NixOS, `@wheel` already qualifies). If the
  substitution fails with a signature error, rerun with `sudo`.
- The signing key lives only in a temp dir for the lifetime of the send
  command; anyone with the ticket can fetch from your store while it runs,
  so stop it (Ctrl-C) when the transfer is done.
