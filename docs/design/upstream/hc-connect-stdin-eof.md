# Draft: upstream issue for herdr-core (hc connect and stdin EOF)

Status: draft for the owner to review. Not posted. Paste everything below the line into a new issue at github.com/herdrdev/herdr-core.

---

**Title:** Windows: `hc connect` exits 0 with no output when stdin reaches EOF right after the request line

## Environment

- Windows, PowerShell 7 (pwsh), hc 0.1.19: affected
- Linux (WSL2), hc 0.1.18: not affected
- The same behaviour was first measured by hand on Windows with hc 0.1.18

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

Windows, hc 0.1.19, `hc connect` with a request line, 20 repetitions against a real document (a 600-byte value, version 12):

| stdin | answered | exit code |
|---|---|---|
| EOF right after the line (A) | 0/20 | 0 |
| held open 1 s after the line (B) | 20/20 | 0 |

A prints nothing at all and exits 0, so the caller cannot tell from the exit code that the request was dropped. B prints `{"id":1,"jsonrpc":"2.0","result":{"value":...,"version":12}}`. Earlier by hand on 0.1.18 (Windows): `hc connect < file` printed nothing, and the same line followed by keeping stdin open for 2 seconds answered every time.

Linux (WSL2), hc 0.1.18: no difference. A, B and C each exit 0 and print the answer (`{"id":1,"jsonrpc":"2.0","result":{"value":null,"version":0}}` for an unset document); against a real document, EOF at once answered 20/20 and held 1 s answered 20/20.

So the difference is Windows only: it looks as if the connection is closed on stdin EOF before the reply is read and written.

## Workaround in use

The caller keeps stdin open for one second after the request (`& { $req; Start-Sleep -Seconds 1 } | & $hc connect` in pwsh; the same hold, `{ printf ...; sleep 1; } | hc connect`, is also used on Linux where it is not needed). It costs a second per call, and is a guess: nothing says how long is long enough.

## Question

Is it intended that `hc connect` on Windows may exit 0 at stdin EOF before it has answered the request it read? If so, what should a one-shot caller do instead (a documented way to say "answer, then exit")? If not, this is a bug report: the exit should wait for the reply, or at least be non-zero when it drops one.
