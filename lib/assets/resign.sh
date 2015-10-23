#!/bin/bash

# Copyright (c) 2011 Float Mobile Learning
# http://www.floatlearning.com/
# Extension Copyright (c) 2013 Weptun Gmbh
# http://www.weptun.de
#
# Extended by Ronan O Ciosoig January 2012
#
# Extended by Patrick Blitz, April 2013
#
# Extended by John Turnipseed and Matthew Nespor, November 2014
# http://nanonation.net/
#
# Extended by Nicolas Bachschmidt, October 2015
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# Please let us know about any improvements you make to this script!
# ./floatsign source "iPhone Distribution: Name" -p "path/to/profile" [-d "display name"]  [-e entitlements] [-k keychain] [-b "BundleIdentifier"] outputIpa
#
#
# Modifed 26th January 2012
#
# new features January 2012:
# 1. change the app display name
#
# new features April 2013
# 1. specify the target bundleId on the command line
# 2. correctly handles entitlements for keychain-enabled resigning
#
# new features November 2014
# 1. now re-signs embedded iOS frameworks, if present, prior to re-signing the application itself
# 2. extracts the team-identifier from provisioning profile and uses it to update previous entitlements
# 3. fixed bug in packaging if -e flag is used
# 4. renamed 'temp' directory and made it a variable so it can be easily modified
# 5. various code formatting and logging adjustments
# 
# new features October 2015
# 1. now re-signs nested applications and app extensions, if present, prior to re-signing the application itself
# 2. enables the -p option to be used more than once
# 3. ensures the provisioning profile's bundle-identifier matches the app's bundle identifier
# 4. extracts the entitlements from the provisioning profile
# 5. copy the entitlements as archived-expanded-entitlements.xcent inside the app bundle (because Xcode does too)
#


function checkStatus {

if [ $? -ne 0 ];
then
    echo "Encountered an error, aborting!" >&2
    exit 1
fi
}

if [ $# -lt 3 ]; then
    echo "usage: $0 source identity -p provisioning [-e entitlements] [-d displayName] [-n version] [-b bundleId] outputIpa" >&2
    echo "       -p option may be provided multiple times" >&2
    exit 1
fi

ORIGINAL_FILE="$1"
CERTIFICATE="$2"
ENTITLEMENTS=
BUNDLE_IDENTIFIER=""
DISPLAY_NAME=""
KEYCHAIN=""
VERSION_NUMBER=""
RAW_PROVISIONS=()
PROVISIONS_BY_ID=()
DEFAULT_PROVISION=""
TEMP_DIR="_floatsignTemp"

# options start index
OPTIND=3
while getopts p:d:e:k:b:n: opt; do
    case $opt in
        p)
            RAW_PROVISIONS+=("$OPTARG")
            if [[ "$OPTARG" =~ .+=.+ ]]; then
                echo "Specified provisioning profile: '${OPTARG#*=}' for bundle identifier: '${OPTARG%%=*}'" >&2
            else
                echo "Specified provisioning profile: '$OPTARG'" >&2
            fi
            ;;
        d)
            DISPLAY_NAME="$OPTARG"
            echo "Specified display name: '$DISPLAY_NAME'" >&2
            ;;
        e)
            ENTITLEMENTS="$OPTARG"
            echo "Specified signing entitlements: '$ENTITLEMENTS'" >&2
            ;;
        b)
            BUNDLE_IDENTIFIER="$OPTARG"
            echo "Specified bundle identifier: '$BUNDLE_IDENTIFIER'" >&2
            ;;
        k)
            KEYCHAIN="$OPTARG"
            echo "Specified Keychain to use: '$KEYCHAIN'" >&2
            ;;
        n)
            VERSION_NUMBER="$OPTARG"
            echo "Specified version to use: '$VERSION_NUMBER'" >&2
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

NEW_FILE="$1"
if [ -z "$NEW_FILE" ]; 
then
    echo "Output file name required" >&2
    exit 1
fi

if [[ "${#RAW_PROVISIONS[*]}" == "0" ]]; then
    echo "-p 'xxxx.mobileprovision' argument is required" >&2
    exit 1;
