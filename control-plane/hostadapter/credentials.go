package hostadapter

import (
	"fmt"
	"sort"
	"strings"
)

// Provider is one model provider omp authenticates against. The set is
// closed at the providers the B7 probe covers: the four proven env-var names
// plus the one negative result.
type Provider string

const (
	ProviderOpenAI    Provider = "openai"
	ProviderAnthropic Provider = "anthropic"
	ProviderXAI       Provider = "xai"
	ProviderGoogle    Provider = "google"
	ProviderGroq      Provider = "groq"
	// ProviderLlamaCpp is the negative result of the B7 probe: omp reads no
	// env var for it — its key comes from the auth store
	// (~/.omp/agent/agent.db, table auth_credentials) and the only
	// LLAMA_CPP_* env var omp carries is LLAMA_CPP_BASE_URL, the endpoint
	// override. The adapter therefore injects nothing for this provider.
	ProviderLlamaCpp Provider = "llama.cpp"
)

// ProvenCredential is one B7 proven name: the env var omp demonstrably reads
// for one provider. The evidence is behavioral — a headless run with a
// dummy, non-routing value in exactly that variable reached the provider,
// which answered with an auth failure naming the bad key (the B7 probe
// record; docs/internal/control-plane/credentials.md § "Gap 2 — resolved:
// the omp provider env-var names (B7)").
type ProvenCredential struct {
	Provider Provider
	// EnvVar is the proven name. Injection uses this name and no other.
	EnvVar string
	// Evidence is the verbatim probe observation that proved the read.
	Evidence string
}

// provenCredentials is the proven-name table (AC5/B7). The omp host reads
// one name per provider; a name not in this table fails closed
// (ErrCredentialNameUnproven) — no guessing, no fallback chain. The probe
// ran on the omp build installed on this node (18.22.0 — the matrix-locked
// 18.7.0 binary was replaced on 2026-11-17; see the B7 record's drift note).
var provenCredentials = []ProvenCredential{
	{ProviderOpenAI, "OPENAI_API_KEY",
		`OpenAI 401 "Incorrect API key provided: sk-dummy…" — the dummy value reached the provider`},
	{ProviderAnthropic, "ANTHROPIC_API_KEY",
		`Anthropic 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}} — the dummy value reached the provider`},
	{ProviderXAI, "XAI_API_KEY",
		`xAI 400 "Incorrect API key provided. You can obtain an API key from https://console.x.ai." — the dummy value reached the provider`},
	{ProviderGoogle, "GEMINI_API_KEY",
		`Google API error (400): "API key not valid. Please pass a valid API key." — the dummy value reached the provider; GOOGLE_API_KEY set instead answers the local missing-key error, so the name is GEMINI_API_KEY`},
	{ProviderGroq, "GROQ_API_KEY",
		`Groq 401 "Invalid API Key" — the dummy value reached the provider`},
}

// ProvenName returns the proven env-var name for one provider. The second
// return is false when the provider has no proven env-var name — which
// includes both unknown providers and ProviderLlamaCpp, whose credentials
// live in the auth store and never in an environment variable.
func ProvenName(p Provider) (ProvenCredential, bool) {
	for _, c := range provenCredentials {
		if c.Provider == p {
			return c, true
		}
	}
	return ProvenCredential{}, false
}

// InjectCredential is one credential-injection request: the env entry the
// adapter adds to one run's environment.
type InjectCredential struct {
	Provider Provider
	// Value is the secret. It travels as one environment entry for the
	// runner process (the node agent's child), never as argv, never in a
	// shell string, and never in a journal row or a log line.
	Value string
}

// EnvEntry resolves the injection against the proven-name table and returns
// the NAME=value entry. It fails closed (AC5/B7): an unproven name —
// including a provider with no proven env var — is a named error, never a
// guessed name and never a fallback chain.
func (r InjectCredential) EnvEntry() (string, error) {
	if strings.TrimSpace(r.Value) == "" {
		return "", fmt.Errorf("%w: provider %q has an empty value",
			ErrCredentialNameUnproven, r.Provider)
	}
	prov, ok := ProvenName(r.Provider)
	if !ok {
		return "", fmt.Errorf("%w: provider %q has no proven env-var name (proven set: %s)",
			ErrCredentialNameUnproven, r.Provider, providerList())
	}
	return prov.EnvVar + "=" + r.Value, nil
}

// ProvenNames is the proven-name table for surfaces and tests: one name per
// proven provider, in provider order.
func ProvenNames() []ProvenCredential {
	out := make([]ProvenCredential, len(provenCredentials))
	copy(out, provenCredentials)
	return out
}

// providerList is the closed provider set, for error text.
func providerList() string {
	names := []string{string(ProviderOpenAI), string(ProviderAnthropic),
		string(ProviderXAI), string(ProviderGoogle), string(ProviderGroq),
		string(ProviderLlamaCpp)}
	sort.Strings(names)
	return strings.Join(names, ", ")
}
