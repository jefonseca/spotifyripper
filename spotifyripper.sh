#!/bin/bash
##############################################################################
# Record music from Spotify to acc or ogg 
# https://github.com/jefonseca/spotifyripper
##############################################################################

# Do not run it with the root user
if [[ $EUID -eq 0 ]]; then
   print_error "This script must not be run as root"
   exit 1
fi

# Check for missing depencies
if [ ! `which which` ]; then
	echo "FATAL: \"which\" was not found in the system"
	exit 2
else
	requeriments='tr killall dbus-monitor pacmd pactl parec fdkaac oggenc'
	for req in $requeriments
	do
		reqcheck=`which $req`
		if [ ! $reqcheck ]; then
			echo "FATAL: \"$req\" was not found"
			exit 2
		fi
	done
fi

# Recieve the recording dir as first argument
if [[ -z $1 ]]; then
	recordingdir="."
else
	recordingdir="${1//[^ A-Za-z0-9._-]/}"
fi

# Set the default values
aac_profile="${aac_profile:-29}"
bitrate="${bitrate:-48}"
recordformat="${recordformat:-aac}"
filenamescheme="${filenamescheme:-normal}"
nulloutput_name=${nulloutput_name:-spotifyrecording}

# Load the configuration file if exists that will override the default values
scriptdirectory=$(dirname $(readlink -f $0))
if [ -s "$scriptdirectory/spotifyripper.conf" ] || [ -r "$scriptdirectory/spotifyripper.conf" ]; then
	source "$scriptdirectory/spotifyripper.conf"
fi

##############################################################################
# Handle debug messages
# Outputs:
#   debug messages
##############################################################################
debug () {
	debug="${debug:-no}"
	if [[ $debug == "yes" ]]; then
		echo "$1"
	fi
}

##############################################################################
# Return the text received eliminating all "dangerous" characters
# Arguments:
#   1) Mode string: "strict" or "strict-lc" (wich converts to lowercase)
#   2) Input String
# Outputs:
#   String
##############################################################################
sanitize_str () {
	if [[ "$1" == "strict" ]]; then
		echo "$2"|tr -dc '[:alnum:]\n\r'
	elif [[ "$1" == "strict-lc" ]]; then
		echo "$2"|tr -dc '[:alnum:]\n\r'|tr '[:upper:]' '[:lower:]'
	fi
}

##############################################################################
# Read the output of pacmd and search for the sink input for Spotify
# Arguments:
#   None
# Outputs:
#   Sink index for Spotify application
##############################################################################
get_spotifysinkindex () {
	while read listline; do
		[[ $listline == *'index: '* ]] && index=$(echo $listline|cut -d " " -f2)
		[[ $listline == *'application.name = "Spotify"'* ]] && echo $index && exit
	done < <(pacmd list-sink-inputs)
}

##############################################################################
# Check if Spotify is running and has created a Sink.
# Arguments:
#   Spotify sink index
# Outputs:
#   If unsucessful writes a message to 
#   stdout and exits
##############################################################################
check_spotify_initial_status () {
	spotifysinkindex="$1"
	if [[ -z $spotifysinkindex ]]; then
		echo "********************************************"
		echo "Start playing anything in Spotify and then"
		echo "leave it in pause."
		echo "Then execute this script again, return to"
		echo "Spotify, and start playing again to start"
		echo "recording"
		echo "********************************************"
		echo "Do not close this terminal while recording"
		echo "********************************************"
		debug "ERROR: Spotify sink not found" ; exit 1
	fi
}

##############################################################################
# Check if a null audio output has been created. If its not create it
# Arguments:
#   Null output name
##############################################################################
create_null_audio_output () {
	if [[ -z $(pactl list short | grep "$1".monitor) ]]; then
		nullsinkindex=$(pactl load-module module-null-sink sink_name="$1")
		sleep 1
	fi
}

##############################################################################
# Move the Spotify Sink to the null output Sink
# Arguments:
#   1) Spotify sink index
#	2) Null output name
##############################################################################
move_spotify_output () {
	pactl move-sink-input "$1" "$2"
}

