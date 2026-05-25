//
//  Constants.swift
//  patcher
//
//  Created by Gil Burns on 3/9/25.
//

import Foundation

struct AppConstants {
    
    static let currentPid: Int32 = ProcessInfo.processInfo.processIdentifier
    static let randomGUID = UUID().uuidString

    static let patcherFullName = "Third Party Patcher"
    static let patcherVersion = "0.2.2"

    // MARK: - Binary paths

    #if DEBUG
    static let installPrefix = "/usr/local/bin/tpp_dev"
    #else
    static let installPrefix = "/usr/local/bin/tpp"
    #endif

    static let patcherBinaryURL    = URL(fileURLWithPath: "\(installPrefix)/patcher")
    static let schedulerBinaryURL  = URL(fileURLWithPath: "\(installPrefix)/patcherscheduler")
    static let reportBinaryURL     = URL(fileURLWithPath: "\(installPrefix)/patcherreport")
    static let patcherMenuAppURL             = URL(fileURLWithPath: "\(installPrefix)/PatcherMenu.app")
    static let availableSoftwareAppURL       = URL(fileURLWithPath: "/Applications/Available Software.app")
    static let availableSoftwareBundleID     = "com.gilburns.AvailableSoftware"

    static let patcherMenuLaunchAgentLabel = "com.gilburns.patcher.menu"
    static let patcherMenuLaunchAgentURL   = URL(fileURLWithPath: "/Library/LaunchAgents/com.gilburns.patcher.menu.plist")

    static let patcherXPCServiceName = "com.gilburns.patcher.xpc"

