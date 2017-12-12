#!/bin/bash

INPUT="${1}"
ORIGINALFILELOCATION=$(dirname "${INPUT}")
ORIGINALFILENAME=$(basename "${INPUT}")

EXTENSION="${ORIGINALFILENAME##*.}"
FILENAME="${ORIGINALFILENAME%.*}"

PROCESSINGDIR="/processing"
OUTPUTDIR="/localized"


# Configure the Postfix mail installation if it hasn't yet already been configured
if [ ! -f /recipient.txt ]
then

	# This configuration allows us to send mail using the G Suite SMTP relay
	# https://support.google.com/a/answer/176600?hl=en
	#
	# **********
	# Be sure to either whitelist your IP address or provide a username/password as environment variables!
	# https://support.google.com/a/answer/2956491?hl=en
	# **********
	
	echo ${EMAIL_HOSTNAME} > /etc/mailname &&
	/usr/sbin/postconf -e myhostname=${EMAIL_HOSTNAME} &&
	/usr/sbin/postconf -e mydestination="localhost.localdomain, localhost" &&
	/usr/sbin/postconf -e inet_interfaces=loopback-only &&
	/usr/sbin/postconf -e inet_protocols=ipv4 &&
	/usr/sbin/postconf -e relayhost=[smtp-relay.gmail.com]:587 &&
	/usr/sbin/postconf -e smtp_always_send_ehlo=yes &&
	/usr/sbin/postconf -e smtp_helo_name=${EMAIL_HOSTNAME} &&
	/usr/sbin/postconf -e smtp_use_tls=yes &&
	/usr/sbin/postconf -e smtp_tls_CAfile=/etc/ssl/certs/ssl-cert-snakeoil.pem &&
	
	# Only enable SMTP authentication if a username / password have been defined
	if [ ! -z "${EMAIL_USERNAME}" ] && [ ! -z "${EMAIL_PASSWORD}" ]
	then
		
		echo "[smtp-relay.gmail.com]:587 ${EMAIL_USERNAME}:${EMAIL_PASSWORD}" > /etc/postfix/sasl/sasl_passwd &&
		/usr/sbin/postmap /etc/postfix/sasl/sasl_passwd &&
		chmod 0600 /etc/postfix/sasl/sasl_passwd* &&
	
		/usr/sbin/postconf -e smtp_sasl_auth_enable=yes &&
		/usr/sbin/postconf -e smtp_sasl_password_maps=hash:/etc/postfix/sasl/sasl_passwd &&
		/usr/sbin/postconf -e smtp_sasl_security_options=noanonymous
		
	fi &&
	
	# Rather than passing the To: and From: lines separately for each email,
	# we define those lines once in recipient.txt and pass that file to sendmail
	echo "To: ${EMAIL_RECIPIENT}" > /recipient.txt &&
	echo "From: Fitzflix <fitzflix@${EMAIL_HOSTNAME}>" >> /recipient.txt &&

	# Restart Postfix
	/usr/sbin/service rsyslog restart &&
	/usr/sbin/service postfix restart
	
fi

# Check to see if the filename matches either "Movie Title (YYYY) - Release [Quality].ext" or "TV Series S00E00 - Description [Quality].ext"
# If it doesn't, then the script exits, so we only operate on files with properly-formatted filenames

if [[ $(perl -e 'if ($ARGV[0] =~ m#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)# ) { print 0 } else { print 1 };' -- "${ORIGINALFILENAME}") -ne 0 ]] && [[ $(perl -e 'if ($ARGV[0] =~ m#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)# ) { print 0 } else { print 1 };' -- "${ORIGINALFILENAME}") -ne 0 ]]
then
	
	echo "The file name ${ORIGINALFILENAME} is formatted incorrectly!" && exit
	
fi


# Start copying the incoming file to the processing directory

if [[ -f "${INPUT}" ]] && [[ ! -f "${PROCESSINGDIR}/${ORIGINALFILENAME}" ]]
then

	echo "Now moving ${ORIGINALFILENAME} to ${PROCESSINGDIR}/${ORIGINALFILENAME}..." &&	
	mv "${INPUT}" "${PROCESSINGDIR}/${ORIGINALFILENAME}"


