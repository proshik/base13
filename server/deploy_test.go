package main

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// The files in deploy/ — the scrape examples, the alert rules and the
// dashboard — name the server's figures by hand. Nothing in Prometheus or
// Grafana complains about a name that does not exist: a rule over it never
// fires, and a panel over it is simply empty, which reads the same as a quiet
// server. So the names are checked here, against a real scrape.

// deployDir is where the operator's files live, next to the server.
const deployDir = "../deploy"

// deployFiles returns every file under deploy/, or skips the test where the
// folder is not there: a copy of server/ on its own, as the image build takes
// it, has no deploy/ beside it and nothing to check.
func deployFiles(t *testing.T) []string {
	t.Helper()
	if _, err := os.Stat(deployDir); errors.Is(err, fs.ErrNotExist) {
		t.Skip("no deploy/ next to the server")
	}
	var files []string
	err := filepath.WalkDir(deployDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("deploy/ could not be read: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("deploy/ holds no files")
	}
	return files
}

// A figure's name as the operator's files write one: the server's own, the Go
// runtime's and the process's. The boundary keeps a word that merely ends in
// one of the prefixes out.
var figureName = regexp.MustCompile(`\b(?:relay|go|process)_[a-z0-9_]+`)

// busyScrape is a scrape of a server that has seen a little of everything: a
// pair playing, a pace report and a desync, the page and the engine served, a
// refusal. Every family is exposed from zero anyway, but a scrape taken after
// activity is the one a dashboard really reads.
func busyScrape(t *testing.T) string {
	t.Helper()
	s := &server{hub: NewHub()}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("server did not come up: %v", err)
	}
	httpServer := newHTTPServer(s.routes(writeStatic(t)))
	go httpServer.Serve(listener)
	t.Cleanup(func() { httpServer.Close(); listener.Close() })
	addr := listener.Addr().String()

	host, guest, _ := seatPair(t, addr)
	packet := []byte{1, 0, 0, 0, 0, 31}
	host.send(t, packet)
	guest.receive(t)
	guest.sendText(t, paceBody(pace{Speed: 80, Waits: 3, Delay: 8, FPS: 60}))
	guest.sendText(t, desyncBody)
	stranger := dial(t, addr)
	stranger.sendJSON(t, hello{Action: "join", Game: "tanks", Code: "ZZZZZZ"})
	stranger.welcome(t)
	for _, path := range []string{"/", "/index.wasm"} {
		response, err := http.Get("http://" + addr + path)
		if err != nil {
			t.Fatalf("%s was not served: %v", path, err)
		}
		io.Copy(io.Discard, response.Body)
		response.Body.Close()
	}
	eventually(t, func() bool {
		return metricValue(t, s, `relay_desynced_matches_total{kind="code"}`) == 1 &&
			metricValue(t, s, `relay_client_windows_total{platform="web",verdict="network"}`) == 1
	})
	return renderMetrics(s)
}

func TestDeployFilesNameOnlyRealMetrics(t *testing.T) {
	// A name in a rule or a panel that the server does not expose is a rule that
	// never fires and a panel that is always empty. A histogram's base name and
	// its _bucket, _sum and _count lines all count as real; a suffix on a family
	// that is not a histogram does not.
	files := deployFiles(t)
	samples, err := parseScrape(busyScrape(t))
	if err != nil {
		t.Fatal(err)
	}
	exposed := map[string]bool{}
	for _, s := range samples {
		exposed[s.name] = true
		for _, suffix := range []string{"_bucket", "_sum", "_count"} {
			if base, cut := strings.CutSuffix(s.name, suffix); cut {
				exposed[base] = true
			}
		}
	}

	used := 0
	for _, file := range files {
		body, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("%s could not be read: %v", file, err)
		}
		for _, name := range slices.Compact(slices.Sorted(slices.Values(figureName.FindAllString(string(body), -1)))) {
			used++
			if exposed[name] {
				continue
			}
			// The process's figures come from the system. The image runs on
			// Linux, where every one the files use is there; a darwin build
			// without cgo, for one, has no resident memory to report.
			if strings.HasPrefix(name, "process_") && runtime.GOOS != "linux" {
				t.Logf("%s names %s, which this %s build does not expose", file, name, runtime.GOOS)
				continue
			}
			t.Errorf("%s names %s, which the server does not expose", file, name)
		}
	}
	if used == 0 {
		t.Error("no figure is named anywhere in deploy/, so nothing was checked")
	}
}

