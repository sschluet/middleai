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

grep -q -- '--hash=sha256:' Sources/MiddleAICore/Resources/tts-runtime-requirements.txt || {
  print -u2 'TTS Python dependencies must be locked with SHA-256 hashes.'
  exit 1
}

git diff --check
print 'Repository policy audit passed.'