# If the file is not in the source directory, but is in the processing folder,
# then it's currently being processed, so we exit the script

elif [[ ! -f "${INPUT}" ]] && [[ -f "${PROCESSINGDIR}/${ORIGINALFILENAME}" ]]
then

	echo "${ORIGINALFILENAME} is already being processed." && exit


# If the file is in neither location, it's already been processed
	
elif [[ ! -f "${INPUT}" ]] && [[ ! -f "${PROCESSINGDIR}/${ORIGINALFILENAME}" ]]
then

	echo "${ORIGINALFILENAME} has already been converted!" && exit
	
fi


# If the file is in both places, then it's still being copied, so we exit
# (in case we run this script so frequently that we could end up trying to ingest a file already being processed)

while [[ -f "${INPUT}" ]] && [[ -f "${PROCESSINGDIR}/${ORIGINALFILENAME}" ]]
do

	echo "${INPUT} is currently being copied..." && exit
	
done


# File has been copied and is now ready
echo "${ORIGINALFILENAME} is ready for conversion!"


# Change the location of the file to process from the input folder to the processing folder
INPUT="${PROCESSINGDIR}/${ORIGINALFILENAME}"


# We performe different actions on a file based on the file extension:
#   - MKV: remove non-native-language tracks, enable subtitle tracks if non-native audio, clear the file's title
#   - M4V: run through AtomicParsley to remove all metadata from the file
#   - Others: no changes

if [[ "${EXTENSION}" == "mkv" ]]; then

	numInputAudioTracks=0
	numInputSubTracks=0
	
	inputAudioLangs=""
	inputSubLangs=""
	
	outputAudioLangs=""
	outputSubLangs=""
	

	# Count the number of, and get languages of, various tracks in the file

	numInputAudioTracks=$(mplayer -vo null -ao null -frames 0 "$INPUT" 2>&1 | grep "stream.*audio.*alang" | wc -l) &&
	
	if [ "$numInputAudioTracks" -ge 1 ]; then
	
		inputAudioLangs=$(mplayer -vo null -ao null -frames 0 "$INPUT" 2>&1 | grep -oP "(?<=-alang )[^ ,]+" | tr '\n' ' ')
		
		echo "${numInputAudioTracks} audio tracks: ${inputAudioLangs}"

	fi

	numInputSubTracks=$(mplayer -vo null -ao null -frames 0 "$INPUT" 2>&1 | grep "stream.*subtitle.*slang" | wc -l)
	
	if [ "$numInputSubTracks" -ge 1 ]; then
	
    	inputSubLangs=$(mplayer -vo null -ao null -frames 0 "$INPUT" 2>&1 | grep -oP "(?<=-slang )[^ ,]+" | tr '\n' ' ')
    	
		echo "${numInputSubTracks} subtitle tracks: ${inputAudioLangs}"

	fi


	# Determine which audio tracks to export
	
	# If first audio track is in our native language, export only native-language audio
	# (I don't think I need every language track, so to save some space this removes non-native language audio tracks if it's already in my native language)
	if [[ "$inputAudioLangs" == "${NATIVE_LANGUAGE:=eng}"* ]]; then
		outputAudioLangs="${NATIVE_LANGUAGE:=eng}"
		
	# If the first audio track isn't our native language, but our language is present, export the first audio track language + native-language audio
	# (The first track isn't my native language, but my native language is present - it's probably a commentary track, etc. Remove all but the first audio track + my native language audio)
	elif [[ "$inputAudioLangs" == *"${NATIVE_LANGUAGE:=eng}"* ]]; then
		outputAudioLangs=$(mplayer -vo null -ao null -frames 0 "$INPUT" 2>&1 | grep -oP -m1 "(?<=-alang )[^ ,]+")
		outputAudioLangs="${outputAudioLangs},${NATIVE_LANGUAGE:=eng}"
		
	# If no native-language track present, export only the first audio track language
	# (There doesn't appear to be any audio in my native language, it's probably a subtitled movie with no commentary track, so keep only the first audio language)
	else
		outputAudioLangs=$(mplayer -vo null -ao null -frames 0 "$INPUT" 2>&1 | grep -oP -m1 "(?<=-alang )[^ ,]+")
		outputAudioLangs="${outputAudioLangs}"
	fi
	
	
	# Determine which subtitle tracks to export
	
	# Non-native audio, native-language subtitles present
	if [[ "$inputAudioLangs" != "${NATIVE_LANGUAGE:=eng}"* ]] && [[ "$inputSubLangs" == *"${NATIVE_LANGUAGE:=eng}"* ]]; then
	
		echo "Non-native audio, native-language subtitles (${NATIVE_LANGUAGE:=eng}) present" &&
	
		mkvmerge -o "${OUTPUTDIR}/${FILENAME}.mkv" -a $outputAudioLangs -s ${NATIVE_LANGUAGE:=eng} --title '' "$INPUT" && rm "${INPUT}"
		
		echo "Setting first audio track and first subtitle track as default tracks..." &&
		
		mkvpropedit "${OUTPUTDIR}/${FILENAME}.mkv" --edit track:a1 --set flag-default=1 --edit track:s1 --set flag-default=1


	# Native-language audio, native-language subtitles present
	elif [[ "$inputSubLangs" == *"${NATIVE_LANGUAGE:=eng}"* ]]; then
	
		echo "Native-language audio (${NATIVE_LANGUAGE:=eng}), native-language subtitles (${NATIVE_LANGUAGE:=eng}) present" &&
	
		mkvmerge -o "${OUTPUTDIR}/${FILENAME}.mkv" -a $outputAudioLangs -s ${NATIVE_LANGUAGE:=eng} --title '' "${INPUT}" && rm "${INPUT}"


	# No native-language subtitles
	elif [ $numInputSubTracks -ge 1 ]; then
	
		echo "No native-language/(${NATIVE_LANGUAGE:=eng}) subtitles" &&

		mkvmerge -o "${OUTPUTDIR}/${FILENAME}.mkv" -a $outputAudioLangs --no-subtitles --title '' "${INPUT}" && rm "${INPUT}"


	# No subtitles whatsover
	else
		echo "No subtitles whatsoever" &&
		
		mkvmerge -o "${OUTPUTDIR}/${FILENAME}.mkv" -a ${NATIVE_LANGUAGE:=eng} --no-subtitles --title '' "${INPUT}" && rm "${INPUT}"

	fi


	
