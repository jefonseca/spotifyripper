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

# Recording dir is the first argument
if [[ -z $1 ]]; then
	recordingdir="."
else
	recordingdir="${1//[^ A-Za-z0-9._-]/}"
fi

# Set the defaults
sink_app_name="${sink_app_name:-spotify}"
aac_profile="${aac_profile:-29}"
bitrate="${bitrate:-48}"
recordformat="${recordformat:-aac}"
filenamescheme="${filenamescheme:-normal}"
nulloutput_name=${nulloutput_name:-spotifyripper}

# If exists, override the default values from a configuration file named spotifyripper.conf
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
	local text_color='\033[0;31m'
	local no_text_color='\033[0m'
	local debugmsg="$1"

	debug="${debug:-false}"
	if [[ "$debug" == "true" || "$debug" == "yes" ]]; then
		if [[ -n $debugmsg ]]; then
            [[ $2 == "padding" ]] && local padding="\n"
			echo -e "$padding DEBUG: ${text_color}$debugmsg${no_text_color}$padding" 1>&2
		fi
	fi
}


##############################################################################
# Print messages to terminal stout
# Outputs:
#   print messages
##############################################################################
msg () {
	local text_color='\033[0;33m'
	local no_text_color='\033[0m'
	local msg="$1"

	echo -e "${text_color}$msg${no_text_color}"
}

##############################################################################
# Check the result of a command execution and print information or exit the script
# Arguments:
#   1) Result
#   2) Spected result
#   3) Success messaje
#   4) Fail message
#   5) Optional flag to exit the script on failure
# Outputs:
#   print messages
##############################################################################
check_result () {
	local execresult="$1"
	local expectedresult="$2"
	local successmsg="$3"
	local failmsg="$4"
	## optional
	local failtype="$5"

	if [[ $execresult == $expectedresult ]]; then
		debug "$successmsg"
	else
		msg "$failmsg"
		if [[ "$failtype" == "fatal" ]]; then
			exit 1
		else
			return 1
		fi
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
		local sanitized=$(echo "$2"|tr -dc '[:alnum:]\n\r')
		echo "$sanitized"
	elif [[ "$1" == "strict-lc" ]]; then
		local sanitized=$(echo "$2"|tr -dc '[:alnum:]\n\r'|tr '[:upper:]' '[:lower:]')
		echo "$sanitized"
	fi
}

##############################################################################
# Read the output of pacmd and search for the sink input for Spotify
# Arguments:
#   Name of the sink that spotify creates
# Outputs:
#   Sink index for Spotify application
##############################################################################
get_spotifysinkindex () {
	local sink_list="$(pacmd list-sink-inputs)"
	debug "get_spotifysinkindex: Trying to get Spotify sink index"
	if [[ $(echo $sink_list|head -n 1|cut -d " " -f1) -gt 0 ]] 2>/dev/null; then
		debug "get_spotifysinkindex: Detected at least one active sink"
		while read listline; do
			[[ $listline == *"index: "* ]] && local sink_index=$(echo $listline|cut -d " " -f2)
			[[ $listline == *"application.name = \"$1\""* ]] && spotify_sink_index="$sink_index" && break
		done < <(echo "$sink_list")

		if [[ -n $spotify_sink_index ]] && [[ $spotify_sink_index -ge 0 ]] 2>/dev/null; then
			debug "get_spotifysinkindex: Detected Spotify sink index: $spotify_sink_index"
		else
			debug "get_spotifysinkindex: Spotify sink not found"
			msg "Start playing something in Spotify and pause the playback to create an audio sink"
			msg "Then execute this script again and start playing again to begin the recording"
			msg "Exiting..."
			exit 1
		fi
	else
		debug "get_spotifysinkindex: No sink detected"
		msg "Start playing something in Spotify and pause the playback to create an audio sink"
		msg "Then execute this script again and start playing something in Spotify"
		msg "Exiting..."
		exit 1
	fi
}

