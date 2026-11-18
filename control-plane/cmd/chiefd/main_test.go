package main

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// AC6: the web UI is loopback-only. A non-loopback --addr is refused with
// the typed error before anything binds — no exposed port, no access layer;
// remote access is CDT-630's phase-3 scope.
func TestNonLoopbackBindIsRefused(t *testing.T) {
	for _, addr := range []string{"0.0.0.0:8090", ":8090", "192.168.1.9:8090", "example.com:8090", "8090"} {
		err := loopbackOnly(addr)
		if err == nil || !errors.Is(err, errNotLoopback) {
			t.Errorf("loopbackOnly(%q) = %v, want the typed loopback refusal", addr, err)
		}
	}
	if !errors.Is(loopbackOnly("0.0.0.0:8090"), errNotLoopback) {
		t.Error("the refusal does not carry the typed cause")
	}
	for _, addr := range []string{"127.0.0.1:8090", "localhost:8090", "[::1]:8090"} {
		if err := loopbackOnly(addr); err != nil {
			t.Errorf("loopbackOnly(%q) = %v, want nil", addr, err)
		}
	}
}

// The loopback refusal exits with the usage code and names the address.
func TestRunRefusesANonLoopbackAddr(t *testing.T) {
	var stderr strings.Builder
	code := run([]string{"--addr", "0.0.0.0:8090"}, io.Discard, &stderr)
	if code != exitUsage {
		t.Errorf("exit code = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "must be loopback") ||
		!strings.Contains(stderr.String(), "0.0.0.0:8090") {
		t.Errorf("stderr = %q, want the typed loopback refusal naming the address", stderr.String())
	}
}

// AC1: the web UI rides the same process and the same port as the API —
// the page is delivery, not data. The page and its assets serve from the
// embedded files, and every other path answers through the API surface,
// which 404s on unknown routes.
func TestTheUIRidesTheAPISPort(t *testing.T) {
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/runs" {
			_, _ = w.Write([]byte(`{"runs":[]}`))
			return
		}
		http.NotFound(w, r)
	})
	srv := httptest.NewServer(withUI(api))
	t.Cleanup(srv.Close)

	res, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK ||
		!strings.Contains(res.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("GET / = %d %s, want the page", res.StatusCode, res.Header.Get("Content-Type"))
	}
	page := readAll(t, res)
	for _, marker := range []string{"Run board", "Chat with the Chief", "Lifecycle"} {
		if !strings.Contains(page, marker) {
			t.Errorf("the page lacks the %q section", marker)
		}
	}

	// The assets: the CSS and the JS serve with their content types, and an
	// unknown static name 404s.
	for name, contentType := range map[string]string{
		"/static/style.css": "text/css",
		"/static/app.js":    "text/javascript",
	} {
		res, err := http.Get(srv.URL + name)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK ||
			!strings.Contains(res.Header.Get("Content-Type"), contentType) {
			t.Errorf("GET %s = %d %s, want %s", name, res.StatusCode,
				res.Header.Get("Content-Type"), contentType)
		}
	}
	if res, err := http.Get(srv.URL + "/static/nope.css"); err != nil {
		t.Fatal(err)
	} else {
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Errorf("GET /static/nope.css = %d, want 404", res.StatusCode)
		}
	}

	// The API surface rides the same port, untouched.
	res, err = http.Get(srv.URL + "/v1/runs")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if body := readAll(t, res); body != `{"runs":[]}` {
		t.Errorf("GET /v1/runs = %q, want the API's own answer", body)
	}
	if res, err := http.Get(srv.URL + "/v1/nope"); err != nil {
		t.Fatal(err)
	} else {
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Errorf("GET /v1/nope = %d, want the API's 404", res.StatusCode)
		}
	}
}

func readAll(t *testing.T, res *http.Response) string {
	t.Helper()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
