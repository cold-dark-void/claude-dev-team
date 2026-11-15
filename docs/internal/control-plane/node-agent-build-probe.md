# Node agent build probe

Carries AC-8. T-08 owns this file and writes it alone. The write-up in this file is the only artifact. No binary ships. No Dockerfile-as-product, no build script is committed. Probe commands are evidence only (AC-10). Container work waits on the AC-10 approval gate (T-02 / G-02); the Go image digest is pinned in the T-02 request.

## AC-8 — Build probe

Build one trivial Go binary in a container and show it starts on the development machine. Record the commands, the image digest, and the binary size.

Cross-compile for two targets and record both as built but not run:

- linux/arm64 (DGX Spark) — `GOOS=linux GOARCH=arm64`.
- darwin/arm64 (Mac) — `GOOS=darwin GOARCH=arm64`.

A committed binary, or a build recipe presented as product code, fails review.

### Build commands and image digest

Probe date: 2026-11-15. All container commands ran as single direct `docker` CLI commands on the host (machine safeguards; no Dockerfile committed, no build script). The scratch dir lived under `/tmp` and was deleted after the probe — the write-up in this file is the only artifact.

**Verdict: supported** — the approved image built a trivial Go binary; the amd64 binary started on the development machine; both cross-compiles built cleanly.

**Approved image (G-02, row 3 only):** `docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea` (official Docker Library `golang` image, digest-pinned).

**1. Pull the approved image — digest confirmation:**

```
$ docker pull docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
docker.io/library/golang@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea: Pulling from library/golang
69245854ad58: Pulling fs layer
338554e9113f: Pulling fs layer
d6c30932f8d3: Pulling fs layer
ee2355d89db5: Pulling fs layer
83d129a974dd: Pulling fs layer
99e3c19f61af: Pulling fs layer
4f4fb700ef54: Pulling fs layer
83d129a974dd: Waiting
99e3c19f61af: Waiting
4f4fb700ef54: Waiting
ee2355d89db5: Waiting
338554e9113f: Verifying Checksum
338554e9113f: Download complete
69245854ad58: Download complete
d6c30932f8d3: Verifying Checksum
d6c30932f8d3: Download complete
99e3c19f61af: Verifying Checksum
99e3c19f61af: Download complete
4f4fb700ef54: Verifying Checksum
4f4fb700ef54: Download complete
69245854ad58: Pull complete
338554e9113f: Pull complete
83d129a974dd: Verifying Checksum
83d129a974dd: Download complete
d6c30932f8d3: Pull complete
ee2355d89db5: Verifying Checksum
ee2355d89db5: Download complete
ee2355d89db5: Pull complete
83d129a974dd: Pull complete
99e3c19f61af: Pull complete
4f4fb700ef54: Pull complete
Digest: sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
Status: Downloaded newer image for golang@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
```

Pulled digest matches the approved pin: `sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea`.

**2. The probe source (one trivial `main.go`, written to `/tmp/node-agent-probe-20261115/`, not in the worktree):**

```go
package main

import "fmt"

func main() {
	fmt.Println("node-agent-probe-ok")
}
```

**3. Build the amd64 binary in the container:**

```
$ docker run --rm -v /tmp/node-agent-probe-20261115:/src -w /src \
    docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea \
    go build -o probe-bin main.go
```

Exit code 0, no output (clean build).

**4. Go toolchain version inside the container:**

```
$ docker run --rm docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea go version
go version go1.27.4 linux/amd64
```

### Binary size and start proof

**Verdict: supported** — the binary the container produced started on this development machine and printed the expected string.

**Start proof (binary run directly on the host, no container):**

```
$ /tmp/node-agent-probe-20261115/probe-bin
node-agent-probe-ok
(exit code 0)
```

**Binary size (amd64, container output):**

```
$ ls -l /tmp/node-agent-probe-20261115/probe-bin
-rwxr-xr-x 1 root root 2342249 Nov 15 02:23 /tmp/node-agent-probe-20261115/probe-bin
```

2,342,249 bytes (~2.2 MiB), statically linked by default Go toolchain settings.

### Cross-compile results (built, not run)

Both cross-compiles were built in the same container and **recorded as built-not-run** — neither binary was executed. They are evidence of the toolchain's cross-compile capability for the DGX Spark (linux/arm64) and Mac (darwin/arm64) targets only.

**linux/arm64 (DGX Spark) build:**

```
$ docker run --rm -v /tmp/node-agent-probe-20261115:/src -w /src \
    -e GOOS=linux -e GOARCH=arm64 \
    docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea \
    go build -o probe-linux-arm64 main.go
```

Exit code 0, no output (clean build).

```
$ file /tmp/node-agent-probe-20261115/probe-linux-arm64
/tmp/node-agent-probe-20261115/probe-linux-arm64: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked, Go BuildID=qW1M9Qy8J_8viPg2eCXf/DGXMiUoNfGcvDqgDZz_-/TqcWr-wvqfU8vhnLt8tJ/GT5MAXO7qPqCncwfllEi, BuildID[sha1]=d2363ff7f80bc1c29540490860c3fe53f1c8f7ae, with debug_info, not stripped

$ ls -l /tmp/node-agent-probe-20261115/probe-linux-arm64
-rwxr-xr-x 1 root root 2342293 Nov 15 02:23 /tmp/node-agent-probe-20261115/probe-linux-arm64
```

2,342,293 bytes. Built-not-run.

**darwin/arm64 (Mac) build:**

```
$ docker run --rm -v /tmp/node-agent-probe-20261115:/src -w /src \
    -e GOOS=darwin -e GOARCH=arm64 \
    docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea \
    go build -o probe-darwin-arm64 main.go
```

Exit code 0, no output (clean build).

```
$ file /tmp/node-agent-probe-20261115/probe-darwin-arm64
/tmp/node-agent-probe-20261115/probe-darwin-arm64: Mach-O 64-bit arm64 executable, flags:<|DYLDLINK|PIE>

$ ls -l /tmp/node-agent-probe-20261115/probe-darwin-arm64
-rwxr-xr-x 1 root root 2413202 Nov 15 02:23 /tmp/node-agent-probe-20261115/probe-darwin-arm64
```

2,413,202 bytes. Built-not-run.

### Cleanup (AC-10 — no binary ships)

The scratch dir `/tmp/node-agent-probe-20261115/` with `main.go` and all three binaries was deleted after the probe. No binary, Dockerfile, or build script is committed; this doc is the only artifact of the probe.