##############################################################################
# Check if a null audio output has been created. If its not create it
# Arguments:
#   The name of the null output
##############################################################################
create_null_audio_output () {
	debug "create_null_audio_output: Trying to create a null audio sink"
	if [[ -z $(pactl list short | grep "$1".monitor) ]]; then
		nullsinkindex=$(pactl load-module module-null-sink sink_name="$1";local result=$?)
		check_result "$?" "0" "create_null_audio_output: Null audio sink \"$1\" created" \
		"FATAL create_null_audio_output: Cannot create null audio sink \"$1\"" "fatal"
	else
		debug "create_null_audio_output: Null audio sink \"$1\" already exists"
	fi
}

##############################################################################
# Move the Spotify Sink to the null output Sink
# Arguments:
#   1) Source sink index
#	2) Destination output name
##############################################################################
move_spotify_output () {
	pactl move-sink-input "$1" "$2"
	check_result "$?" "0" "move_spotify_output: Moved the sink index $1 to $2" \
	"FATAL move_spotify_outpu: cannot move the sink index $1 to $2" "fatal"
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
			local outputdir="$2/${3//[^ A-Za-z0-9._-]/}/${4//[^ A-Za-z0-9._-]/}"
			local outputfile="${5//[^ A-Za-z0-9._-]/}.$6"
			[[ ! -d "$outputdir" ]] && mkdir -p "$outputdir"
			echo "$outputdir/$outputfile"
			;;
		"strict")
			local sartist=$(sanitize_str "strict" "$3")
			local salbum=$(sanitize_str "strict" "$4")
			local stitle=$(sanitize_str "strict" "$5")
			local outputdir="$2/$sartist/$salbum"
			local outputfile="$stitle.$6"
			[[ ! -d "$outputdir" ]] && mkdir -p "$outputdir"
			echo "$outputdir/$outputfile"
			;;
		"strict-lc-nodir")
			local sartist=$(sanitize_str "strict-lc" "$3")
			local salbum=$(sanitize_str "strict-lc" "$4")
			local stitle=$(sanitize_str "strict-lc" "$5")
			local outputdir="$2"
			local outputfile="$sartist"'_'"$salbum"'_'"$stitle"'.'"$6"
			[[ ! -d "$outputdir" ]] && mkdir -p "$outputdir"
			echo "$outputdir/$outputfile"
			;;
		*) msg "FATAL: file_path_structure: invalid or nor defined. Exiting..." ; exit 1 ;;
	esac
}

