cask "jev-voice" do
  version "0.9.1"
  sha256 "46280f5eebfa0210e9c4faa93edecee4245a00d28136378b6b88adf1e16ba841"

  url "https://github.com/chris-wozniczek/jev-voice-control/releases/download/v#{version}/Jev-Voice-#{version}.zip"
  name "Jev Voice"
  desc "Menu-bar voice control powered by TypeSafe AI's Jev"
  homepage "https://github.com/chris-wozniczek/jev-voice-control"

  depends_on :macos

  app "Jev Voice.app"

  # The app is ad-hoc signed (no Apple Developer ID yet); drop the quarantine
  # flag so Gatekeeper does not block the first launch.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Jev Voice.app"],
        must_succeed: false
  end

  uninstall quit: "com.chriswozniczek.jevvoice"

  zap trash: "~/Library/Preferences/com.chriswozniczek.jevvoice.plist"

  caveats <<~EOS
    Jev Voice lives in the menu bar (no Dock icon). Press Option+Space to talk.
    Grant Microphone, Speech Recognition and Accessibility permissions when prompted,
    then set your TypeSafe API key in the popover's Settings (gear icon).
    If macOS still reports the app "Not Opened" (ad-hoc signature), run:
      xattr -dr com.apple.quarantine "#{appdir}/Jev Voice.app"
  EOS
end