elif [[ "${EXTENSION}" == "m4v" ]] || [[ "${EXTENSION}" == "mp4" ]]; then

	echo "Removing MPEG-4 metadata..." &&
	AtomicParsley "${INPUT}" --metaEnema --overWrite &&
	mv "${INPUT}" "${OUTPUTDIR}/"
	
else

	echo "Format isn't MKV or MPEG-4, moving to the output directory ${OUTPUTDIR}..." &&
	mv "${INPUT}" "${OUTPUTDIR}/"
	
fi


# I used to blindly trust HandBrake's crop methods, but https://github.com/donmelton/video_transcoding
# has shown me how frequently it can get the crop values wrong. We'll try to determine a crop value for
# a file if we can, but if HandBrake and ffmpeg differ, then we have to review and assign a crop value
# manually. Here, we can provide a .txt file named the same as the video file, containing only a colon-separated crop value
# (e.g. 100:100:0:0 to remove the top and bottom 100 pixels from a video)

# If a .txt crop sidecar file exists, use the crop value in the file.
# Otherwise we'll attempt to determine a crop value for the file using Don Melton's scripts.
# This way we can use a script to run detect-crop --values-only on our files and if it succeeds it'll export the crop to an appropriate file

if [[ -f "${ORIGINALFILELOCATION}/${FILENAME}.txt" ]]
then

	crop=$(cat "${ORIGINALFILELOCATION}/${FILENAME}.txt") &&
	crop="'${crop}'" &&
	rm "${ORIGINALFILELOCATION}/${FILENAME}.txt"
	
else

	# Calculate source file's crop value
	# (if null, then handbrake and ffmpeg differ in crop values, and need manual checking)
	crop=$(detect-crop --values-only "${OUTPUTDIR}/${ORIGINALFILENAME}" || echo) &&

	if [[ -z ${crop} ]]
	then

		echo "Couldn't determine a crop value!" &&
		crop="NULL"
	
	else
	
		crop="'${crop}'"
	
	fi
	