##############################################################################
# Read and filter dbus messages
# Arguments:
#   dbus-monitor filter
# Outputs:
#   Each value in sequence to be read for the main control loop
##############################################################################
get_dbusmessages () {

##############################################################################
# Parse dbus lines and get the values
# Arguments:
#   1) Type: string or int32
#	2) Filter
#	3) String
# Outputs:
#   Each value in sequence to be read for the main control loop
##############################################################################
    dbus_parse () {
        case $1 in
            string)
                local dbus_message="$(echo "$3"|cut -d '"' -f2)"
                debug "$2: $dbus_message"
                echo $dbus_message
                ;;
            int32)
                local dbus_message="$(echo "$3"|awk '{print substr($3,1)}')"
                debug "$2: $dbus_message"
                echo $dbus_message
                ;;
        esac
    }

	while read string; do
        # debug "Reading dbus string: $string" "padding"
        # Start Reading a dbus message block
        if [[ $string == *'string "org.mpris.MediaPlayer2.Player"'* ]]; then
            local read_sequence="step1" && debug "looking for a start sequence"

        elif [[ $read_sequence ]] && [[ ! $read_dbus_block ]]; then
            case $read_sequence in
                step1)
                    debug "start read sequence step 1"
                    if [[ $string == *'array ['* ]]; then
                        local read_sequence="step2" && debug "step 1 success"
                    else
                        unset read_sequence && debug "exiting metadata sequence"
                    fi
                ;;
                step2)
                    debug "start read sequence step 2"
                    if [[ $string == *'dict entry('* ]]; then
                        local read_sequence="step3" && debug "step 2 success"
                    else
                        unset read_sequence && debug "exit read sequence"
                    fi
                    ;;
                step3)
                    debug "start read sequence step 3"
                    if [[ $string == *'string "PlaybackStatus"'* ]] || [[ $string == *'string "Metadata"'* ]]; then
                        unset read_sequence && debug "step 3 success" && debug "finished start read sequence"
                        local read_dbus_block=true && debug "reading dbus block"
                        echo "___dbus_read_start___" 
                        case $string in
                            *'string "PlaybackStatus"'*)
                                local dbus_value="playbackstatus" && debug "reading playback status"
                                ;;
                            *'string "Metadata"'*)
                                debug "reading metadata"
                                ;;
                        esac
                    else
                        unset read_sequence && debug "exit read sequence"
                    fi
                    ;;
            esac

        elif [[ $read_dbus_block ]]; then
            if [[ $string == 'array [' ]];then
                stop_read_sequence=true && debug "recieved a dbus block finish flag" && continue
            elif [[ $stop_read_sequence ]];then 
                if [[ $string != ']' ]]; then
                    unset stop_read_sequence && debug "continue reading dbus block"
                else
                    echo "___dbus_read_stop___" 
                    unset read_dbus_block && unset stop_read_sequence && debug "dbus block read finished"
                    continue
                fi
            fi

            if [[ $dbus_value == "playbackstatus" ]]; then
                local playbackstatus="$(dbus_parse "string" "PlaybackStatus" "$string")"
                echo "playbackstatus -> $playbackstatus" && unset dbus_value && unset playbackstatus
            else 
                case $dbus_value in
                    trackid)
                        local trackid="$(dbus_parse "string" "mpris:trackid" "$string")" && echo "trackid -> $trackid"
                        unset dbus_value && unset trackid
                        ;;
                    arturl)
                        local arturl="$(dbus_parse "string" "mpris:artUrl" "$string")" && echo "arturl -> $arturl"
                        unset dbus_value && unset arturl
                        ;;
                    album)
                        local album="$(dbus_parse "string" "xesam:album" "$string")" && echo "album -> $album"
                        unset dbus_value && unset album
                        ;;
                    albumartist)
                        [[ $string == *'array ['* ]] && continue 
                        [[ $string == *']'* ]] && unset dbus_value && unset albumartist && continue
                        [[ -n "$albumartist" ]] && local albumartist="$albumartist \\\\ $(dbus_parse "string" "xesam:albumArtist" "$string")" && continue
                        local albumartist="$(dbus_parse "string" "xesam:albumArtist" "$string")" && echo "albumartist -> $albumartist"
                        unset dbus_value && unset albumartist
                        ;;
                    artist)
                        [[ $string == *'array ['* ]] && continue 
                        [[ $string == *']'* ]] && unset dbus_value && unset artist && continue
                        [[ -n "$artist" ]] && local artist="$artist \\\\ $(dbus_parse "string" "xesam:artist" "$string")" && continue
                        local artist="$(dbus_parse "string" "xesam:artist" "$string")" && echo "artist -> $artist"
                        unset dbus_value && unset artist
                        ;;
                    discnumber)
                        local discnumber="$(dbus_parse "int32" "xesam:discNumber" "$string")" && echo "discnumber -> $discnumber"
                        unset dbus_value && unset discnumber
                        ;;
                    title)
                        local title="$(dbus_parse "string" "xesam:title" "$string")" && echo "title -> $title"
                        unset dbus_value && unset title
                        ;;
                	tracknumber)
                    	local tracknumber="$(dbus_parse "int32" "xesam:trackNumber" "$string")" && echo "tracknumber -> $tracknumber"
                        unset dbus_value && unset tracknumber
                        ;;
                    *)  case $string in
                            *'string "mpris:trackid"'*)
                                local dbus_value="trackid"
                                ;;
                            *'string "mpris:artUrl"'*)
                                local dbus_value="arturl"
                                ;;
                            *'string "xesam:album"'*)
                                local dbus_value="album"
                                ;;
                            *'string "xesam:albumArtist"'*)
                                local dbus_value="albumartist"
                                ;;
                            *'string "xesam:artist"'*)
                                local dbus_value="artist"
                                ;;
                            *'string "xesam:discNumber"'*)
                                local dbus_value="discnumber"
                                ;;
                            *'string "xesam:title"'*)
                                local dbus_value="title"
                                ;;
                            *'string "xesam:trackNumber"'*)
                                local dbus_value="tracknumber"
                                ;; 
                        esac
                        ;;
                esac
            fi
        elif [[ $read_sequence ]] || [[ $read_dbus_block ]] || [[ $dbus_value ]]; then
            unset read_sequence && unset read_dbus_block && unset dbus_value && debug "cleaning up..."
        fi

	done < <(dbus-monitor "$1")
}

