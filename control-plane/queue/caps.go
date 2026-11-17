package queue

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Tier tokens of the Model map (SPEC-037 M12). A map value that resolves to
// one of these is a tier key; any other resolved string is a full vendor slug.
var tierTokens = []string{"opus", "sonnet", "haiku"}

// MatchKey derives the per-model-endpoint match key from a resolved model
// string (§ the match key in the package doc): the tier token when the
// string is one of the three shipped tokens; the full slug otherwise; the
// tier-default key when the resolution was empty.
//
// The comparison is byte-exact. A slug is never truncated and never matched
// by prefix: a stale or misspelled slug matches nothing rather than matching
// a family (CDT-603's failure mode, applied to slots).
func MatchKey(model string) string {
	if strings.TrimSpace(model) == "" {
		return "tier-default"
	}
	for _, t := range tierTokens {
		if model == t {
			return t
		}
	}
	return model
}

// caps is a resolved cap pair: the node concurrency setting and the
// per-model-endpoint cap for one match key. Both are enforced
// independently (AC2).
type caps struct {
	// Concurrency is the node's Spawn concurrency cap (CDT-573). 0 means
	// unbounded.
	Concurrency int
	// ModelCap is the per-model-endpoint ceiling the Model map names for the
	// match key. 0 means unbounded: no map row for the match key and no
	// "tier-default" row.
	ModelCap int
}

// parseCap is the one cap reader: a positive decimal integer with no sign,
// spaces, or leading zeros. resolve-concurrency.sh applies the same rule to
// its layers; the queue applies it to whatever a layer names.
func parseCap(raw string) (int, error) {
	if raw == "" {
		return 0, nil
	}
	if len(raw) > 1 && raw[0] == '0' {
		return 0, fmt.Errorf("%w: cap %q is not an integer >= 1", ErrConfig, raw)
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 0, fmt.Errorf("%w: cap %q is not an integer >= 1", ErrConfig, raw)
	}
	return n, nil
}

// concurrencyFromDoc reads the top-level "concurrency" key of one Model-map
// layer, the CDT-573 Spawn concurrency cap. Absent, null, or an empty
// string means the layer names no cap. Any other non-integer value fails
// closed (SPEC-037 M33), reported with the file it came from.
func concurrencyFromDoc(doc map[string]json.RawMessage, file string) (int, error) {
	raw, ok := doc["concurrency"]
	if !ok || strings.TrimSpace(string(raw)) == "null" || strings.TrimSpace(string(raw)) == `""` {
		return 0, nil
	}
	var n int
	if err := json.Unmarshal(raw, &n); err != nil || n < 1 {
		return 0, fmt.Errorf("%w: concurrency in %s is not an integer >= 1", ErrConfig, file)
	}
	return n, nil
}

// modelSlots decodes the top-level "model_slots" object of one Model-map
// layer. It accepts the same value shapes resolve-model.sh's
// concurrency_from_layer accepts for the concurrency key: a JSON integer >= 1
// is a cap; JSON null, an empty string, or an absent key means the layer
// names no cap. Any other value is a fail-closed configuration error
// (SPEC-037 M33), reported with the file it came from.
//
// Unknown top-level keys are ignored, the SPEC-037 M22 reader rule — the
// same forward-compatibility that lets a pre-CDT-573 reader ignore
// "concurrency" lets a pre-CDT-649 reader ignore "model_slots".
func modelSlots(raw []byte, file string) (map[string]int, error) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, nil
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		// A layer that is not a JSON object is skipped whole (SPEC-037 M32):
		// resolve-model.sh does the same for its layers.
		return nil, nil
	}
	rawSlots, ok := doc["model_slots"]
	if !ok {
		return nil, nil
	}
	if strings.TrimSpace(string(rawSlots)) == "null" {
		return nil, nil
	}
	var slots map[string]json.RawMessage
	if err := json.Unmarshal(rawSlots, &slots); err != nil {
		return nil, fmt.Errorf("%w: model_slots in %s is not an object of integer caps", ErrConfig, file)
	}
	out := make(map[string]int, len(slots))
	for k, rawVal := range slots {
		if k == "" {
			return nil, fmt.Errorf("%w: model_slots in %s carries an empty key", ErrConfig, file)
		}
		if strings.TrimSpace(string(rawVal)) == "null" || strings.TrimSpace(string(rawVal)) == `""` {
			continue
		}
		var n int
		if err := json.Unmarshal(rawVal, &n); err != nil || n < 1 {
			return nil, fmt.Errorf("%w: model_slots.%s in %s is not an integer >= 1", ErrConfig, k, file)
		}
		out[k] = n
	}
	return out, nil
}