// panel is as much of a Grafana panel as the checks below read.
type panel struct {
	ID          int             `json:"id"`
	Type        string          `json:"type"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	Datasource  *panelSource    `json:"datasource"`
	Targets     []panelTarget   `json:"targets"`
	Panels      []panel         `json:"panels"`
	GridPos     json.RawMessage `json:"gridPos"`
}

type panelSource struct {
	Type string `json:"type"`
	UID  string `json:"uid"`
}

type panelTarget struct {
	Datasource *panelSource `json:"datasource"`
	Expr       string       `json:"expr"`
	RefID      string       `json:"refId"`
}

// dashboardVariable is one of the dashboard's template variables.
type dashboardVariable struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Query string `json:"query"`
}

// The one datasource every panel reads through: a variable, so the dashboard
// imports into any Grafana whatever its Prometheus is called there.
const datasourceVariable = "${datasource}"

func TestDashboardIsValidJSON(t *testing.T) {
	// A dashboard that does not parse is refused at import, and one whose
	// panels point at a datasource by a name from somebody else's Grafana
	// imports fine and shows nothing.
	deployFiles(t)
	body, err := os.ReadFile(filepath.Join(deployDir, "grafana", "relay.json"))
	if err != nil {
		t.Fatalf("the dashboard could not be read: %v", err)
	}
	var dashboard struct {
		UID           string `json:"uid"`
		Title         string `json:"title"`
		SchemaVersion int    `json:"schemaVersion"`
		Templating    struct {
			List []dashboardVariable `json:"list"`
		} `json:"templating"`
		Panels []panel `json:"panels"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	if err := decoder.Decode(&dashboard); err != nil {
		t.Fatalf("the dashboard is not valid JSON: %v", err)
	}
	if decoder.More() {
		t.Fatal("the dashboard has something after its closing brace")
	}
	if dashboard.UID == "" || dashboard.Title == "" {
		t.Errorf("the dashboard has no uid or no title: %q, %q", dashboard.UID, dashboard.Title)
	}
	if dashboard.SchemaVersion < 39 {
		t.Errorf("schemaVersion %d; the dashboard is written for 39 or later", dashboard.SchemaVersion)
	}
	variable := slices.IndexFunc(dashboard.Templating.List, func(v dashboardVariable) bool {
		return v.Name == "datasource"
	})
	if variable < 0 || dashboard.Templating.List[variable].Type != "datasource" ||
		dashboard.Templating.List[variable].Query != "prometheus" {
		t.Fatal("the dashboard has no datasource variable of type datasource over prometheus")
	}

	// Rows hold no queries; a collapsed row carries its panels inside it.
	var panels []panel
	for _, p := range dashboard.Panels {
		panels = append(panels, p)
		panels = append(panels, p.Panels...)
	}
	ids := map[int]string{}
	queried := 0
	for _, p := range panels {
		if other, taken := ids[p.ID]; taken {
			t.Errorf("panels %q and %q share id %d", other, p.Title, p.ID)
		}
		ids[p.ID] = p.Title
		if len(p.GridPos) == 0 {
			t.Errorf("panel %q has no place on the grid", p.Title)
		}
		if p.Type == "row" {
			continue
		}
		if p.Datasource == nil || p.Datasource.UID != datasourceVariable {
			t.Errorf("panel %q does not read through %s", p.Title, datasourceVariable)
		}
		if len(p.Targets) == 0 {
			t.Errorf("panel %q has no query", p.Title)
		}
		for _, target := range p.Targets {
			queried++
			if target.Datasource == nil || target.Datasource.UID != datasourceVariable {
				t.Errorf("a query of panel %q does not read through %s", p.Title, datasourceVariable)
			}
			if strings.TrimSpace(target.Expr) == "" {
				t.Errorf("panel %q has an empty query", p.Title)
			}
			// Prometheus 3 stores an integer bound as "5.0", so a selector on
			// le="5" matches nothing; and a mean is the one figure a single
			// client's forged reports can drag anywhere.
			if strings.Contains(target.Expr, "le=") {
				t.Errorf("panel %q selects a bucket bound by its text: %s", p.Title, target.Expr)
			}
			if strings.Contains(target.Expr, "_sum") && strings.Contains(target.Expr, "_count") {
				t.Errorf("panel %q divides a sum by a count instead of taking a quantile: %s", p.Title, target.Expr)
			}
		}
	}
	if queried == 0 {
		t.Error("the dashboard has no queries at all")
	}
}