fi &&


# Calculate source file's video/general bitrate to use as destination bitrate
videoBitrate=$(mediainfo --Output="Video;%BitRate%" "${OUTPUTDIR}/${ORIGINALFILENAME}") &&
generalBitrate=$(mediainfo --Output="General;%BitRate%" "${OUTPUTDIR}/${ORIGINALFILENAME}")

if [[ ! -z ${videoBitrate} ]]
then

	vbv_maxrate=$(( $videoBitrate / 1000 )) &&
	vbv_maxrate="'${vbv_maxrate}'"
	
elif [[ ! -z ${generalBitrate} ]]
then

	vbv_maxrate=$(( $generalBitrate / 1000 )) &&
	vbv_maxrate="'${vbv_maxrate}'"
	
else
	
	echo "Couldn't determine a bitrate!" &&
	vbv_maxrate="NULL"
	
fi


# Calculate source file's duration in seconds
# (I'm curious how well each droplet type can encode files, so capturing this as a data point)
file_duration=$(mediainfo --Inform="General;%Duration%" "${OUTPUTDIR}/${ORIGINALFILENAME}")

if [[ ! -z ${file_duration} ]]
then

	file_duration=$(( $file_duration / 1000 )) &&
	file_duration="'${file_duration}'"
	
else

	file_duration="NULL"
	
fi


	


# Find out if it's a movie or a tv show

# Try to match the movie regex
if [[ $(perl -e 'if ($ARGV[0] =~ m#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)# ) { print 0 } else { print 1 };' -- "${ORIGINALFILENAME}") -eq 0 ]]
then

	# Create the movie-relevant column values
	
	movie_title=$(echo "${ORIGINALFILENAME}" | perl -pe        's#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)#\1#')
	release_year=$(echo "${ORIGINALFILENAME}" | perl -pe       's#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)#\2#')
	release_identifier=$(echo "${ORIGINALFILENAME}" | perl -pe 's#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)#\3#')
	quality_title=$(echo "${ORIGINALFILENAME}" | perl -pe      's#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)#\4#')
	extension=$(echo "${ORIGINALFILENAME}" | perl -pe          's#(.+) \((\d{4})\) \-(?: (.+) | )\[(.+)\]\.(.+)#\5#')
	
	dir_path="/Movies/${movie_title} (${release_year})"
	
	
	# Construct the file name based on whether or not there was a release identifier value
	
	if [[ -z "${release_identifier// }" ]]
	then
		
		base_name="${movie_title} (${release_year}) - [${quality_title}].${extension}"
		file_path="${dir_path}/${base_name}"
		plex_name="${movie_title} (${release_year})"
		escaped_release_identifier="NULL"
		
	else
	
		base_name="${movie_title} (${release_year}) - ${release_identifier} [${quality_title}].${extension}"
		file_path="${dir_path}/${base_name}"
		plex_name="${movie_title} (${release_year}) - ${release_identifier}"
		escaped_release_identifier="'`printf \"%q\" ${release_identifier}`'"
		
	fi
	
	escaped_plex_name=$(printf %q "${plex_name}")
	escaped_movie_title=$(printf %q "${movie_title}")
	escaped_release_year=$(printf %q "${release_year}")
	escaped_file_path=$(printf %q "${file_path}")
	escaped_dir_path=$(printf %q "${dir_path}")
	escaped_base_name=$(printf %q "${base_name}")
	escaped_quality_title=$(printf %q "${quality_title}")
	
	# Move the file to its destination
	mkdir -p "/Originals${dir_path}" &&
	mv "${OUTPUTDIR}/${ORIGINALFILENAME}" "/Originals${file_path}" &&
	
	# Add the file to the database
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO presets_titles (plex_name, movie_title, release_year, release_identifier) VALUES ('${escaped_plex_name}', '${escaped_movie_title}', '${escaped_release_year}', ${escaped_release_identifier});"
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO files (file_path, dir_path, base_name, plex_name, quality_title, crop, vbv_maxrate, file_duration) VALUES ('${escaped_file_path}', '${escaped_dir_path}', '${escaped_base_name}', '${escaped_plex_name}', '${escaped_quality_title}', ${crop}, ${vbv_maxrate}, ${file_duration});"
	
	cat /recipient.txt <(echo "Subject: Fitzflix Import") <(echo "${file_path}") | /usr/sbin/sendmail -t
	