fi

# Check for and remove the temporary directory if it already exists
if [ -d "$TEMP_DIR" ]; 
then
    echo "Removing previous temporary directory: '$TEMP_DIR'" >&2
    rm -Rf "$TEMP_DIR"
fi

filename=$(basename "$ORIGINAL_FILE")
extension="${filename##*.}"
filename="${filename%.*}"

# Check if the supplied file is an ipa or an app file
if [ "${extension}" = "ipa" ]
then
    # Unzip the old ipa quietly
    unzip -q "$ORIGINAL_FILE" -d $TEMP_DIR
    checkStatus
elif [ "${extension}" = "app" ]
then
    # Copy the app file into an ipa-like structure
    mkdir -p "$TEMP_DIR/Payload"
    cp -Rf "${ORIGINAL_FILE}" "$TEMP_DIR/Payload/${filename}.app"
    checkStatus
else
    echo "Error: Only can resign .app files and .ipa files." >&2
    exit
fi

# check the keychain
if [ "${KEYCHAIN}" != "" ];
then
    security list-keychains -s $KEYCHAIN
    security unlock $KEYCHAIN
    security default-keychain -s $KEYCHAIN
fi

# Set the app name
# The app name is the only file within the Payload directory
APP_NAME=$(ls "$TEMP_DIR/Payload/")

# Make sure that PATH includes the location of the PlistBuddy helper tool as its location is not standard
export PATH=$PATH:/usr/libexec

# Test whether two bundle identifiers match
# The first one may contain the wildcard character '*', in which case pattern matching will be used unless the third parameter is "STRICT"
function does_bundle_id_match {

if [[ "$1" == "$2" ]]; then
    return 0
elif [[ "$3" != STRICT && "$1" =~ \* ]]; then
    local PATTERN0="${1//\./\\.}"       # com.example.*     -> com\.example\.*
    local PATTERN1="${PATTERN0//\*/.*}" # com\.example\.*   -> com\.example\..*
    if [[ "$2" =~ ^$PATTERN1$ ]]; then
        return 0
    fi
fi

return 1
}

# Find the provisioning profile for a given bundle identifier
function provision_for_bundle_id {

for ARG in "${PROVISIONS_BY_ID[@]}"; do
    if does_bundle_id_match "${ARG%%=*}" "$1" "$2"; then
        echo "${ARG#*=}"
        break
    fi
done
}

# Find the bundle identifier contained inside a provisioning profile
function bundle_id_for_provison {

local FULL_BUNDLE_ID=`PlistBuddy -c 'Print :Entitlements:application-identifier' /dev/stdin <<< $(security cms -D -i "$1")`
checkStatus
echo "${FULL_BUNDLE_ID#*.}"
}

# Add given provisioning profile and bundle identifier to the search list
function add_provision_for_bundle_id {

local PROVISION="$1"
local BUNDLE_ID="$2"

local CURRENT_PROVISION=`provision_for_bundle_id "$BUNDLE_ID" STRICT`

if [[ "$CURRENT_PROVISION" != "" && "$CURRENT_PROVISION" != "$PROVISION" ]]; then
    echo "Conflicting provisioning profiles '$PROVISION' and '$CURRENT_PROVISION' for bundle identifier '$BUNDLE_ID'." >&2
    exit 1
fi

PROVISIONS_BY_ID+=("$BUNDLE_ID=$PROVISION")
}

# Add given provisioning profile to the search list
function add_provision {

local PROVISION="$1"

if [[ "$1" =~ .+=.+ ]]; then
    PROVISION="${1#*=}"
    add_provision_for_bundle_id "$PROVISION" "${1%%=*}"
elif [[ "$DEFAULT_PROVISION" == "" ]]; then
    DEFAULT_PROVISION="$PROVISION"
fi

if [[ ! -e "$PROVISION" ]]; then
    echo "Provisioning profile '$PROVISION' file does not exist" >&2
    exit 1;
fi

local BUNDLE_ID=`bundle_id_for_provison "$PROVISION"`
add_provision_for_bundle_id "$PROVISION" "$BUNDLE_ID"
}

