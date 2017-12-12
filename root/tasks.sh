#!/bin/bash

configure_s3cmd () {

# Configure .s3cfg if it doesn't already exist
if [ ! -f ~/.s3cfg ]
then

	# There doesn't appear to be any way to set the gpg_passphrase variable on the command line, and building the .s3cfg file per
	# https://stackoverflow.com/questions/38622898/configuring-s3cmd-non-interactively-through-bash-script?rq=1#comment64712342_38629201 and then
	# using sed to replace the gpg_passphrase line with one containing our passphrase seems to give a permissions error, so instead
	# we have to fake our way through the interactive configuration process.
	
	echo -e "${S3_ACCESS_KEY}\n${S3_SECRET_KEY}\n\n\n\n${S3_GPG_PASSPHRASE}\n\n\n\nN\nY\n" | s3cmd --configure

fi

}


archive_video () {

	# archive_video takes the original video file (typically an .mkv), encrypts it with
	# our ${S3_ENCRYPTION_KEY}, and uploads it to S3/Glacier for offsite backup

	# Upload the video to S3 (use a lifecycle rule for the ${S3_BUCKET} if you want it to be moved to Glacier storage)
	taskStart=$(date +%s) &&
	s3cmd --force -e put /mnt/storage/Originals"${file_path}" "s3://${S3_BUCKET}${file_path}" &&
	taskEnd=$(date +%s) &&
	
	task_duration=$(( taskEnd - taskStart )) &&
	
	# Update the database to indicate that the file has been archived
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_task (queue_start, file_path, task, task_duration) SELECT FROM_UNIXTIME('${queueStart}'), file_path, task, '${task_duration}' FROM v_queue WHERE file_path = '${escaped_file_path}';" &&
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "UPDATE files SET date_file_archived = CURRENT_TIMESTAMP WHERE file_path = '${escaped_file_path}';"

}


delete_video() {

	# delete_video deletes a file from the host (e.g. after we import a better-quality version,
	# the lower-quality original doesn't need to take up storage on our device)

	# Delete the file from the host
	taskStart=$(date +%s) &&
	rm /mnt/storage/Originals"${file_path}" &&
	
	# Remove the directory tree if it is empty
	rmdir -p --ignore-fail-on-non-empty /mnt/storage/Originals"${dir_path}" &&
	taskEnd=$(date +%s) &&
	
	task_duration=$(( taskEnd - taskStart )) &&
	
	# Update the database to indicate that the file has been deleted
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_task (queue_start, file_path, task, task_duration) SELECT FROM_UNIXTIME('${queueStart}'), file_path, task, '${task_duration}' FROM v_queue WHERE file_path = '${escaped_file_path}';" &&
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "UPDATE files SET date_file_deleted = CURRENT_TIMESTAMP WHERE file_path = '${escaped_file_path}';"

}


restore_video () {

	# If we used a lifecycle rule to migrate videos we've archived to Glacier storage (which we should have!),
	# then we need to first issue a restore request before the file can be downloaded
	# (Note that it will take some time before the file will be ready for download!
	#  This only *requests* that the file be made available for later download.)
	#
	# There's different classes of restore requests based on how fast the file will be restored, with faster options being more expensive
	# See https://aws.amazon.com/glacier/pricing/ for Glacier request pricing
	#
	# We use a "bulk" restore priority as it's the cheapest
	
	# Issue a restore request
	taskStart=$(date +%s) &&
	s3cmd --restore-priority=bulk restore "s3://${S3_BUCKET}${file_path}" &&
	taskEnd=$(date +%s) &&
	
	task_duration=$(( taskEnd - taskStart )) &&
	
	# Update the database to indicate that a restore has been requested
	# A DB trigger will also update the database for when the restore should be available (bulk = 12 hours after restore request)
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_task (queue_start, file_path, task, task_duration) SELECT FROM_UNIXTIME('${queueStart}'), file_path, task, '${task_duration}' FROM v_queue WHERE file_path = '${escaped_file_path}';" &&
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "UPDATE files SET date_restore_requested = CURRENT_TIMESTAMP WHERE file_path = '${escaped_file_path}';"

}


copy_video () {

	rm /mnt/Storage/Plex/"${dir_path}/${plex_name}.*"
	
	mkdir -p /mnt/storage/Plex"${dir_path}" &&
	
	cp /mnt/Storage/Originals"${file_path}" /mnt/Storage/Plex"${file_path}" &&
	
	# Update the database to show that the file has been copied as of now
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_task (queue_start, file_path, task, dir_path, plex_name, series_title, release_identifier, file_duration, quality_title, task_duration) SELECT FROM_UNIXTIME('${queueStart}'), file_path, task, dir_path, plex_name, series_title, release_identifier, file_duration, quality_title, '${task_duration}' FROM v_queue WHERE file_path = '${escaped_file_path}';" &&
	
}


