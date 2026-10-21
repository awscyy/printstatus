#!/usr/bin/env ruby
# Generate the tap entry from the exact, verified GitHub release download.
require "digest"
require "fileutils"
require "rubygems"

version, archive, destination = ARGV
abort "Usage: update-cask.rb VERSION ARCHIVE CASK_PATH" unless ARGV.length == 3
abort "Invalid version" unless version.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
sha256 = Digest::SHA256.file(archive).hexdigest

if File.exist?(destination)
  current = File.read(destination)
  old_version = current[/^  version "([^"]+)"$/, 1]
  abort "Cannot read existing cask version" unless old_version
  if Gem::Version.new(version) < Gem::Version.new(old_version)
    puts "Keeping newer cask #{old_version}; not downgrading to #{version}"
    exit
  end
  if version == old_version && current[/^  sha256 "([^"]+)"$/, 1] != sha256
    abort "Published version #{version} already has a different checksum"
  end
end

FileUtils.mkdir_p(File.dirname(destination))
File.write(destination, <<~CASK)
  cask "printstatus" do
    version "#{version}"
    sha256 "#{sha256}"

    url "https://github.com/awscyy/printstatus/releases/download/v\#{version}/PrintStatus-\#{version}.zip"
    name "PrintStatus"
    desc "Menu bar status and model previews for Prusa Connect printers"
    homepage "https://github.com/awscyy/printstatus"

    depends_on macos: :sonoma

    app "PrintStatus.app"

    uninstall quit: "org.aidans.PrintStatus"

    zap trash: "~/Library/Preferences/org.aidans.PrintStatus.plist"
  end
CASK
