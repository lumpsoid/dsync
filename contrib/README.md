# contrib/ — community-maintained examples

**These are examples, not supported integrations.** Nothing here is built,
tested or released by this project, and no CI runs it. They exist because the
thing that makes third-party packaging painful is never the unit file, it is
undocumented process behaviour — so dsync documents the process contract
(`README.md`, "Running the agent under a service supervisor") and shows what
that contract looks like written out for three supervisors. Copy one, change
the paths, and own the result.

| File | Supervisor |
|---|---|
| `systemd/dsync-agent.service` | systemd, as a system service |
| `systemd/dsync-agent@.service` | systemd, one instance per replica set |
| `openrc/dsync-agent` | OpenRC |
| `runit/dsync-agent/run` | runit (and, unchanged, s6) |

All four are the same program started the same way, because that is the whole
point of the contract: `dsync agent --serve` in the foreground, as an
unprivileged user, logging to stdout and stderr, stopped with SIGTERM, with a
kill timeout above dsync's own 10-second exit bound, and an explicit
`--state-dir`.

## Before it will serve anything

A fresh agent trusts nobody and can reach nothing. Pairing and granting are
operator actions against the *same state directory the service uses*, and they
take effect on the next connection with no restart (SPEC §4.4):

```sh
sudo -u dsync dsync pair show --name phone --state-dir /var/lib/dsync
sudo -u dsync dsync pair grant phone /srv/media --state-dir /var/lib/dsync
```

`pair show` needs a terminal — it asks you to confirm the device id the peer
presented — so it is a thing you run, never a thing the unit does.

## Two agents on one host

Give each its own `--state-dir` and its own `--port`. Without separate state
directories they share a paired-device store and contend for the same replica
locks. The systemd template unit (`dsync-agent@.service`) is that arrangement
written out; the other three are single-instance and are forked by hand the
same way.
