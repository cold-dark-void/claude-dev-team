package main

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

// The web UI (CDT-652): a small set of static files, embedded and served by
// this one process on the same loopback port as the Chief's API — the page
// gains no endpoint of its own; every number it shows comes from the /v1
// endpoints of chief.Handler. No build step: the files are plain HTML, CSS,
// and JavaScript, compiled into the binary by go:embed.
//
//go:embed web
var webFS embed.FS

// uiHandler serves the web UI's static files. The page is delivery, not
// data: the API stays chief.Handler's.
func uiHandler() http.Handler {
	sub, err := fs.Sub(webFS, "web")
	if err != nil {
		panic("chiefd: the embedded web UI is missing: " + err.Error())
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		serveAsset(w, sub, "index.html", "text/html; charset=utf-8")
	})
	mux.HandleFunc("GET /static/", func(w http.ResponseWriter, r *http.Request) {
		switch name := strings.TrimPrefix(r.URL.Path, "/static/"); name {
		case "style.css":
			serveAsset(w, sub, "style.css", "text/css; charset=utf-8")
		case "app.js":
			serveAsset(w, sub, "app.js", "text/javascript; charset=utf-8")
		default:
			http.NotFound(w, r)
		}
	})
	return mux
}

// serveAsset writes one embedded file. A live board must not be cached: the
// browser re-reads the page and its assets on every visit.
func serveAsset(w http.ResponseWriter, fsys fs.FS, name, contentType string) {
	raw, err := fs.ReadFile(fsys, name)
	if err != nil {
		http.Error(w, "404 page not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(raw)
}

// withUI mounts the web UI's static routes in front of the Chief's API —
// one process, one loopback port, one surface. Everything else answers
// through the API, including its own 404s.
func withUI(api http.Handler) http.Handler {
	ui := uiHandler()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || strings.HasPrefix(r.URL.Path, "/static/") {
			ui.ServeHTTP(w, r)
			return
		}
		api.ServeHTTP(w, r)
	})
}
