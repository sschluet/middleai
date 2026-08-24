#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

required_files=(
  LICENSE
  NOTICE
  THIRD_PARTY_NOTICES.md
  Package.resolved
  Sources/MiddleAICore/Resources/tts-runtime-requirements.txt
)
for required_file in $required_files; do
  [[ -s "$required_file" ]] || {
    print -u2 "Missing required supply-chain file: $required_file"
    exit 1
  }
done

if git grep -I -n -E -- \
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' \
  -- ':!scripts/audit-repository.sh'; then
  print -u2 'Private-key material must not be committed.'
  exit 1
fi

if git grep -I -n -E -- \
  "(api[_-]?key|access[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9_./+:-]{20,}[\"']" \
  -- '*.swift' '*.json' '*.yaml' '*.yml' '*.sh' ':!scripts/audit-repository.sh'; then
  print -u2 'A likely hard-coded credential was found.'
  exit 1
fi

if git grep -I -n -i -E -- 'fluid[[:space:]]?voice' -- ':!scripts/audit-repository.sh'; then
  print -u2 'Obsolete product-comparison references must not be committed.'
  exit 1
fi

if git grep -I -n -F -- 'arguments: ["dumpbtm"]' -- '*.swift'; then
  print -u2 'Background scans must not invoke sfltool dumpbtm because it requests admin authorization.'
  exit 1
fi

# OpenAI and OpenRouter are supported answer providers. Product names are allowed when they
# describe that integration; obsolete product-comparison references remain blocked above.

grep -q -- '--hash=sha256:' Sources/MiddleAICore/Resources/tts-runtime-requirements.txt || {
  print -u2 'TTS Python dependencies must be locked with SHA-256 hashes.'
  exit 1
}

plutil -lint Resources/Info.plist >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMessage' Resources/Info.plist)" == \
  "editSelectedText" ]] || {
  print -u2 'The selected-text macOS service is missing its handler declaration.'
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSSendTypes:0' Resources/Info.plist)" == \
  "public.plain-text" ]] || {
  print -u2 'The selected-text macOS service must accept generic plain text.'
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSSendTypes:1' Resources/Info.plist)" == \
  "public.utf8-plain-text" ]] || {
  print -u2 'The selected-text macOS service must accept UTF-8 plain text.'
  exit 1
}

git diff --check
print 'Repository policy audit passed.'