# Get Spotify sink index
get_spotifysinkindex "$sink_app_name"
create_null_audio_output "$nulloutput_name"
move_spotify_output "$spotify_sink_index" "$nulloutput_name"

# Kill the proces when the script ends. Remove the created sink
trap 'echo "" ; msg "Killing all and unloading the null audio sink" ; killall fdkaac 2>/dev/null ; killall oggenc 2>/dev/null ; killall parec 2>/dev/null ; pactl unload-module module-null-sink 2>/dev/null' EXIT

# Start reading the activity of spotify
while read dbus_read; do
	# Read the start flag
	if [[ $dbus_read == "___dbus_read_start___" ]]; then
		debug "recieve a start message"
		dbus_messages_start=true
		continue
	elif [[ $dbus_read == "___dbus_read_stop___" ]]; then
		debug "recieve a stop message"
		if [[ $media_record ]]; then
			msg "************* Metadata *************"
			msg "Title: $title"
			msg "Artist: $artist"
			msg "Album: $album"
			msg "Album artist: $albumartist"
			msg "Track number: $tracknumber"
			msg "Disc number: $discnumber"
			msg "************* Metadata *************"
			case $recordformat in
				aac)
					killall fdkaac 2>/dev/null ; killall parec 2>/dev/null
					outputfile=$(file_path_structure "$filenamescheme" "$recordingdir" "$artist" "$album" "$title" "m4a")
					msg "RECORDING: \"$title\" by \"$artist\" in $recordformat"
					msg "RECORDING TO: $outputfile"
					parec -d "$nulloutput_name".monitor | fdkaac -R -S -p "$aac_profile" --bitrate "$bitrate"k --moov-before-mdat --afterburner 1 \
					--title "$title" --artist "$artist" --album "$album" --album-artist "$albumartist" --track "$tracknumber" --disk "$discnumber" \
					- -o "$outputfile" 2>/dev/null & disown
				;;
				ogg)
					killall oggenc 2>/dev/null ; killall parec 2>/dev/null
					outputfile=$(file_path_structure "$filenamescheme" "$recordingdir" "$artist" "$album" "$title" "oga")
					msg "RECORDING: \"$title\" by \"$artist\" in format $recordformat"
					msg "RECORDING TO: $outputfile"
					parec -d "$nulloutput_name".monitor | oggenc -b "$bitrate" --raw \
					--title "$title" --artist "$artist" --album "$album" --tracknum "$tracknumber" \
					- -o "$outputfile" 2>/dev/null & disown
				;;
				*)
					debug "No configured format. Please set the \$recordformat variable" ; exit 1
				;;
			esac
		fi
		unset dbus_messages_start && unset media_record
		continue
	elif [[ $dbus_read == *'playbackstatus -> '* ]]; then
		playbackstatus="${dbus_read#playbackstatus -> }"
		if [[ $playbackstatus != "Playing" ]]; then
			debug "playback status is not Playing. exiting..."
			msg "Change on playback status. Stoping everithing... ¯\_(ツ)_/¯"
			exit 0
		fi
		continue
	elif [[ $dbus_messages_start ]]; then
		debug "setting media metadata"
		media_record=true
		case $dbus_read in
			'title -> '*)
				title="${dbus_read#title -> }"
				continue ;;
			'artist -> '*)
				artist="${dbus_read#artist -> }"
				continue ;;
			'album -> '*)
				album="${dbus_read#album -> }"
				continue ;;
			'albumartist -> '*)
				albumartist="${dbus_read#albumartist -> }"
				continue ;;
			'tracknumber -> '*)
				tracknumber="${dbus_read#tracknumber -> }"
				continue ;;
			'discnumber -> '*)
				discnumber="${dbus_read#discnumber -> }"
				continue ;;
		esac
	fi
done < <(get_dbusmessages "path=/org/mpris/MediaPlayer2,member=PropertiesChanged")