# Try to match the TV show regex
elif [[ $(perl -e 'if ($ARGV[0] =~ m#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)# ) { print 0 } else { print 1 };' -- "${ORIGINALFILENAME}") -eq 0 ]]
then

	# Create the TV-relevant column values
	
	series_title=$(echo "${ORIGINALFILENAME}" | perl -pe       's#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)#\1#')
	season_number=$(echo "${ORIGINALFILENAME}" | perl -pe      's#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)#\2#')
	episode_number=$(echo "${ORIGINALFILENAME}" | perl -pe     's#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)#\3#')
	release_identifier=$(echo "${ORIGINALFILENAME}" | perl -pe 's#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)#\4#')
	quality_title=$(echo "${ORIGINALFILENAME}" | perl -pe      's#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)#\5#')
	extension=$(echo "${ORIGINALFILENAME}" | perl -pe          's#(.+) \- S(\d+)E(\d+) \-(?: (.+) | )\[(.+)\]\.(.+)#\6#')
	
	
	# TV season "0" files go into a "Specials" directory
	if [[ ${season_number} -eq 0 ]]
	then
	
		dir_path="/TV Shows/${series_title}/Specials"
		
	else
	
		dir_path="/TV Shows/${series_title}/Season `printf \"%02d\" ${season_number}`"
		
	fi
	
	
	# Construct the file name based on whether or not there was a release identifier value
	
	if [[ -z "${release_identifier// }" ]]
	then
		
		base_name="${series_title} - S`printf \"%02d\" ${season_number#0}`E`printf \"%02d\" ${episode_number#0}` - [${quality_title}].${extension}"
		file_path="${dir_path}/${base_name}"
		plex_name="${series_title} - S`printf \"%02d\" ${season_number#0}`E`printf \"%02d\" ${episode_number#0}`"
		escaped_release_identifier="NULL"
		
	else
	
		base_name="${series_title} - S`printf \"%02d\" ${season_number#0}`E`printf \"%02d\" ${episode_number#0}` - ${release_identifier} [${quality_title}].${extension}"
		file_path="${dir_path}/${base_name}"
		plex_name="${series_title} - S`printf \"%02d\" ${season_number#0}`E`printf \"%02d\" ${episode_number#0}` - ${release_identifier}"
		escaped_release_identifier="'`printf \"%q\" ${release_identifier}`'"
		
	fi
	
	escaped_series_title=$(printf %q "${series_title}")
	escaped_plex_name=$(printf %q "${plex_name}")
	escaped_season_number=$(printf %q "${season_number}")
	escaped_episode_number=$(printf %q "${episode_number}")
	escaped_file_path=$(printf %q "${file_path}")
	escaped_dir_path=$(printf %q "${dir_path}")
	escaped_base_name=$(printf %q "${base_name}")
	escaped_quality_title=$(printf %q "${quality_title}")
	
	# Move the file to its destination
	mkdir -p "/Originals${dir_path}" &&
	mv "${OUTPUTDIR}/${ORIGINALFILENAME}" "/Originals${file_path}" &&
	
	# Add the file to the database
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO presets_series (series_title) VALUES ('${escaped_series_title}');"
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO presets_titles (plex_name, series_title, season_number, episode_number, release_identifier) VALUES ('${escaped_plex_name}', '${escaped_series_title}', '${escaped_season_number}', '${escaped_episode_number}', ${escaped_release_identifier});"
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO files (file_path, dir_path, base_name, plex_name, quality_title, crop, vbv_maxrate, file_duration) VALUES ('${escaped_file_path}', '${escaped_dir_path}', '${escaped_base_name}', '${escaped_plex_name}', '${escaped_quality_title}', ${crop}, ${vbv_maxrate}, ${file_duration});"

	cat /recipient.txt <(echo "Subject: Fitzflix Import") <(echo "${file_path}") | /usr/sbin/sendmail -t
	
else
	
	echo "The file name ${ORIGINALFILENAME} is formatted incorrectly!"

fi