encode_video () {

	# If we don't have a local version of the file, download it from S3
	# (This is for videos that we've archived to S3, deleted from our host, and have already requested to be restored)	
	if [[ ! -f /mnt/storage/Originals"${file_path}" ]]
	then
	
		mkdir -p /mnt/storage/Originals"${dir_path}" &&
		
		s3cmd get "s3://${S3_BUCKET}${file_path}" /mnt/storage/Originals"${file_path}"
	
	fi &&


	# Set a default Handbrake preset if none was specified
	# (Use the DEFAULT_HANDBRAKE_PRESET environment variable if it exists)
	
	if [[ ${handbrake_preset} == "NULL" ]]
	then
		handbrake_preset=${DEFAULT_HANDBRAKE_PRESET:="Apple 1080p60 Surround"}
	fi &&


	# If we're using the x264 encoder, and we have an ${encoder_tune} specified,
	# then tune the encoder for that content (or default to "film" tuning)
	#
	# If we're using another encoder (e.g. x265), don't use any tuning
	
	if [[ ${mpeg_encoder} == "x264" ]]
	then
	
		if [[ ${encoder_tune} == "NULL" ]]
		then
			encoder_tune="--encoder-tune film"
		else
			encoder_tune="--encoder-tune ${encoder_tune}"
		fi
		
	else
		encoder_tune=""
	fi &&
	
	
	# Use the crop value specified if one has been determined for the film
	# (If one hasn't been determined, we fall back to Handbrake's default crop method of 
	#  removing the black bars, according to whether the ${handbrake_preset} crops by default)

	if [[ ${crop} == "NULL" ]]
	then
		crop=""
	else
		crop="--crop ${crop}"
	fi &&


	# Use the decomb setting of EEDI2 Bob (selective + deinterlace + EEDI2 + cubic + blend + yadif) if none has been specified
	# See https://github.com/HandBrake/HandBrake/blob/master/libhb/decomb.h for decomb methods

	if [[ ${decomb} == "NULL" ]]
	then
		decomb="63"
	fi &&


	# Apply a denoise filter if one has been specified
	
	if [[ ${nlmeans} == "NULL" ]] || [[ ${nlmeans_tune} == "NULL" ]]
	then
		denoise=""
	else
		denoise="--nlmeans=${nlmeans} --nlmeans-tune ${nlmeans_tune}"
	fi &&


	# Default to ${NATIVE_LANGUAGE} (English, if not specified) as the native language
	# If other audio languages are provided in ${audio_language}, then subtitles in ${NATIVE_LANGUAGE} will be shown

	if [[ ${audio_language} == "NULL" ]]
	then
		audio_language="--native-language ${NATIVE_LANGUAGE:=eng}"
	else
		audio_language="--audio-lang-list ${audio_language} --native-language ${NATIVE_LANGUAGE:=eng}"
	fi &&
	
	
	# Create a path for the transcoded file to be stored
	mkdir -p /mnt/storage/Plex"${dir_path}" &&

	# Convert the video
	taskStart=$(date +%s) &&
	HandBrakeCLI --preset """${handbrake_preset}""" --encoder ${mpeg_encoder} ${encoder_tune} ${crop} --quality ${quality} --encopts vbv-maxrate=${vbv_maxrate}:vbv-bufsize=${vbv_bufsize}:crf-max=${crf_max}:qpmax=${qpmax} --detelecine --decomb=mode=${decomb} ${denoise} ${audio_language} -i /mnt/storage/Originals"${file_path}" -o /mnt/storage/Plex"${dir_path}/${plex_name}".m4v >> /mnt/storage/"${plex_name}".log &&
	taskEnd=$(date +%s) &&
	
	task_duration=$(( taskEnd - taskStart )) &&
	
	# Update the database to show that the file has been transcoded as of now
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_task (queue_start, file_path, task, dir_path, plex_name, series_title, release_identifier, file_duration, quality_title, handbrake_preset, mpeg_encoder, encoder_tune, crop, quality, vbv_maxrate, vbv_bufsize, crf_max, qpmax, decomb, nlmeans, nlmeans_tune, audio_language, task_duration) SELECT FROM_UNIXTIME('${queueStart}'), file_path, task, dir_path, plex_name, series_title, release_identifier, file_duration, quality_title, handbrake_preset, mpeg_encoder, encoder_tune, crop, quality, vbv_maxrate, vbv_bufsize, crf_max, qpmax, decomb, nlmeans, nlmeans_tune, audio_language, '${task_duration}' FROM v_queue WHERE file_path = '${escaped_file_path}';" &&
	
	if [[ "${task}" == "encode" ]]
	then
		mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "UPDATE presets_titles SET latest_transcode = CURRENT_TIMESTAMP WHERE plex_name = '${escaped_plex_name}';"
	fi &&
	
	# Delete the log file
	rm /mnt/storage/"${plex_name}".log

}