##############################################################################
# Create the proper directory structure and filename for the output file based
# on the option given. Currently there are 3 options:
# "normal" : Create an structure based on Artist / Album / Tittle
# "strict" : Create an structure based on Artist / Album / Tittle removing 
#            all special characters
# "strict-lc-nodir" : Creates no structure. It removes the special characters 
#                     and converts to lower case the filename
# Arguments:
#   1) $filenamescheme variable defined in the configuration secction
#   2) $recordingdir variable recieved as script's first argument (or the 
#      default value)
#   3) Artist name
#   4) Album name
#   5) Song's title
#   6) Extension for the output fimename name according to the format choosen
# Outputs:
#   Output a path and filename for the recorded file
##############################################################################
file_path_structure () {
	case $1 in
		"normal")
			outputdir="$2/${3//[^ A-Za-z0-9._-]/}/${4//[^ A-Za-z0-9._-]/}"
			outputfile="${5//[^ A-Za-z0-9._-]/}.$6"
			[[ ! -d "$outputdir" ]] && mkdir -p "$outputdir"
			echo "$outputdir/$outputfile"
			;;
		"strict")
			sartist=$(sanitize_str "strict" "$3")
			salbum=$(sanitize_str "strict" "$4")
			stitle=$(sanitize_str "strict" "$5")
			outputdir="$2/$sartist/$salbum"
			outputfile="$stitle.$6"
			[[ ! -d "$outputdir" ]] && mkdir -p "$outputdir"
			echo "$outputdir/$outputfile"
			;;
		"strict-lc-nodir")
			sartist=$(sanitize_str "strict-lc" "$3")
			salbum=$(sanitize_str "strict-lc" "$4")
			stitle=$(sanitize_str "strict-lc" "$5")
			outputdir="$2"
			outputfile="$sartist"'_'"$salbum"'_'"$stitle"'.'"$6"
			[[ ! -d "$outputdir" ]] && mkdir -p "$outputdir"
			echo "$outputdir/$outputfile"
			;;
		*) debug "FATAL: filenamescheme  - invalid or nor defined" ; exit 1 ;;
	esac
}

##############################################################################
# Read and filter dbus messages related to Spotify
# Arguments:
#   None
# Outputs:
#   It outpus each value in sequence to be read for the main control loop
##############################################################################
get_dbusmessages () {
	while read string; do
	## Read field header
		if [[ $string == *'string "org.mpris.MediaPlayer2.Player"'* ]]; then echo "_DBUS_MESSAGE_START_"
		elif [[ $string == *'string "mpris:trackid"'* ]]; then settrackid="1" ; continue
		elif [[ $string == *'string "mpris:artUrl"'* ]]; then setartUrl="1" ; continue
		elif [[ $string == *'string "xesam:album"'* ]]; then setalbum="1" ; continue
		elif [[ $string == *'string "xesam:albumArtist"'* ]]; then setalbumArtist="1" ; continue
		elif [[ $string == *'string "xesam:artist"'* ]]; then setartist="1" ; continue
		elif [[ $string == *'string "xesam:title"'* ]]; then settitle="1" ; continue
		elif [[ $string == *'string "xesam:trackNumber"'* ]]; then settrackNumber="1" ; continue
		elif [[ $string == *'string "PlaybackStatus"'* ]]; then setPlaybackStatus="1" ; continue
		fi
	## Print field values
		if [[ -n $settrackid ]]; then
			settrackid="" ; echo $(echo "$string"|cut -d '"' -f2) ; continue
		elif [[ -n $setartUrl ]]; then
			setartUrl="" ;  echo $(echo "$string"|cut -d '"' -f2) ; continue
		elif [[ -n $setalbum ]]; then
			setalbum="" ; echo $(echo "$string"|cut -d '"' -f2) ; continue
		elif [[ -n $setalbumArtist ]]; then
			[[ $string == *'array ['* ]] && continue
			setalbumArtist="" ; echo $(echo "$string"|cut -d '"' -f2) ; continue
		elif [[ -n $setartist ]]; then
			[[ $string == *'array ['* ]] && continue
			setartist="" ; echo $(echo "$string"|cut -d '"' -f2) ; continue
		elif [[ -n $settitle ]]; then
			settitle="" ; echo $(echo "$string"|cut -d '"' -f2) ; continue
		elif [[ -n $settrackNumber ]]; then
			settrackNumber="" ; echo $(echo "$string"|awk '{print substr($3,1)}') ; continue
		elif [[ -n $setPlaybackStatus ]]; then
			setPlaybackStatus="" ; echo $(echo "$string"|cut -d '"' -f2) ; continue
		fi
	done < <(dbus-monitor "path=/org/mpris/MediaPlayer2,member=PropertiesChanged")
}

