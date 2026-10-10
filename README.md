# tinaja-power

Keeps track of when this laptop loses AC power, and says so honestly about the times it
was not looking.

## The idea

A laptop on mains power is a very good power-failure detector for the room it is in. When
the office loses power, the charger stops, and the machine starts running on its battery.
That is the reference signal. Everything else here is bookkeeping so that the resulting
history means something.

```
  Mon 05 Oct 01:31  → Mon 05 Oct 06:26  4h 55m
  Wed 30 Sep 08:37  → Wed 30 Sep 11:54  3h 16m

2 outages, 8h 11m on battery, longest 4h 55m.
On battery 99.9% of observed time.
Observed 8h 11m of 1w 2d 22h (3.4%). The other 1w 2d 14h is unknown — the laptop was off, asleep or rebooting.
```

Read the last line first. **This laptop can only witness outages while it is switched on**,
and it spends a third of its life switched off. So the tool tracks three states, not two:

| State | Meaning |
|---|---|
| on AC | the office has power |
| on battery | the office does not have power — this is an outage |
| **unknown** | nobody was watching. The laptop was off, asleep or rebooting |

Unknown time is never counted as uptime and never counted as an outage. Every report says
how much of the period it actually saw, because a percentage computed over 3.4% of a week
wearing the label "99.9% on battery" would be nonsense.

## Setup

Four commands. Nothing here touches your account manager or your boot; step 4 is the one
that changes how your machine behaves, so read the note under it.

### 1. Get the code

```bash
git clone https://github.com/zarmeza/tinaja-power ~/Developer/tinaja-power
cd ~/Developer/tinaja-power
```

### 2. Check it works

```bash
ruby exe/tinaja-power status
```

You should get a line like:

```
On AC — 88% — 2.544 Wh — route via wlp3s0
```

`On battery` instead of `On AC` means it works and the office is currently dark.
`AC unknown — no mains supply could be read` means this kernel does not expose an adapter,
and nothing else in this tool will work.

### 3. Install it, so the timer can find it

The systemd unit looks for the command at `~/.local/bin/tinaja-power`, so make it a plain
symlink to the checkout. There is nothing to compile.

```bash
mkdir -p ~/.local/bin
ln -s ~/Developer/tinaja-power/exe/tinaja-power ~/.local/bin/tinaja-power
~/.local/bin/tinaja-power status
```

### 4. Make it run every 30 seconds, always

First, copy the unit files where systemd looks for them:

```bash
mkdir -p ~/.config/systemd/user
cp ~/Developer/tinaja-power/systemd/tinaja-power.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
```

Then **the important part** — let the timer keep running when you log out:

```bash
loginctl enable-linger zarmeza
```

> **What is linger?** By default, systemd stops your background services the moment you log
> out. That is fine for a desktop and useless for a machine you are using as a server.
> Enabling linger says "keep running my stuff whether or not anyone is logged in". It does
> not open a remote shell and does not log you in automatically — it just stops systemd
> from tidying up after you.
>
> **Without it, every logout books itself as an unknown gap.** You were logged out for
> about 31 hours on 8 October, and without linger the tool would have recorded that whole
> stretch as "nobody knows". That is honest but useless, because it is the tool failing, not
> the office failing.

To see what it is set to, or undo it:

```bash
loginctl show-user zarmeza | grep Linger   # Linger=yes is what you want
loginctl disable-linger zarmeza            # undo
```

Finally, start the timer:

```bash
systemctl --user enable --now tinaja-power.timer
systemctl --user list-timers tinaja-power.timer
```

If it says `failed`, ask it why:

```bash
systemctl --user status tinaja-power.timer
journalctl --user -u tinaja-power.service -n 20
```

### 5. Optional: pull in what the journal already knows

```bash
tinaja-power backfill
```

This reads the kernel's `AC Adapter [ADP1] (on-line/off-line)` lines out of `journalctl` and
seeds the history with them. On this machine it finds two real outages — 30 September and
5 October — and marks everything between them unknown.

It is worth knowing what this command is and is not. The kernel only logs the adapter when
it looks at it, which is usually at boot. So an `on-line` line does **not** mean the machine
was on AC until the next line, and the tool will not pretend otherwise: those stretches
become *unknown*, not uptime. There is a case for reading the boot markers too and marking
the stretches where the machine was demonstrably running as observed, but it is not done
yet.

### 6. Optional: make the bot ask it

The Discord bot shells out to `tinaja-power status --json` rather than reading the machine
itself. That keeps all the sysfs parsing in one place. See `tinaja-python-for-now-bot`.

## Daily use

```bash
tinaja-power status                 # what is happening right now
tinaja-power report                 # everything on record
tinaja-power report --since 7d      # just the last week
tinaja-power report --since 30d -n 5   # last five outages in the last month
tinaja-power report --json          # for another program
```

## How it decides

- **An outage is time on battery.** Nothing else. Not "AC off *and* the router died" —
  the router here is a cellular CPE that may have its own battery, so losing the internet is
  not proof of losing power. Reachability is recorded next to the outage as context and is
  never used as a filter.
- **A silence longer than 300 seconds means unknown, not continuity.** If the timer stops
  for any reason, that stretch is written as unknown rather than extended. This is the whole
  reason the tool can be believed.
- **Time the journal says nothing about stays unrecorded**, rather than being guessed at in
  whichever direction flatters the numbers.
- **The database is one file**, by default `~/.local/share/tinaja-power/power.db`. Override
  it with `--db PATH` or `$TINAJA_POWER_DB`. It is outside any checkout on purpose, so
  reinstalling or deleting the source never touches the history. To start over, delete it.

## Development

```bash
rake test                    # 72 tests
ruby -Ilib -Itest test/store_test.rb   # one file
rake record                  # record once, out loud
```

The tests build a fake `/sys` and `/proc` on disk rather than stubbing the filesystem, on
the grounds that reading the filesystem is the job and mocking it would only test the mock.
`test/real_machine_test.rb` reads this machine for real, so the parsers have to survive the
actual files and not only the fixture.

## Layout

```
exe/tinaja-power              the command
lib/tinaja_power/sysfs.rb     reads /sys and /proc; nil means unknown, never a guess
lib/tinaja_power/store.rb     the database, the intervals, and the gap rule
lib/tinaja_power/report.rb    turns intervals into numbers; percentages over observed time only
lib/tinaja_power/journal.rb   seeds history from the journal
lib/tinaja_power/format.rb    rendering, kept apart so --json and the text cannot drift
systemd/                      the timer and the unit it fires
```
