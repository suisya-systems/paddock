# Draft: upstream issue for herdr-core (hc connect and stdin EOF)

Status: draft for the owner to review. Not posted. Paste everything below the line into a new issue at github.com/herdrdev/herdr-core. Fill the Windows rows from the host run before posting (marked `TODO`).

---

**Title:** `hc connect`: is a request answered when stdin reaches EOF right after the request line?

## Environment

- hc / herdr-core 0.1.18
- Linux (WSL2): measured, see Observed
- Windows (pwsh, named pipe): `TODO` fill from the host run

## What I am trying to do

Read and write a document (`doc.get` / `doc.set`) from a script. `hc` has no CLI verb for documents, so I pipe one JSON-RPC line into `hc connect`:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"org-state"}}' | hc connect
```

## Reproduction

`scripts/probes/hc-connect-stdin-eof.sh` (sh) and `hc-connect-stdin-eof.ps1` (pwsh), inlined here:

```sh
REQ='{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"org-state"}}'
printf '%s\n' "$REQ" | hc connect; echo "exit=$?"                  # A: EOF right after the line
{ printf '%s\n' "$REQ"; sleep 1; } | hc connect; echo "exit=$?"    # B: stdin held open 1 s
hc connect < request.json; echo "exit=$?"                          # C: from a file
```

## Expected

`hc connect` writes the response to the request it read before it exits, so A and C print the same one JSON line as B and exit 0. The docs I found (`docs/commands.md` "hc connect": "Speak the protocol over stdin/stdout"; `schema/README.md` "Connecting": plain mode is "JSON-RPC 2.0, one message per line") do not say what happens when stdin ends, so this is my reading, not a documented promise.

## Observed

Linux, hc 0.1.18: no difference. A, B and C each exit 0 and print the 61-byte answer `{"id":1,"jsonrpc":"2.0","result":{"value":null,"version":0}}`. Against a real document, 20 repetitions: EOF at once answered 20/20, held 1 s answered 20/20.

Windows, hc 0.1.18 (earlier hand measurement): `hc connect < file` printed nothing, while the same line followed by keeping stdin open for 2 seconds answered every time. `TODO` replace with the output of `hc-connect-stdin-eof.ps1` (exit codes and answered counts for A and B).

## Workaround in use

The caller keeps stdin open for one second after the request (`{ printf ...; sleep 1; } | hc connect`, and `& { $req; Start-Sleep -Seconds 1 } | & $hc connect` in pwsh). It costs a second per call, and is a guess: nothing says how long is long enough.

## Question

Is it intended that `hc connect` may exit at stdin EOF before it has answered the requests it read (on Windows at least)? If so, what should a one-shot caller do instead (a documented way to say "answer, then exit")? If not, this is a bug report.
