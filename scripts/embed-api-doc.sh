#!/bin/bash
# Writes Sources/VoiceCore/APIDoc.swift from API.md, so the service can serve the document
# (GET /api.md) and the panel can copy it, without a resource bundle to find at run time.
# Run it after editing API.md; the tests fail when the two have drifted apart.
set -euo pipefail
cd "$(dirname "$0")/.."
out=Sources/VoiceCore/APIDoc.swift
if grep -q '"#' API.md; then
  echo "error: API.md contains \"# which would end the raw string literal; change the delimiter in $0" >&2
  exit 1
fi
{
  echo '// Generated from API.md by scripts/embed-api-doc.sh. Edit API.md, then run the script.'
  echo 'import Foundation'
  echo
  echo '/// API.md, the contract for client apps, as shipped with this build.'
  echo 'public enum APIDoc {'
  echo '    /// The port API.md is written for.'
  echo '    public static let documentedPort = 8767'
  echo
  echo '    /// API.md as it is in the repository.'
  echo '    public static let markdown = #"""'
  cat API.md
  # A blank line, so the literal ends with the file's final newline (a multi-line string drops
  # the newline before its closing delimiter).
  echo
  echo '"""#'
  echo
  echo '    /// API.md with the port the service is actually listening on.'
  echo '    public static func markdown(port: Int) -> String {'
  echo '        guard port != documentedPort else { return markdown }'
  echo '        return markdown.replacingOccurrences(of: ":\(documentedPort)", with: ":\(port)")'
  echo '    }'
  echo '}'
} > "$out"
echo "wrote $out"
