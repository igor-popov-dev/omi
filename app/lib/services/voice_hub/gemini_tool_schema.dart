// Gemini Live tool-schema sanitizer — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/voice/hub/geminiToolSchema.ts`
// (`sanitizeGeminiToolSchema`), used by `gemini_hub_session.dart`'s
// `sessionSetupFrame()` (lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3).
//
// Gemini Live's function-declaration `parameters` is an OpenAPI-3.0 `Schema`,
// NOT full JSON Schema. Any keyword outside this Schema subset — most
// notably `additionalProperties`, which a generic tool manifest may stamp on
// every tool — makes Gemini REJECT the whole BidiGenerateContent setup and
// close the socket within seconds of connect (no `setupComplete`), so a
// warm silently cascades and the reconnect budget bleeds out. We ALLOWLIST
// the supported Schema keys and drop everything else — fail-closed, so a
// future manifest keyword can't reach the wire and silently kill sockets
// again. Field set per the TS source (verified there via Context7 against
// the `@google/genai` `Schema` type) — copied verbatim, not re-derived.
const Set<String> geminiSupportedSchemaKeys = {
  'type',
  'format',
  'title',
  'description',
  'nullable',
  'default',
  'enum',
  'items',
  'minItems',
  'maxItems',
  'properties',
  'required',
  'minProperties',
  'maxProperties',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'pattern',
  'example',
  'anyOf',
  'propertyOrdering',
};

/// Project a JSON Schema onto Gemini's OpenAPI-3.0 `Schema` subset: keep only
/// the allowlisted keys and recurse structurally (into `properties` values —
/// NOT their arbitrary names — plus `items` and `anyOf`). Non-schema-bearing
/// values (`enum`, `required`, `default`, `example`, …) are copied verbatim.
/// Pure: returns a fresh copy, never mutates the input, so a catalog object
/// can be shared across provider lanes (today just the one Gemini lane, but
/// the TS source shares this leaf with a main-side catalog test too).
Object? sanitizeGeminiToolSchema(Object? schema) {
  if (schema is! Map) return schema;
  final out = <String, dynamic>{};
  for (final entry in schema.entries) {
    final key = entry.key;
    if (key is! String || !geminiSupportedSchemaKeys.contains(key)) continue; // fail-closed
    final value = entry.value;
    if (key == 'properties' && value is Map) {
      final props = <String, dynamic>{};
      for (final propEntry in value.entries) {
        props[propEntry.key as String] = sanitizeGeminiToolSchema(propEntry.value);
      }
      out[key] = props;
    } else if (key == 'items') {
      out[key] = sanitizeGeminiToolSchema(value);
    } else if (key == 'anyOf' && value is List) {
      out[key] = value.map(sanitizeGeminiToolSchema).toList();
    } else {
      out[key] = value; // scalar / enum / required / example / default — verbatim
    }
  }
  return out;
}