# Call the necessary functions before starting
spotifysinkindex=$(get_spotifysinkindex)
check_spotify_initial_status "$spotifysinkindex"
create_null_audio_output "$nulloutput_name"
move_spotify_output "$spotifysinkindex" "$nulloutput_name"

# Kill the proces when the script ends. Remove the created Sink
trap "killall fdkaac 2>/dev/null ; killall oggenc 2>/dev/null ; killall parec 2>/dev/null ; pactl unload-module module-null-sink 2>/dev/null" EXIT

# Start reading the activity of spotify
while read dbusmessage; do
	# Read the start flag
	if [[ $dbusmessage == "_DBUS_MESSAGE_START_" ]]; then
		fieldnum=1

	# Read the spotify messages in sequence
	elif [[ -n $dbusmessage ]]; then
		case $fieldnum in
			1)	trackid="$dbusmessage" ; ((fieldnum++)) ;;
			2)	artUrl="$dbusmessage" ; ((fieldnum++)) ;;
			3)	album="$dbusmessage" ; ((fieldnum++)) ;;
			4)	albumArtist="$dbusmessage" ; ((fieldnum++)) ;;
			5)	artist="$dbusmessage" ; ((fieldnum++)) ;;
			6)	title="$dbusmessage" ; ((fieldnum++)) ;;
			7)	trackNumber="$dbusmessage" ; ((fieldnum++)) ;;
			8)	PlaybackStatus="$dbusmessage" ; fieldnum="last" ;;
			9)	debug "FATAL: Unknown dbus field" ; exit 1 ;;
		esac
		
		# Skip when the dbus message is repeated in the same song
		if [[ "$ctrackid" == "$trackid" ]] && [[ "$fieldnum" == "last" ]] && [[ "$PlaybackStatus" == "Playing" ]]; then
			continue
		
		# Detect the pause status. Leave a message and exit the script
		elif [[ "$fieldnum" == "last" ]] && [[ "$PlaybackStatus" == "Paused" ]]; then
			echo "********************************************"
		 	echo "Pause status during recording!"
			echo "It could have finished the recording"
		 	echo "********************************************"
		 	echo "Exiting script"
		 	echo "********************************************"
		 	exit 0
		
		# All previous things, was for this part
		elif [[ "$fieldnum" == "last" ]] && [[ "$PlaybackStatus" == "Playing" ]]; then
			ctrackid=$trackid
			if [[ $recordformat == "aac" ]]; then
				killall fdkaac 2>/dev/null && killall parec 2>/dev/null
				echo "RECORDING: \"$title\" by \"$artist\" in $recordformat"
				outputfile=$(file_path_structure "$filenamescheme" "$recordingdir" "$artist" "$album" "$title" "m4a")

				parec -d "$nulloutput_name".monitor | fdkaac -R -S -p "$aac_profile" --bitrate "$bitrate"k --moov-before-mdat --afterburner 1 \
				--title "$title" --artist "$artist" --album "$album" --album-artist "$albumArtist" --track "$trackNumber" \
				-o "$outputfile" - 2>/dev/null & disown

			elif [[ $recordformat == "ogg" ]]; then
				killall oggenc 2>/dev/null && killall parec 2>/dev/null
				echo "RECORDING: \"$title\" by \"$artist\" in format $recordformat"
				outputfile=$(file_path_structure "$filenamescheme" "$recordingdir" "$artist" "$album" "$title" "oga")

				parec -d "$nulloutput_name".monitor | oggenc -b "$bitrate" --raw \
				--title "$title" --artist "$artist" --album "$album" --tracknum "$trackNumber" \
				-o "$outputfile" - 2>/dev/null & disown

			else
				debug "No configured format. Please set the \$recordformat variable" ; exit 1
			fi
		fi
	else
		debug "Empty dbus message. This should not happen ¯\_(ツ)_/¯" ; exit 1
		exit 1
	fi
done < <(get_dbusmessages)