    static let applicationSupportURL: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .localDomainMask)
            .first?
            .appendingPathComponent("Application Support") ?? URL(fileURLWithPath: "/Library/Application Support")
    }()

    /// Base folder for all patcher data.
    /// When the environment variable PATCHER_DATA_DIR is set, that path is used
    /// instead — allowing tests to redirect all derived paths to a temp directory
    /// without requiring root access.
    static var patcherFolderURL: URL {
        if let override = ProcessInfo.processInfo.environment["PATCHER_DATA_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return applicationSupportURL.appendingPathComponent("Patcher")
    }

    static let patcherCacheFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Cache")
    }()

    static let patcherConfigFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Config")
    }()

    static let patcherDiscoveredFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Discovered")
    }()

    static let installomatorFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Installomator")
    }()

    static let installomatorMetadataFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Installomator-Metadata")
    }()

    static let installomatorLabelsFolderURL: URL = {
        installomatorFolderURL
            .appendingPathComponent("Labels")
    }()

    static let managedFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Managed")
    }()

    static let managedLabelsFolderURL: URL = {
        managedFolderURL
            .appendingPathComponent("Labels")
    }()

    static let managedIconsFolderURL: URL = {
        managedFolderURL
            .appendingPathComponent("Icons")
    }()

    static let managedMetadataFolderURL: URL = {
        managedFolderURL
            .appendingPathComponent("Metadata")
    }()

    static let patcherScannedFolderURL: URL = {
        patcherFolderURL
            .appendingPathComponent("Scanned")
    }()

    static let managedLabelsVersionFileURL: URL = {
        managedFolderURL
            .appendingPathComponent("Version.txt")
    }()

    static let patcherConfigFileURL: URL = {
        patcherConfigFolderURL
            .appendingPathComponent("config.json")
    }()

    /// Accumulates stage/apply results between scheduled webhook notification sends.
    /// Cleared automatically after each successful sendReport run.
    static let webhookReportLogURL: URL = {
        patcherConfigFolderURL
            .appendingPathComponent("webhook_report.json")
    }()

    static let installomatorVersionFileURL: URL = {
        installomatorFolderURL
            .appendingPathComponent("Version.txt")
    }()
    
    // MARK: - swiftDialog

    static let swiftDialogBinaryURL              = URL(fileURLWithPath: "/usr/local/bin/dialog")
    static let swiftDialogCommandFileURL         = URL(fileURLWithPath: "/var/tmp/com.gilburns.patcher.dialog.command")
    static let swiftDialogProgressCommandFileURL = URL(fileURLWithPath: "/var/tmp/com.gilburns.patcher.progress.command")

    static let patcherTempFolderURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("patcher_\(currentPid)_\((randomGUID)[(randomGUID).startIndex..<(randomGUID).index((randomGUID).startIndex, offsetBy: 8)])")
    
    static let csvFilePath = AppConstants.patcherTempFolderURL
        .appendingPathComponent("installomator_results.csv")

    
    static let processLabelZsh = """
#!/bin/zsh

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
export LANG="en_US.UTF-8"

currentUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')

################################
# FUNCTIONS FUNCTIONS FUNCTIONS
################################

downloadURLFromGit() { # $1 git user name, $2 git repo name
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}

    if [[ $type == "pkgInDmg" ]]; then
        filetype="dmg"
    elif [[ $type == "pkgInZip" ]]; then
        filetype="zip"
    else
        filetype=$type
    fi

    if [ -n "$archiveName" ]; then
        downloadURL=$(curl -sfL "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | awk -F '"' "/browser_download_url/ && /$archiveName\\"/ { print \\$4; exit }")
        if [[ "$(echo $downloadURL | grep -ioE "https.*$archiveName")" == "" ]]; then
            #downloadURL=https://github.com$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\\n" | grep -i "^/.*\\/releases\\/download\\/.*$archiveName" | head -1)
            downloadURL="https://github.com$(curl -sfL "$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\\n" | grep -i "expanded_assets" | head -1)" | tr '"' "\\n" | grep -i "^/.*\\/releases\\/download\\/.*$archiveName" | head -1)"
        fi
    else
        downloadURL=$(curl -sfL "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | awk -F '"' "/browser_download_url/ && /$filetype\\"/ { print \\$4; exit }")
        if [[ "$(echo $downloadURL | grep -ioE "https.*.$filetype")" == "" ]]; then
            #downloadURL=https://github.com$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\\n" | grep -i "^/.*\\/releases\\/download\\/.*\\.$filetype" | head -1)
            downloadURL="https://github.com$(curl -sfL "$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\\n" | grep -i "expanded_assets" | head -1)" | tr '"' "\\n" | grep -i "^/.*\\/releases\\/download\\/.*\\.$filetype" | head -1)"
        fi
    fi
    if [ -z "$downloadURL" ]; then
        cleanupAndExit 14 "could not retrieve download URL for $gitusername/$gitreponame" ERROR
    else
        echo "$downloadURL"
        return 0
    fi
}


versionFromGit() {
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}

    appNewVersion=$(curl -sLI "https://github.com/$gitusername/$gitreponame/releases/latest" | grep -i "^location" | tr "/" "\\n" | tail -1 | sed 's/[^0-9\\.]//g')
    if [ -z "$appNewVersion" ]; then
        printlog "could not retrieve version number for $gitusername/$gitreponame" WARN
        appNewVersion=""
    else
        echo "$appNewVersion"
        return 0
    fi
}


xpath() {
    if [[ $(sw_vers -buildVersion) > "20A" ]]; then
        /usr/bin/xpath -q -e $@
    else
        /usr/bin/xpath -q $@
    fi
}


getJSONValue() {
    printf '%s' "$1" | /usr/bin/osascript -l 'JavaScript' \
        -e "let json = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile$(/usr/bin/uname -r | /usr/bin/awk -F '.' '($1 > 18) { print "AndReturnError(ObjC.wrap())" }'), $.NSUTF8StringEncoding)" \
        -e 'if ($.NSFileManager.defaultManager.fileExistsAtPath(json)) json = $.NSString.stringWithContentsOfFileEncodingError(json, $.NSUTF8StringEncoding, ObjC.wrap())' \
        -e "const value = JSON.parse(json.js)$([ -n "${2%%[.[]*}" ] && echo '.')$2" \
        -e 'if (typeof value === "object") { JSON.stringify(value, null, 4) } else { value }'
}


printlog() { :; }

################################
# MAIN  MAIN  MAIN  MAIN  MAIN
################################

if [[ -z "$1" ]]; then
    echo "Label file path required"
    exit 1
fi

fullPathToLabel="$1"

# Ensure the label file exists
if [[ ! -f "$fullPathToLabel" ]]; then
    echo "Label file does not exist: $fullPathToLabel"
    exit 1
fi

# Get the label from the full path for the eval
label=$fullPathToLabel:t:r

# Surpress helper tools from running when labels are evaluated
INSTALL="force"

# Read contents of the label into variable
labelFile=$(/bin/cat "${fullPathToLabel}")

# Load all values in label into respective variables
eval 'case "$label" in '"$labelFile"'; esac' >/dev/null 2>&1

# If appCustomVersion is a function, call it to resolve the installed version.
# A non-empty result means the item is installed; blank or failed means not installed.
resolvedCustomVersion=""
if typeset -f appCustomVersion > /dev/null 2>&1; then
    resolvedCustomVersion=$(appCustomVersion 2>/dev/null) || resolvedCustomVersion=""
fi

timeStamp=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")

# Serialize blockingProcesses array as newline-separated string so each element
# is preserved as a distinct entry (zsh "$arrayVar" collapses all elements into one scalar)
blockingProcessesSerialized="${(j:\n:)blockingProcesses}"

# convert variable to json to pass back to Swift code
json_output=$(osascript -l JavaScript -e "
function run(argv) {
    return JSON.stringify({
        appCustomVersion: argv[0],
        appName: argv[1],
        appNewVersion: argv[2],
        archiveName: argv[3],
        blockingProcesses: argv[4].split('\\n').filter(function(s) { return s !== ''; }),
        CLIInstaller: argv[5],
        CLIArguments: argv[6],
        curlOptions: argv[7],
        downloadURL: argv[8],
        expectedTeamID: argv[9],
        installerTool: argv[10],
        label: argv[11],
        name: argv[12],
        packageID: argv[13],
        pkgName: argv[14],
        targetDir: argv[15],
        timeStamp: argv[16],
        type: argv[17],
        updateTool: argv[18],
        updateToolArguments: argv[19],
        updateToolRunAsCurrentUser: argv[20],
        versionKey: argv[21]
    });
}
" "$resolvedCustomVersion" "$appName" "$appNewVersion" "$archiveName" "$blockingProcessesSerialized" "$CLIInstaller" "$CLIArguments" "$curlOptions" "$downloadURL" "$expectedTeamID" "$installerTool" "$label" "$name" "$packageID" "$pkgName" "$targetDir" "$timeStamp" "$type" "$updateTool" "$updateToolArguments" "$updateToolRunAsCurrentUser" "$versionKey" )


# Check if JXA returned an error
if [[ "$json_output" == ERROR* ]]; then
    echo "JXA JSON error: $json_output"
    exit 1
fi

# Output JSON
echo "$json_output" | LC_ALL=C.UTF-8 tr -d '\r'
"""

}

