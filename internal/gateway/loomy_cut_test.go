package gateway

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/yetone/magpie/internal/provider"
)

// anyHostStream answers every request as the stream it holds, whatever host
// the provider's base names: a plugin provider's base is plugin://<id>/v1,
// which no transport dials, and Host() is that base cut down to the id.
type anyHostStream struct{ frames string }

func (s anyHostStream) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Body != nil {
		io.Copy(io.Discard, r.Body)
	}
	return &http.Response{StatusCode: 200, Status: "200 OK",
		Header: http.Header{"Content-Type": {"text/event-stream"}},
		Body:   io.NopCloser(strings.NewReader(s.frames)), Request: r}, nil
}

// loomyProvider is Loomy as magpie holds it: a plugin's provider, whose base
// is plugin://loomy/v1 and whose Host is therefore the plugin's id, "loomy",
// not the vendor's hostname.
func loomyProvider(t *testing.T) provider.Provider {
	t.Helper()
	p := provider.Provider{ID: "loomy", Name: "Loomy", Key: "k",
		Models: []string{"m"}, Chat: "plugin://loomy/v1"}
	if got := p.Host(); got != "loomy" {
		t.Fatalf("a plugin provider's Host is the plugin's id, not the vendor's host: %q", got)
	}
	return p
}

// Loomy's gateway ends a generation it did not finish with a bare [DONE] and
// no finish_reason (the contract measured against its own desktop client,
// docs/loomy-upstream.md in dsh-router-loomy). A whole reply of its does
// carry one, so a stream of its with none is a reply cut short.
func TestSaysItsEndForLoomy(t *testing.T) {
	if !saysItsEnd(loomyProvider(t), provider.Chat, "spark-x") {
		t.Errorf("a Loomy Chat stream that ended with no finish_reason is no cut")
	}
}

// Another plugin's Chat stream may end whole with neither a finish_reason nor
// [DONE], and goes as it came: the rule is Loomy's alone.
func TestAnotherPluginsChatStreamIsNoCut(t *testing.T) {
	other := provider.Provider{ID: "notloomy", Name: "X", Chat: "plugin://notloomy/v1"}
	if saysItsEnd(other, provider.Chat, "m") {
		t.Errorf("another plugin's Chat stream was read as a cut: Host %q", other.Host())
	}
}

// A Loomy reply that made calls is no cut: its tool-call frames have no
// recorded run against a real account, and a call read as a cut would fail a
// working turn. Nothing else is exempt.
func TestLoomyCallIsWhole(t *testing.T) {
	loomy := loomyProvider(t)
	other := provider.Provider{ID: "notloomy", Name: "X", Chat: "plugin://notloomy/v1"}
	for _, c := range []struct {
		name  string
		p     provider.Provider
		proto provider.Protocol
		calls bool
		want  bool
	}{
		{"loomy made calls", loomy, provider.Chat, true, true},
		{"loomy said nothing of calls", loomy, provider.Chat, false, false},
		{"another plugin made calls", other, provider.Chat, true, false},
		{"loomy on another protocol", loomy, provider.Anthropic, true, false},
	} {
		if got := loomyCallIsWhole(c.p, c.proto, c.calls); got != c.want {
			t.Errorf("%s: loomyCallIsWhole = %v, want %v", c.name, got, c.want)
		}
	}
}

// The user's case: a Loomy reply that stops mid-sentence with a bare [DONE] is
// told as a cut, not handed over as a whole reply.
func TestLoomyRelayEndedShort(t *testing.T) {
	fresh(t)
	half := sse(`data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant"}}]}`,
		`data: {"id":"c","choices":[{"index":0,"delta":{"content":"half said"}}]}`,
		`data: [DONE]`)
	if err := provider.Save(provider.Provider{ID: "loomy", Name: "Loomy", Key: "k",
		Models: []string{"m"}, Chat: "plugin://loomy/v1"}); err != nil {
		t.Fatal(err)
	}
	s := New()
	s.client = &http.Client{Transport: anyHostStream{frames: half}}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/v1/chat/completions",
		strings.NewReader(`{"model":"loomy/m","stream":true,"messages":[{"role":"user","content":"hi"}]}`)))
	code, body := rec.Code, rec.Body.String()
	if code != 200 || !strings.Contains(body, "half said") {
		t.Fatalf("%d %s", code, body)
	}
	if !strings.Contains(body, "ended before it was complete") {
		t.Errorf("a cut Loomy reply ended as if whole: %s", body)
	}
}

// A whole Loomy reply — its finish_reason come, [DONE] or not — goes as it
// came, never a cut and never a second end added to it.
func TestLoomyRelayWholeStaysWhole(t *testing.T) {
	fresh(t)
	whole := sse(`data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant"}}]}`,
		`data: {"id":"c","choices":[{"index":0,"delta":{"content":"all said"}}]}`,
		`data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`)
	for _, frames := range []string{whole, whole + "data: [DONE]\n\n"} {
		s := New()
		s.client = &http.Client{Transport: anyHostStream{frames: frames}}
		if err := provider.Save(provider.Provider{ID: "loomy", Name: "Loomy", Key: "k",
			Models: []string{"m"}, Chat: "plugin://loomy/v1"}); err != nil {
			t.Fatal(err)
		}
		rec := httptest.NewRecorder()
		s.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/v1/chat/completions",
			strings.NewReader(`{"model":"loomy/m","stream":true,"messages":[{"role":"user","content":"hi"}]}`)))
		code, body := rec.Code, rec.Body.String()
		if code != 200 || !strings.Contains(body, "all said") || strings.Contains(body, "ended before") || strings.Count(body, `"finish_reason"`) != 1 {
			t.Fatalf("%d %s", code, body)
		}
	}
}

// A Loomy reply that made calls and ended with no finish_reason is no cut: the
// turn is the client's to run, as it came.
func TestLoomyCallsEndedShortStayWhole(t *testing.T) {
	fresh(t)
	call := sse(`data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant"}}]}`,
		`data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t1","type":"function","function":{"name":"bash","arguments":"{}"}}]}}]}`,
		`data: [DONE]`)
	if err := provider.Save(provider.Provider{ID: "loomy", Name: "Loomy", Key: "k",
		Models: []string{"m"}, Chat: "plugin://loomy/v1"}); err != nil {
		t.Fatal(err)
	}
	s := New()
	s.client = &http.Client{Transport: anyHostStream{frames: call}}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/v1/chat/completions",
		strings.NewReader(`{"model":"loomy/m","stream":true,"messages":[{"role":"user","content":"hi"}]}`)))
	code, body := rec.Code, rec.Body.String()
	if code != 200 || !strings.Contains(body, "bash") || strings.Contains(body, "ended before") {
		t.Fatalf("a Loomy call read as a cut: %d %s", code, body)
	}
}