# Load bundle identifiers from provisioning profiles
for ARG in "${RAW_PROVISIONS[@]}"; do
    add_provision "$ARG"
done

# Resign the given application
function resign {

local APP_PATH="$1"
local NESTED="$2"
local BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER"
local NEW_PROVISION="$NEW_PROVISION"
local APP_IDENTIFER_PREFIX=""
local TEAM_IDENTIFIER=""

if [[ "$NESTED" == NESTED ]]; then
    # Ignore bundle identifier for nested applications
    BUNDLE_IDENTIFIER=""
fi

# Make sure that the Info.plist file is where we expect it
if [ ! -e "$APP_PATH/Info.plist" ];
then
    echo "Expected file does not exist: '$APP_PATH/Info.plist'" >&2
    exit 1;
fi

# Read in current values from the app
local CURRENT_NAME=`PlistBuddy -c "Print :CFBundleDisplayName" "$APP_PATH/Info.plist"`
local CURRENT_BUNDLE_IDENTIFIER=`PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist"`
local NEW_PROVISION=`provision_for_bundle_id "${BUNDLE_IDENTIFIER:-$CURRENT_BUNDLE_IDENTIFIER}"`

if [[ "$NEW_PROVISION" == "" && "$NESTED" != NESTED ]]; then
    NEW_PROVISION="$DEFAULT_PROVISION"
fi

if [[ "$NEW_PROVISION" == "" ]]; then
    if [[ "$NESTED" == NESTED ]]; then
        echo "No provisioning profile for nested application: '$APP_PATH' with bundle identifier '${BUNDLE_IDENTIFIER:-$CURRENT_BUNDLE_IDENTIFIER}'" >&2
    else
        echo "No provisioning profile for application: '$APP_PATH' with bundle identifier '${BUNDLE_IDENTIFIER:-$CURRENT_BUNDLE_IDENTIFIER}'" >&2
    fi
    echo "Use the -p option (example: -p com.example.app=xxxx.mobileprovision)" >&2
    exit 1;
fi

local PROVISION_BUNDLE_IDENTIFIER=`bundle_id_for_provison "$NEW_PROVISION"`

# Use provisioning profile's bundle identifier
if [ "$BUNDLE_IDENTIFIER" == "" ]; then
    if [[ "$PROVISION_BUNDLE_IDENTIFIER" =~ \* ]]; then
        echo "Bundle Identifier contains a *, using the current bundle identifier" >&2
        BUNDLE_IDENTIFIER="$CURRENT_BUNDLE_IDENTIFIER"
    else
        BUNDLE_IDENTIFIER="$PROVISION_BUNDLE_IDENTIFIER"
    fi
fi

if ! does_bundle_id_match "$PROVISION_BUNDLE_IDENTIFIER" "$BUNDLE_IDENTIFIER"; then
    echo "Bundle Identifier '$PROVISION_BUNDLE_IDENTIFIER' in provisioning profile '$NEW_PROVISION' does not match the Bundle Identifier '$BUNDLE_IDENTIFIER' for application '$APP_PATH'." >&2
    exit 1
fi

echo "Current bundle identifier is: '$CURRENT_BUNDLE_IDENTIFIER'" >&2
echo "New bundle identifier will be: '$BUNDLE_IDENTIFIER'" >&2

# Update the CFBundleDisplayName property in the Info.plist if a new name has been provided
if [ "${DISPLAY_NAME}" != "" ];
then
    if [ "${DISPLAY_NAME}" != "${CURRENT_NAME}" ];
    then
        echo "Changing display name from '$CURRENT_NAME' to '$DISPLAY_NAME'" >&2
        `PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP_PATH/Info.plist"`
    fi
fi

# Replace the embedded mobile provisioning profile
echo "Validating the new provisioning profile: $NEW_PROVISION" >&2
security cms -D -i "$NEW_PROVISION" > "$TEMP_DIR/profile.plist"
checkStatus

APP_IDENTIFER_PREFIX=`PlistBuddy -c "Print :Entitlements:application-identifier" "$TEMP_DIR/profile.plist" | grep -E '^[A-Z0-9]*' -o | tr -d '\n'` 
if [ "$APP_IDENTIFER_PREFIX" == "" ];
then
    APP_IDENTIFER_PREFIX=`PlistBuddy -c "Print :ApplicationIdentifierPrefix:0" "$TEMP_DIR/profile.plist"` 
    if [ "$APP_IDENTIFER_PREFIX" == "" ];
    then
        echo "Failed to extract any app identifier prefix from '$NEW_PROVISION'" >&2
        exit 1;
    else
        echo "WARNING: extracted an app identifier prefix '$APP_IDENTIFER_PREFIX' from '$NEW_PROVISION', but it was not found in the profile's entitlements" >&2
    fi
else
    echo "Profile app identifier prefix is '$APP_IDENTIFER_PREFIX'" >&2
fi

TEAM_IDENTIFIER=`PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$TEMP_DIR/profile.plist" | tr -d '\n'` 
if [ "$TEAM_IDENTIFIER" == "" ];
then
    TEAM_IDENTIFIER=`PlistBuddy -c "Print :TeamIdentifier:0" "$TEMP_DIR/profile.plist"` 
    if [ "$TEAM_IDENTIFIER" == "" ];
    then
        echo "Failed to extract team identifier from '$NEW_PROVISION', resigned ipa may fail on iOS 8 and higher" >&2
    else
        echo "WARNING: extracted a team identifier '$TEAM_IDENTIFIER' from '$NEW_PROVISION', but it was not found in the profile's entitlements, resigned ipa may fail on iOS 8 and higher" >&2
    fi
else
    echo "Profile team identifier is '$TEAM_IDENTIFIER'" >&2
fi

cp "$NEW_PROVISION" "$APP_PATH/embedded.mobileprovision"


#if the current bundle identifier is different from the new one in the provisioning profile, then change it.
if [ "$CURRENT_BUNDLE_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ];
then
    echo "Updating the bundle identifier from '$CURRENT_BUNDLE_IDENTIFIER' to '$BUNDLE_IDENTIFIER'" >&2
    `PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP_PATH/Info.plist"`
    checkStatus
fi

# Update the version number properties in the Info.plist if a version number has been provided
if [ "$VERSION_NUMBER" != "" ];
then
    CURRENT_VERSION_NUMBER=`PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist"`
    if [ "$VERSION_NUMBER" != "$CURRENT_VERSION_NUMBER" ];
    then
        echo "Updating the version from '$CURRENT_VERSION_NUMBER' to '$VERSION_NUMBER'" >&2
        `PlistBuddy -c "Set :CFBundleVersion $VERSION_NUMBER" "$APP_PATH/Info.plist"`
        `PlistBuddy -c "Set :CFBundleShortVersionString $VERSION_NUMBER" "$APP_PATH/Info.plist"`
    fi
fi

# Check for and resign any embedded frameworks (new feature for iOS 8 and above apps)
FRAMEWORKS_DIR="$APP_PATH/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ];
then
    if [ "$TEAM_IDENTIFIER" == "" ];
    then
        echo "ERROR: embedded frameworks detected, re-signing iOS 8 (or higher) applications wihout a team identifier in the certificate/profile does not work" >&2
        exit 1;
    fi
    
    echo "Resigning embedded frameworks using certificate: '$CERTIFICATE'" >&2
    for framework in "$FRAMEWORKS_DIR"/*
    do
        if [[ "$framework" == *.framework || "$framework" == *.dylib ]]
        then
            /usr/bin/codesign -f -s "$CERTIFICATE" "$framework"
            checkStatus
        else
            echo "Ignoring non-framework: $framework" >&2
        fi
    done
fi


if [ "$ENTITLEMENTS" != "" ];
then
    if [ -n "$APP_IDENTIFER_PREFIX" ];
    then
        # sanity check the 'application-identifier' is present in the provided entitlements and matches the provisioning profile value 
        ENTITLEMENTS_APP_ID_PREFIX=`PlistBuddy -c "Print :application-identifier" "$ENTITLEMENTS" | grep -E '^[A-Z0-9]*' -o | tr -d '\n'` 
        if [ "$ENTITLEMENTS_APP_ID_PREFIX" == "" ]; 
        then
            echo "Provided entitlements file is missing a value for the required 'application-identifier' key" >&2
            exit 1;
        elif [ "$ENTITLEMENTS_APP_ID_PREFIX" != "$APP_IDENTIFER_PREFIX" ]; 
        then
            echo "Provided entitlements file's app identifier prefix value '$ENTITLEMENTS_APP_ID_PREFIX' does not match the provided provisioning profile's value '$APP_IDENTIFER_PREFIX'" >&2
            exit 1;
        fi
    fi

    if [ -n "$TEAM_IDENTIFIER" ];
    then
        # sanity check the 'com.apple.developer.team-identifier' is present in the provided entitlements and matches the provisioning profile value
        ENTITLEMENTS_TEAM_IDENTIFIER=`PlistBuddy -c "Print :com.apple.developer.team-identifier" "$ENTITLEMENTS" | tr -d '\n'` 
        if [ "$ENTITLEMENTS_TEAM_IDENTIFIER" == "" ]; 
        then
            echo "Provided entitlements file is missing a value for the required 'com.apple.developer.team-identifier' key" >&2
            exit 1;
        elif [ "$ENTITLEMENTS_TEAM_IDENTIFIER" != "$TEAM_IDENTIFIER" ]; 
        then
            echo "Provided entitlements file's 'com.apple.developer.team-identifier' '$ENTITLEMENTS_TEAM_IDENTIFIER' does not match the provided provisioning profile's value '$TEAM_IDENTIFIER'" >&2
            exit 1;
        fi
    fi

    echo "Resigning application using certificate: '$CERTIFICATE'" >&2
    echo "and entitlements: $ENTITLEMENTS" >&2
    cp -- "$ENTITLEMENTS" "$APP_PATH/archived-expanded-entitlements.xcent"
    /usr/bin/codesign -f -s "$CERTIFICATE" --entitlements="$ENTITLEMENTS" "$APP_PATH"
    checkStatus
else
    echo "Extracting entitlements from provisioning profile" >&2
    PlistBuddy -x -c "Print Entitlements" "$TEMP_DIR/profile.plist" > "$TEMP_DIR/newEntitlements"
    checkStatus
    echo "Resigning application using certificate: '$CERTIFICATE'" >&2
    echo "and entitlements from provisioning profile: $NEW_PROVISION" >&2
    cp -- "$TEMP_DIR/newEntitlements" "$APP_PATH/archived-expanded-entitlements.xcent"
    /usr/bin/codesign -f -s "$CERTIFICATE" --entitlements="$TEMP_DIR/newEntitlements" "$APP_PATH"
    checkStatus
fi

# Remove the temporary files if they were created before generating ipa
rm -f "$TEMP_DIR/newEntitlements"
rm -f "$TEMP_DIR/profile.plist"

}

# Sign nested applications and app extensions
while IFS= read -d '' -r app;
do
    echo "Resigning nested application: '$app'" >&2
    resign "$app" NESTED
done < <(find "$TEMP_DIR/Payload/$APP_NAME" -d -mindepth 1 \( -name "*.app" -or -name "*.appex" \) -print0)

# Resign the application
resign "$TEMP_DIR/Payload/$APP_NAME"

# Repackage quietly
echo "Repackaging as $NEW_FILE" >&2

# Zip up the contents of the "$TEMP_DIR" folder
# Navigate to the temporary directory (sending the output to null)
# Zip all the contents, saving the zip file in the above directory
# Navigate back to the orignating directory (sending the output to null)
pushd "$TEMP_DIR" > /dev/null
zip -qry "../$TEMP_DIR.ipa" *
popd > /dev/null

# Move the resulting ipa to the target destination
mv "$TEMP_DIR.ipa" "$NEW_FILE"

# Remove the temp directory
rm -rf "$TEMP_DIR"

echo "Process complete" >&2