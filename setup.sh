#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Locate brew (handles non-standard install paths)
BREW=""
for candidate in \
  /Users/akshatsingh/homebrew/bin/brew \
  /opt/homebrew/bin/brew \
  /usr/local/bin/brew \
  "$(command -v brew 2>/dev/null)"
do
  if [ -x "$candidate" ]; then BREW="$candidate"; break; fi
done

if [ -z "$BREW" ]; then
  echo "→ Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then BREW="$candidate"; break; fi
  done
fi

echo "→ Brew: $BREW"
echo "→ Installing XcodeGen..."
"$BREW" install xcodegen
XCODEGEN="$("$BREW" --prefix)/bin/xcodegen"

echo "→ Creating Tests folder (required by project.yml)..."
mkdir -p Tests

echo "→ Creating entitlements file..."
cat > App/DAWQ.entitlements << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.healthkit</key>
    <true/>
    <key>com.apple.developer.healthkit.access</key>
    <array/>
</dict>
</plist>
EOF

echo "→ Generating DAWQ.xcodeproj..."
"$XCODEGEN" generate

echo ""
echo "✓ Done! Open with:"
echo "  open DAWQ.xcodeproj"
echo ""
open DAWQ.xcodeproj
