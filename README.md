# Fitzflix

A Docker-based video library manager, one of original-quality files and another of transcoded versions for [Plex](https://www.plex.tv/).

## Background

While Plex can transcode video files on the fly based on the client's capabilities, meaning that typically only one video library is necessary, Fitzflix was designed to maintain two video libraries in parallel: one library of original-quality video files, and a second of files for Plex to use that have been pre-transcoded.

By keeping the original-quality files available, they can be re-encoded in the future as encoder capabilities improve (e.g. encoding originally using H.264, then later as H.265 HEVC when devices are more fully capable of playing that format).

By pre-transcoding the video files, they can be served from a lower-processor device (e.g NAS hardware) that cannot handle on-the-fly transcoding. Pre-transcoding is handled by DigitalOcean droplets so many videos can be transcoded in parallel.

By maintaining a database of the videos in our library, we can keep track of what titles we have in what formats. A web-based portal for viewing the library / editing settings is currently out of scope for this repository.


## Features

  - Removes unnecessary audio / subtitle languages from video files
  - Uses standard Plex [movie](https://support.plex.tv/hc/en-us/articles/200381023-Naming-Movie-files) and [TV](https://support.plex.tv/hc/en-us/articles/200220687-Naming-Series-Season-Based-TV-Shows) naming conventions
  - Uses [Don Melton's transcoding scripts](https://github.com/donmelton/video_transcoding) as a basis for cropping and transcoding
  - Uses [GNU Parallel](https://www.gnu.org/software/parallel/) to process multiple tasks simultaneously
  - Sends emails when tasks begin, as tasks are processed, and when tasks are complete, and estimates cost
  - Archives original files in Amazon S3, and encrypts files with GPG
  - Deletes local files that have been replaced with better-quality versions


## Setup

### Volumes

Assign folders for these mount paths:

  - `/Imports`
  - `/Originals`
  - `/Plex`
  - `/root/.ssh/` (optional; will use SSH keys in this directory)

### Environment Variables

Define the environment variables:

  - `TZ` Timezone
  - `PUID` UID - log in to container and run `id` to find
  - `PGID` GID - log in to container and run `id` to find
  

  - `DEFAULT_HANDBRAKE_PRESET` HandBrake preset to use if no handbrake_preset is specified (optional; default: Apple 1080p60 Surround)


  - `DO_API_KEY` API key for accessing DigitalOcean
  - `DO_MAX_DROPLETS` Maximum number of droplets to run at once (optional; default: 5)
  - `DO_MIN_CPU` Minimum number of CPUs to allocate per task (optional; default: 1)
  - `DO_MIN_RAM` Minimum gigabytes of RAM to allocate per task (optional; default: 1)
  - `DO_REGION` DigitalOcean region for droplet creation (optional; default: nyc3)


  - `EMAIL_HOSTNAME` G Suite domain name (e.g. example.com)
  - `EMAIL_PASSWORD` G Suite Gmail password
  - `EMAIL_RECIPIENT` Recipient address for status emails (e.g. user@example.com)
  - `EMAIL_USERNAME` G Suite Gmail account username (e.g. user@example.com)


  - `MYSQL_DB` Database name (optional; default: fitzflix_db)
  - `MYSQL_HOST` Database hostname
  - `MYSQL_PASSWORD` Database password
  - `MYSQL_PORT` Database port number (optional; default: 3306)
  - `MYSQL_USER` Database user name


  - `NATIVE_LANGUAGE` ISO 639-2 language code, used to remove non-native languages / enable subtitles (optional; default: eng)


  - `S3_ACCESS_KEY` S3 access key
  - `S3_BUCKET` S3 bucket
  - `S3_GPG_PASSPHRASE` Passphrase for encrypting uploaded files
  - `S3_SECRET_KEY` S3 secret key

## Usage

### Import

Add video files to be imported into the `/Imports` directory.

Movie naming format: **Movie Title (Year) - Optional Release Info [Quality].ext**

  - `Movie Title (2017) - [Bluray-1080p].mkv`
  - `Movie Title (2017) - Director's Cut [DVD].mkv`

TV Show naming format: **TV Show Title - SseasonEepisode - Optional Release Info [Quality].ext**

  - `TV Show Title - S01E01 - [Bluray-1080p].mkv`
  - `TV Show Title - S01E01 - Extended Version [DVD].mkv`
  
"Quality" must be one of the following:

  - Bluray-720p
  - Bluray-1080p
  - Bluray-2160p
  - DVD
  - HDTV-720p
  - HDTV-1080p
  - HDTV-2160p
  - Raw-HD
  - SDTV
  - Unknown
  - WEBDL-480p
  - WEBDL-720p
  - WEBDL-1080p
  - WEBDL-2160p
  
Quality preference order can be modified in the `ref_source_quality` table; if a title with a higher quality preference is added, lower-quality files that have already been archived will be marked for deletion.

The **Import.sh** script will run once every minute; modify its frequency in `/etc/cron.d/fitzflix-cron`. It will perform different operations on the file based on its file extension:

  - mkv
	  - If the first audio track is `${NATIVE_LANGUAGE}`, keep only `${NATIVE_LANGUAGE}` audio and remove all others
      - If the first audio track isn't `${NATIVE_LANGUAGE}`, but `${NATIVE_LANGUAGE}` audio is present, keep the first audio track language + `${NATIVE_LANGUAGE}` and remove all others, and enable `${NATIVE_LANGUAGE}` subtitles
      - If `${NATIVE_LANGUAGE}` audio isn't present, keep only the first audio track language and enable `${NATIVE_LANGUAGE}` subtitles
    
  - m4v / mp4
    - Run the file through [atomicparsley](http://atomicparsley.sourceforge.net/), removing all metadata
    
  - all others
    - No modifications
    
The file will then be passed to [detect-crop](https://github.com/donmelton/video_transcoding) to determine the crop values. If HandBrake and ffmpeg agree, the crop value will be saved, otherwise the crop value will be null and cropping behavior is determined by the preset stored in `DEFAULT_HANDBRAKE_PRESET`. The crop value can be saved in an associated sidecar file (e.g., if the file is `Movie Title (Year) - Optional Release Info [Quality].ext`, the sidecar should be `Movie Title (Year) - Optional Release Info [Quality].txt`) that contains only the crop value to be applied (e.g. `100:100:0:0` to remove the top and bottom 100 pixels from a video).

Files will be saved in `/Originals/Movies` or `/Originals/TV Shows`:


  - `/Originals/Movies/Movie Title (2017)/Movie Title (2017) - [Bluray-1080p].mkv`
  - `/Originals/Movies/Movie Title (2017)/Movie Title (2017) - Director's Cut [Bluray-1080p].mkv`
    
    
  - `/Originals/TV Shows/TV Show Title/Season 01/TV Show Title - S01E01 - [DVD].mkv`
  - `/Originals/TV Shows/TV Show Title/Season 01/TV Show Title - S01E01 - Extended Version [DVD].mkv`
  - `/Originals/TV Shows/TV Show Title/Specials/TV Show Title - S00E01 - [DVD].mkv`
  
### Archive

Files with the "archive" task will be uploaded to a DigitalOcean droplet, encrypted with the `${S3_GPG_PASSPHRASE}`, and uploaded to `${S3_BUCKET}`.

### Delete

Original files with the "delete" task will be deleted from the local filesystem. Files will only be deleted if they were previously archived to S3.

### Restore

If a file needs to be re-transcoded, but has already been deleted from the local filesystem, it will be marked "restore"; the file's archived version will be requested to be restored from AWS Glacier storage, and marked with a future time for when it should be available for download. Retrievals are set to use the "Bulk" retrieval timeframe: [https://aws.amazon.com/glacier/faqs/](https://aws.amazon.com/glacier/faqs/)

### Encode

Files with the "encode" task will be transcoded. If the file has been previously deleted from the local filesystem, and already requested to be restored from AWS Glacier storage, it will first be downloaded from AWS Glacier storage. Otherwise it will be uploaded from the local filesystem.

Encoding settings are applied in the following table sequence: `presets_generic` -> `presets_series` -> `presets_titles` -> `files`. Encoding settings can then be overridden at a granular level; multiple series might use the same generic settings, can be tweaked on a series level, and overridden per episode or based on an individual file.

Updating a record's settings updates its associated `date_updated` field. If a video's settings have been updated since it was last encoded, it will be queued for transcoding. For example:

  - Updating a `presets_generic` record will flag all files transcoded with that custom preset for re-transcoding.
  - Updating a `presets_series` record will flag all of that series' episodes for re-transcoding.
  - Updating a `presets_titles` record will flag the best-quality version of that tv show or movie for re-transcoding.
  - Updating a `files` record will flag *that particular file* for re-transcoding, but *only if it is the best quality version* of that tv show or movie.
  
Thus, a genre's settings can be set in `presets_generic`, an entire show can have across-the-board presets applied at the `presets_series` level, individual episodes that would benefit from different settings (e.g. a live-action special episode of an otherwise all-animated tv series) can be applied in `presets_titles`, and individual crop settings for a file can be set in `files`.

Encodings will use these settings as default:

  - HandBrake preset set in the environment variable `DEFAULT_HANDBRAKE_PRESET`; default is Apple 1080p60 Surround
  - x264 MPEG encoder
  - film encoder tuning
  - crop settings according to `DEFAULT_HANDBRAKE_PRESET`'s default; default is to remove black bars
  - `quality`, `vbv_maxrate`, `vbv_bufsize`, `crf_max`, and `qpmax` are based on [Don Melton's video scripts](https://github.com/donmelton/video_transcoding#rationale), with two major changes: `vbv_maxrate` is based on the input file's bitrate with a max of 9800kbps [(max DVD bitrate)](https://en.wikipedia.org/wiki/DVD-Video#Data_rate) for SD, 20000kbps [(half of Blu-ray)](https://en.wikipedia.org/wiki/Blu-ray#Bit_rate) for HD, and 40000kbps for 4K, and `crf_max` is 18. (e.g. input file with 3000kbps bitrate: `quality=1, vbv_maxrate=3000, vbv_bufsize=6000, crf_max=18, qpmax=34`)
  - decomb setting of EEDI2 Bob (selective + deinterlace + EEDI2 + cubic + blend + yadif) = [63](https://github.com/HandBrake/HandBrake/blob/master/libhb/decomb.h)
  
Files will be encoded on the remote nodes, and returned to `/Plex/Movies` or `/Plex/TV Shows`. The Plex name is the same as the original file name, but without the `quality_title` information:

  - `/Plex/Movies/Movie Title (2017)/Movie Title (2017).mkv`
  - `/Plex/Movies/Movie Title (2017)/Movie Title (2017) - Director's Cut.mkv`
    
    
  - `/Plex/TV Shows/TV Show Title/Season 01/TV Show Title - S01E01.mkv`
  - `/Plex/TV Shows/TV Show Title/Season 01/TV Show Title - S01E01 - Extended Version.mkv`
  - `/Plex/TV Shows/TV Show Title/Specials/TV Show Title - S00E01.mkv`
  
Better quality source versions will overwrite existing versions.

### Purge

Files marked with the "purge" task will have their local files AND their AWS Glacier files deleted, and their records removed from the database. This option is only available for those files that have the `purge_queue` flag set, and `date_earliest_purge` is in the past.

### Queue

Three queue files are created: **queue_archive.tsv**, **queue_encode.tsv**, and **queue_other.tsv**. Archive and Encode tasks are processed remotely, while Other contains tasks that do not require much processing power.

Based on the number of tasks in queue_archive.tsv and queue_encode.tsv, up to `${DO_MAX_DROPLETS}` droplets will be created for remote processing. The droplet type is chosen to process as many tasks as possible in the shortest amount of time, but if multiple droplets are estimated to take the same length of time, then the least expensive of those options is selected. The droplet details are added to a **dropletSpecs.txt** file, and an email is sent with information about the droplets created.

Daily at 8 AM, if **dropletSpecs.txt** exists and is older than 24 hours, then an email will be sent advising that droplets older than 24 hours exist.

Droplets to process the queue will be created using [GNU Parallel](https://www.gnu.org/software/parallel/), so multiple droplets can be created simultaneously rather than waiting for each to deploy one at a time. Once each droplet is created with the necessary attached storage and utilities installed, the droplet's connection information is added to **sshloginfile.txt**, which acts as a lockfile. As long as sshloginfile.txt exists, future queues will not start. 

Each run of the queue will create a record in `history_queue`:

  - start time
  - droplet type selected based on number and type of tasks to complete
  - number of CPUs per droplet
  - number of simultaneous tasks each droplet performed
  - number of CPUs per task (CPUs per droplet / simultaneous tasks)
  - an estimated hourly cost
  - number of droplets created
  - the time when the queue finished
  - estimated hours
  - estimated cost
  
Tasks performed during that queue will be recorded in `history_task`. Only those columns relevant to the task performed will be populated:

  - sequential ID
  - queue start time
  - path of file being processed
  - task performed
  - directory path of file being processed
  - Plex name of file
  - series title
  - release identifier
  - quality title
  - HandBrake preset
  - MPEG encoder
  - encoder tune
  - crop settings
  - quality setting
  - vbv maxrate
  - vbv bufsize
  - crf max
  - qpmax
  - decomb setting
  - nlmeans
  - nlmeans tune
  - audio language
  - duration of task (excluding the time spent uploading the file to the droplet)
  
Tasks are processed by feeding each queue_ file to [GNU Parallel](https://www.gnu.org/software/parallel/). Files for remote tasks are uploaded to the attached block storage volume `/mnt/storage`, archived or transcoded, and returned to the host machine.
  
After each queue_ file is processed, an email is sent detailing the actions that were performed.
  
Once a queue begins, it will keep running until there is nothing left in `v_queue`.

Once there is nothing left in `v_queue`, all droplets with the `fitzflix-transcoder` tag are destroyed, and an email is sent out with an estimated total cost.
  
### Email updates

Updates will be sent to `${EMAIL_RECIPIENT}` from `fitzflix@${EMAIL_HOSTNAME}` at the start, during, and end of each queue.

Contents at start:

  - droplet type
  - number of CPUs per droplet
  - amount of RAM per droplet
  - number of simultaneous jobs per droplet
  - estimated droplet cost per droplet
  - estimated attached storage cost per droplet
  - number of droplets created
  
Contents during (after each run of `v_queue`):

  - task performed, and file it was performed on
  
Contents at end:

  - Estimated total cost
