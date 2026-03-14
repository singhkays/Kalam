#!/bin/bash

# Exit on error
set -e

PROJECT_ROOT=$(pwd)
APP_DIR="$PROJECT_ROOT/app"
BUILD_DIR="$PROJECT_ROOT/build"
ASSETS_DIR="$PROJECT_ROOT/assets"
ARCHIVE_PATH="$BUILD_DIR/Kalam.xcarchive"
APP_NAME="Kalam"
BUNDLE_ID="singhkays.Kalam"
DMG_NAME="Kalam.dmg"
DMG_VOL_NAME="Kalam Installer"
BACKGROUND_FILE="$ASSETS_DIR/dmg_background.png"

echo "🚀 Starting build process for $APP_NAME..."

# Create build directory
mkdir -p "$BUILD_DIR"

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive the app
echo "📦 Archiving the application..."
# If SIGNING_IDENTITY is not provided, we use '-' for ad-hoc signing (local only, no notarization possible)
SIGNING_ID="${SIGNING_IDENTITY:--}"

xcodebuild archive \
    -project "$APP_DIR/Kalam.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="$SIGNING_ID" \
    CODE_SIGN_STYLE="Manual"

# App path inside the archive
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app at $APP_PATH"
    exit 1
fi

# Create a temporary directory for DMG content
echo "📂 Preparing DMG content..."
DMG_TEMP_DIR="$BUILD_DIR/dmg_temp"
rm -rf "$DMG_TEMP_DIR"
mkdir -p "$DMG_TEMP_DIR"
cp -R "$APP_PATH" "$DMG_TEMP_DIR/"
ln -s /Applications "$DMG_TEMP_DIR/Applications"

# Set up the background image in a hidden folder
mkdir -p "$DMG_TEMP_DIR/.background"
cp "$BACKGROUND_FILE" "$DMG_TEMP_DIR/.background/background.png"

# Create a master DMG first (read/write to apply AppleScript)
echo "💿 Creating intermediate DMG..."
MASTER_DMG="$BUILD_DIR/Kalam_master.dmg"
rm -f "$MASTER_DMG"
hdiutil create -volname "$DMG_VOL_NAME" -srcfolder "$DMG_TEMP_DIR" -ov -format UDRW "$MASTER_DMG"

# Mount the intermediate DMG
echo "🔌 Mounting intermediate DMG..."
# -noautoopen prevents Finder from popping up locally
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$MASTER_DMG" | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 5 # Give Finder more time to see the volume

# Apply AppleScript for layout
echo "✍️ Applying AppleScript layout..."
APPLESCRIPT="
tell application \"Finder\"
  set diskName to \"$DMG_VOL_NAME\"
  repeat 15 times
    if exists disk diskName then exit repeat
    delay 1
  end repeat
  
  tell disk diskName
    set theView to container window
    # Try to open only if not already open
    try
        open
    end try
    delay 2
    set current view of theView to icon view
    set toolbar visible of theView to false
    set statusbar visible of theView to false
    # bounds: {left, top, right, bottom}
    set the bounds of theView to {400, 100, 1000, 500}
    
    set viewOptions to the icon view options of theView
    set icon size of viewOptions to 120
    set background picture of viewOptions to file (diskName & \":.background:background.png\")
    set arrangement of viewOptions to not arranged
    
    delay 2
    # Icons centered vertically at Y=180
    set position of item \"$APP_NAME.app\" of theView to {150, 180}
    set position of item \"Applications\" of theView to {450, 180}
    
    update every item with registering applications
    delay 2
    close
  end tell
end tell
"
echo "$APPLESCRIPT" | osascript

# Finalize the DMG
echo "🧹 Unmounting and converting to final DMG..."
sync
hdiutil detach "$DEVICE"
sleep 5

DMG_PATH="$BUILD_DIR/$DMG_NAME"
rm -f "$DMG_PATH"
hdiutil convert "$MASTER_DMG" -format UDZO -o "$DMG_PATH"
rm -f "$MASTER_DMG"

echo "✅ Stylized DMG created: $DMG_PATH"

# Cleanup temp dir
rm -rf "$DMG_TEMP_DIR"

# Create GitHub Release
if [ "$CI" = "true" ]; then
    echo "🤖 CI detected. Skipping internal 'gh release' call. Workflow will handle artifact upload."
    exit 0
fi

if command -v gh &> /dev/null; then
    echo "🚀 Creating GitHub Release..."
    VERSION=$(grep -m 1 "MARKETING_VERSION =" "$APP_DIR/Kalam.xcodeproj/project.pbxproj" | cut -d'=' -f2 | tr -d ' ;' | head -n 1)
    if [ -z "$VERSION" ]; then VERSION="1.0.0"; fi
    
    TAG="v$VERSION"
    
    if gh release view "$TAG" &> /dev/null; then
        echo "🗑️ Deleting existing release $TAG..."
        gh release delete "$TAG" --yes
    fi
    
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        git tag -d "$TAG"
    fi

    gh release create "$TAG" "$DMG_PATH" --title "Release $TAG" --notes "Kalam macOS Release. Open the DMG and drag Kalam to the Applications folder to install. This release features a stylized installer aligned with our brand aesthetic."
    echo "🎉 Release created successfully!"
else
    echo "⚠️ GitHub CLI (gh) not found. Skipping release creation."
fi
