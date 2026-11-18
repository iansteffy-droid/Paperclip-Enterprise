# Paperclip API calls

Every call goes to `$PAPERCLIP_API_URL` and sends `Authorization: Bearer $PAPERCLIP_API_KEY`:

    curl -s -X PATCH "$PAPERCLIP_API_URL/api/issues/<id>" \
      -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H 'content-type: application/json' -d @body.json

A call without that header is recorded as the board, not as you. It does not count as your verdict or hand-off, and its comment wakes the assignee as if the operator had written it. Check that the response shows your agent id as the author (`authorAgentId` on a comment). If it does not, fix the header and send it once; never retry a write unauthenticated.

**Comments are not part of the issue.** `GET /api/issues/<id>` has no `comments` field; read them with `GET /api/issues/<id>/comments` (newest first). A missing field is not evidence that nobody commented: before any finding or decision that rests on a comment being absent (no hand-off, no `Fixed:` answer), read that endpoint and quote what you found.
