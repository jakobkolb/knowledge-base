## Enriched MCP Server Integration Test Report

**Date:** 2026-05-03 | **Server:** mcp-obsidian v0.1.0 | **Plugin:** obsidian-local-rest-api v3.6.1

---

### Results Summary

| # | Tool | Status | Notes |
|---|------|--------|-------|
| 1 | `obsidian_list_files_in_vault` | ✅ PASS | |
| 2 | `obsidian_list_files_in_dir` | ✅ PASS | |
| 3 | `obsidian_get_file_contents` | ✅ PASS | |
| 4 | `obsidian_batch_get_file_contents` | ✅ PASS | |
| 5 | `obsidian_simple_search` | ✅ PASS | |
| 6 | `obsidian_complex_search` | ✅ PASS | |
| 7 | `obsidian_append_content` | ✅ PASS | |
| 8 | `obsidian_put_content` | ✅ PASS | |
| 9 | `obsidian_patch_content` | ❌ FAIL | Bug: block target_type broken; heading/frontmatter work |
| 10 | `obsidian_delete_file` | ✅ PASS | |
| 11 | `obsidian_get_periodic_note` | ✅ PASS | |
| 12 | `obsidian_get_recent_periodic_notes` | ❌ FAIL | Bug: endpoint does not exist in plugin v3.6.1 |
| 13 | `obsidian_get_recent_changes` | ✅ PASS | Requires Dataview plugin (installed) |

---

### Bug 1: `obsidian_get_recent_periodic_notes`

**Root cause:** The mcp-obsidian server calls an endpoint that does not exist in the Obsidian Local REST API plugin.

**What the tool calls:**

```
GET /periodic/{period}/recent?limit=N&includeContent=0
```

**How the plugin routes this URL:**
The plugin's `/periodic/{period}/` route returns the current periodic note. Any path segment after `{period}` is interpreted as a `Target-Type` for patching (valid values: `heading`, `block`, `frontmatter`). The word `recent` is not a valid `Target-Type`, so the plugin returns 400.

**Observed request/response:**

```
GET /periodic/daily/recent?limit=5&includeContent=0 HTTP/1.1

HTTP/1.1 400 Bad Request
Content-Location: Diary/2026-05-03.md       <- plugin found the daily note
Content-Type: text/markdown; charset=utf-8

{"message":"The 'Target-Type' header you provided was invalid.","errorCode":40054}
```

The `Content-Location` header confirms the plugin found today's daily note (`Diary/2026-05-03.md`) and then tried to treat `recent` as a target-type section identifier, which is invalid.

**There is no "list recent periodic notes" endpoint in obsidian-local-rest-api v3.6.1.** The plugin only provides:

- `GET /periodic/{period}/` — current periodic note
- `PATCH /periodic/{period}/{target_type}` — patch a section of the current periodic note

**Suggested fix in mcp-obsidian:** Replace the broken endpoint call with a vault file listing + date filtering approach, similar to how `get_recent_changes` uses Dataview DQL. For example:

```python
# Option A: DQL query scoped to periodic note folder
"TABLE file.mtime WHERE file.path =~ \"Diary/.*\" SORT file.mtime DESC LIMIT {limit}"

# Option B: list vault files, filter by naming convention, sort by mtime
```

---

### Bug 2: `obsidian_patch_content` — block target_type

**Root cause:** The `block` target type fails when the `Target` header value uses the `^blockid` syntax (as Obsidian renders it in the UI). The plugin expects the raw block ID without the `^` prefix.

**What the tool sends (for all target types):**

```http
PATCH /vault/{filepath} HTTP/1.1
Content-Type: text/markdown
Target-Type: {heading|block|frontmatter}
Target: {url_percent_encoded_target}
Operation: {append|prepend|replace}
```

**Curl reproducers:**

Working — `heading` type:

```bash
curl -X PATCH https://127.0.0.1:27124/vault/my-note.md \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: text/markdown" \
  -H "Target-Type: heading" \
  -H "Target: Section%20A" \
  -H "Operation: replace" \
  --data "New content."
# HTTP 200
```

Working — `frontmatter` type:

```bash
curl -X PATCH https://127.0.0.1:27124/vault/my-note.md \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: application/json" \
  -H "Target-Type: frontmatter" \
  -H "Target: tags" \
  -H "Operation: replace" \
  --data '["tag1","tag2"]'
# HTTP 200
```

Broken — `block` type with `^` prefix:

```bash
curl -X PATCH https://127.0.0.1:27124/vault/my-note.md \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: text/markdown" \
  -H "Target-Type: block" \
  -H "Target: ^myblock" \
  -H "Operation: replace" \
  --data "New content."
# HTTP 400
# {"message":"The patch you provided could not be applied to the target content.\ninvalid-target","errorCode":40080}
```

Working — `block` type without `^`:

```bash
curl -X PATCH https://127.0.0.1:27124/vault/my-note.md \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: text/markdown" \
  -H "Target-Type: block" \
  -H "Target: myblock" \
  -H "Operation: replace" \
  --data "New content."
# HTTP 200 (note: may duplicate the ^blockid suffix in the output — minor quirk)
```

**Note on URL-encoding:** The mcp-obsidian code calls `urllib.parse.quote(target)` before setting the `Target` header. The plugin correctly URL-decodes it (`Section%20A` resolves to heading `Section A`). This is not a bug.

**Suggested fix in mcp-obsidian:** Clarify in the `patch_content` tool description that for `target_type: block`, the `target` should be the raw block ID without the `^` prefix. Optionally strip a leading `^` defensively in `obsidian.py:patch_content`.

---

### `obsidian_get_recent_changes` — verified working

This tool uses a Dataview DQL query over `POST /search/` and works correctly (Dataview plugin is installed in the vault):

```
POST /search/
Content-Type: application/vnd.olrapi.dataview.dql+txt

TABLE file.mtime
WHERE file.mtime >= date(today) - dur(90 days)
SORT file.mtime DESC
LIMIT 10
```

Returns an array of `{filename, result: {"file.mtime": "..."}}` objects. ✅