purge_video () {

	# purge_video removes a file and all of its database records

	# Delete the original file
	taskStart=$(date +%s) &&
	rm /mnt/storage/Originals"${file_path}"
	
	# Delete the original file's path
	rmdir -p --ignore-fail-on-non-empty /mnt/storage/Originals"${dir_path}"
	
	# If the transcoded version exists
	if [[ -f /mnt/storage/Plex"${dir_path}/${plex_name}.m4v" ]]
	then
	
		# Delete the transcoded file
		rm /mnt/storage/Plex"${dir_path}/${plex_name}.m4v"
		
		# Delete the transcoded file's path
		rmdir -p --ignore-fail-on-non-empty /mnt/storage/Plex"${dir_path}"
		
	fi
	
	# Delete the archived file from S3 storage
	s3cmd rm "s3://${S3_BUCKET}${file_path}"
	taskEnd=$(date +%s) &&
	
	task_duration=$(( taskEnd - taskStart )) &&
	
	# Remove the file from the database
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_task (queue_start, file_path, task, task_duration) SELECT FROM_UNIXTIME('${queueStart}'), file_path, task, '${task_duration}' FROM v_queue WHERE file_path = '${escaped_file_path}';" &&
	mysql -h ${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}} -P ${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "DELETE FROM files WHERE file_path = '${escaped_file_path}'; DELETE FROM presets_titles WHERE plex_name = '${escaped_plex_name}'; DELETE FROM presets_titles WHERE series_title = '${escaped_series_title}';"

}



# What time did the current queue begin? We need this value to update the history_task table

queueStart=$(tail -n1 /mnt/storage/dropletSpecs.txt | tr -s '\t' | cut -f1)

# Map each column in the .tsv input file to its corresponding field from the database

file_path=${1}
task=${2}
dir_path=${3}
plex_name=${4}
series_title=${5}
release_identifier=${6}
quality_title=${7}
file_duration=${8}
handbrake_preset=${9}
mpeg_encoder=${10}
encoder_tune=${11}
crop=${12}
quality=${13}
vbv_maxrate=${14}
vbv_bufsize=${15}
crf_max=${16}
qpmax=${17}
decomb=${18}
nlmeans=${19}
nlmeans_tune=${20}
audio_language=${21}


# Create escaped versions of each value for if we need to use it in an SQL query

escaped_file_path=$(printf %q "${1}")
escaped_task=$(printf %q "${2}")
escaped_dir_path=$(printf %q "${3}")
escaped_plex_name=$(printf %q "${4}")
escaped_series_title=$(printf %q "${5}")
escaped_release_identifier=$(printf %q "${6}")
escaped_quality_title=$(printf %q "${7}")
escaped_file_duration=$(printf %q "${8}")
escaped_handbrake_preset=$(printf %q "${9}")
escaped_mpeg_encoder=$(printf %q "${10}")
escaped_encoder_tune=$(printf %q "${11}")
escaped_crop=$(printf %q "${12}")
escaped_quality=$(printf %q "${13}")
escaped_vbv_maxrate=$(printf %q "${14}")
escaped_vbv_bufsize=$(printf %q "${15}")
escaped_crf_max=$(printf %q "${16}")
escaped_qpmax=$(printf %q "${17}")
escaped_decomb=$(printf %q "${18}")
escaped_nlmeans=$(printf %q "${19}")
escaped_nlmeans_tune=$(printf %q "${20}")
escaped_audio_language=$(printf %q "${21}")


# Configure s3cmd by building .s3cfg file if it does not already exist
configure_s3cmd


# Call the appropriate function depending on the type of task for this item in queue

if [[ "${task}" == "archive" ]]
then

	archive_video
	
elif [[ "${task}" == "delete" ]]
then

	delete_video
	
elif [[ "${task}" == "restore" ]]
then

	restore_video
	
elif [[ "${task}" == "encode" ]] || [[ "${task}" == "calibration" ]]
then

	encode_video
	
elif [[ "${task}" == "purge" ]]
then

	purge_video
	
else

	exit 1

fi