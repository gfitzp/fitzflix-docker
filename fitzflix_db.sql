-- x264 encoder tune options
--
-- encoder_tune		see handbrakecli --help for --encoder-tune-list options available

CREATE TABLE ref_encoder_tune_opts (
	encoder_tune		VARCHAR(32) PRIMARY KEY
);

INSERT INTO ref_encoder_tune_opts (encoder_tune) VALUES
('film'),
('animation'),
('grain');



-- Noise reduction strength options
--
-- nlmeans			see handbrakecli --help for --nlmeans options available

CREATE TABLE ref_nlmeans_opts (
	nlmeans				VARCHAR(32) PRIMARY KEY
);

INSERT INTO ref_nlmeans_opts (nlmeans) VALUES
('ultralight'),
('light'),
('medium'),
('strong');



-- Noise reduction tune options
--
-- nlmeans_tune		see handbrakecli --help for --nlmeans-tune options available

CREATE TABLE ref_nlmeans_tune_opts (
	nlmeans_tune		VARCHAR(32) PRIMARY KEY
);

INSERT INTO ref_nlmeans_tune_opts (nlmeans_tune) VALUES
('none'),
('film'),
('grain'),
('highmotion'),
('animation'),
('tape'),
('sprite');



-- Quality settings associated with each source type
-- See https://github.com/donmelton/video_transcoding#explanation for additional details
-- 
-- quality_title	human-readable quality term, uses "scene" naming convention for convenience and standardization
--
-- vbv_maxrate		average target bitrate for encoding
--					maxes out at the DVD maximum bitrate of 9800 kbps for DVD quality and lower
--					maxes out at 20000 kbps for Blu-Ray and lower-quality HD formats (Blu-Ray spec max is 40000 kbps)
--					maxes out at 40000 kbps for higher-quality HD content
--
-- vbv_bufsize		set to 2x vbv_maxrate
--
-- crf_max			max constant quality setting (lower numbers = higher quality)
--
-- qpmax			quantizer value
--
-- preference		order of preference for file quality
--					used for determining which formats we prefer over others in best_format
--
-- date_updated		date the setting was updated

CREATE TABLE ref_source_quality (
	quality_title			VARCHAR(32) PRIMARY KEY,
	quality					DECIMAL(3,1) NOT NULL DEFAULT 1,
	vbv_maxrate 			INT NOT NULL,
	vbv_bufsize				INT NOT NULL,
	crf_max					INT NOT NULL DEFAULT 18,
	qpmax					INT NOT NULL DEFAULT 34,
	preference				INT NOT NULL,
	date_updated			DATETIME DEFAULT NULL
);

CREATE TRIGGER `trg_quality_update_date` BEFORE UPDATE ON `ref_source_quality` FOR EACH ROW SET NEW.date_updated = CURRENT_TIMESTAMP;

-- set vbv_bufsize to 2x vbv_maxrate
CREATE TRIGGER `trg_quality_set_bufsize` BEFORE INSERT ON `ref_source_quality` FOR EACH ROW SET NEW.vbv_bufsize = NEW.vbv_maxrate * 2;
CREATE TRIGGER `trg_quality_update_bufsize` BEFORE UPDATE ON `ref_source_quality` FOR EACH ROW SET NEW.vbv_bufsize = NEW.vbv_maxrate * 2;

INSERT INTO ref_source_quality (quality_title, vbv_maxrate, preference) VALUES
('Unknown', 9800, 0),
('SDTV', 9800, 1),
('WEBDL-480p', 9800, 2),
('DVD', 9800, 3),
('HDTV-720p', 20000, 4),
('HDTV-1080p', 20000, 5),
('Raw-HD', 20000, 6),
('WEBDL-720p', 20000, 7),
('Bluray-720p', 20000, 8),
('WEBDL-1080p', 20000, 9),
('Bluray-1080p', 20000, 10),
('HDTV-2160p', 40000, 11),
('WEBDL-2160p', 40000, 12),
('Bluray-2160p', 40000, 13);



-- Generic preset settings to be applied to any series, title, or file
--
-- custom_preset		name of the custom preset
--
-- handbrake_preset		a Handbrake preset to use as the base for this preset's settings
--						see handbrakecli --help for --preset options available
--
-- mpeg_encoder			x264, x265, mpeg4, mpeg2, VP8, VP9, theora
--						see handbrakecli --help for --encoder options available
--
-- encoder_tune			tune option for the x264 encoder
--						see handbrakecli --encoder-tune-list for --encoder-tune options available
--
-- quality				target CRF quality score
--						see https://github.com/donmelton/video_transcoding#explanation
--
-- crf_max				max constant quality setting (lower numbers = higher quality)
--						see https://github.com/donmelton/video_transcoding#explanation
--
-- qpmax				quantizer value
--						see https://github.com/donmelton/video_transcoding#explanation
--
-- decomb				see https://github.com/HandBrake/HandBrake/blob/master/libhb/decomb.h for decomb methods
--
-- nlmeans				noise reduction strength value
--
-- nlmeans_tune			noise reduction tuning option
--
-- audio_language		audio language
--
-- custom_settings		additional custom settings for this preset to pass to the encoding process
--						CURRENTLY NOT IMPLEMENTED
--
-- date_updated			date the settings were updated

CREATE TABLE presets_generic (
	custom_preset			VARCHAR(128) PRIMARY KEY,
	handbrake_preset		VARCHAR(128),
	mpeg_encoder			VARCHAR(32),
	encoder_tune			VARCHAR(32),
	quality					DECIMAL(3,1),
	crf_max					INT,
	qpmax					INT,
	decomb					INT,
	nlmeans					VARCHAR(32),
	nlmeans_tune			VARCHAR(32),
	audio_language			VARCHAR(3),
	custom_settings			VARCHAR(1024),
	date_updated			DATETIME,
	
	FOREIGN KEY (encoder_tune) REFERENCES ref_encoder_tune_opts(encoder_tune) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans) REFERENCES ref_nlmeans_opts(nlmeans) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans_tune) REFERENCES ref_nlmeans_tune_opts(nlmeans_tune) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TRIGGER `trg_presets_add_date` BEFORE INSERT ON `presets_generic` FOR EACH ROW SET NEW.date_updated = CURRENT_TIMESTAMP;
CREATE TRIGGER `trg_presets_update_date` BEFORE UPDATE ON `presets_generic` FOR EACH ROW SET NEW.date_updated = CURRENT_TIMESTAMP;

INSERT INTO presets_generic (custom_preset, encoder_tune, nlmeans, nlmeans_tune, audio_language) VALUES
('Anime - Basic', 'animation', 'strong', 'animation', 'jpn'),
('Anime - Detailed', 'animation', null, null, 'jpn'),
('Cartoon - Basic', 'animation', 'strong', 'animation',  null),
('Cartoon - Detailed', 'animation', null, null, null);



-- Series-level presets
-- handy for creating a blanket set of presets to be applied across a particular TV show
-- e.g. series_title = 'Looney Tunes', custom_preset = 'Cartoon - Basic'
-- will apply the 'Cartoon - Basic' preset to every Looney Tunes cartoon in the library
-- 
-- changes in this table will override settings made in presets_generic
-- 
-- series_title				TV show title this set of settings will apply to
--
-- custom_preset			an entry in presets_generic that can be used as a basis for this show's presets
--
-- handbrake_preset			a Handbrake preset to use as the base for this preset's settings
--							see handbrakecli --help for --preset options available
--
-- mpeg_encoder				x264, x265, mpeg4, mpeg2, VP8, VP9, theora
--							see handbrakecli --help for --encoder options available
--
-- encoder_tune				tune option for the x264 encoder
--							see handbrakecli --encoder-tune-list for --encoder-tune options available
--
-- quality					target CRF quality score
--							see https://github.com/donmelton/video_transcoding#explanation
--
-- crf_max					max constant quality setting (lower numbers = higher quality)
--							see https://github.com/donmelton/video_transcoding#explanation
--
-- qpmax					quantizer value
--							see https://github.com/donmelton/video_transcoding#explanation
--
-- decomb					see https://github.com/HandBrake/HandBrake/blob/master/libhb/decomb.h for decomb methods
--
-- nlmeans					noise reduction strength value
--							see handbrakecli --help for options available
--
-- nlmeans_tune				noise reduction tuning option
--							see handbrakecli --help for options available
--
-- audio_language			audio language
--
-- custom_settings			additional custom settings for this preset to pass to the encoding process
--							CURRENTLY NOT IMPLEMENTED
--
-- date_series_updated		date the settings were updated

CREATE TABLE presets_series (
	series_title			VARCHAR(256) PRIMARY KEY,
	custom_preset			VARCHAR(128),
	handbrake_preset		VARCHAR(128),
	mpeg_encoder			VARCHAR(32),
	encoder_tune			VARCHAR(32),
	quality					DECIMAL(3,1),
	crf_max					INT,
	qpmax					INT,
	decomb					INT,
	nlmeans					VARCHAR(32),
	nlmeans_tune			VARCHAR(32),
	audio_language			VARCHAR(3),
	custom_settings			VARCHAR(1024),
	date_series_updated		DATETIME NOT NULL,
	
	FOREIGN KEY (custom_preset) REFERENCES presets_generic(custom_preset) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (encoder_tune) REFERENCES ref_encoder_tune_opts(encoder_tune) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans) REFERENCES ref_nlmeans_opts(nlmeans) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans_tune) REFERENCES ref_nlmeans_tune_opts(nlmeans_tune) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TRIGGER `trg_series_add_date` BEFORE INSERT ON `presets_series` FOR EACH ROW SET NEW.date_series_updated = CURRENT_TIMESTAMP;
CREATE TRIGGER `trg_series_updated_date` BEFORE UPDATE ON `presets_series` FOR EACH ROW SET NEW.date_series_updated = CURRENT_TIMESTAMP;



-- Title-level presets
-- handy for creating a preset for a particular episode of a particular TV show
-- movie presets will also go in this table
-- 
-- changes in this table will override settings made in presets_series and presets_generic
--
-- plex_name				title for the file when added to the Plex library
--							(basically the title but without any quality details included)
--
-- movie_title				movie title
--							use https://www.themoviedb.org/
--
-- release_year				year the movie was released
--							use https://www.themoviedb.org/
--
-- series_title				tv show title
--							use https://www.thetvdb.com/
--
-- season_number			tv show season number
--							use https://www.thetvdb.com/
--							for "specials" use 0
--
-- episode_number			tv show episode number
--							use https://www.thetvdb.com/
--
-- release_identifier		additional custom disambiguation information
--							e.g. "Director's Cut", "Extended Version", etc.
--
-- custom_preset			an entry in presets_generic that can be used as a basis for this title
--
-- handbrake_preset			a Handbrake preset to use as the base for this preset's settings
--							see handbrakecli --help for --preset options available
--
-- mpeg_encoder				x264, x265, mpeg4, mpeg2, VP8, VP9, theora
--							see handbrakecli --help for --encoder options available
--
-- encoder_tune				tune option for the x264 encoder
--							see handbrakecli --encoder-tune-list for --encoder-tune options available
--
-- quality					target CRF quality score
--							see https://github.com/donmelton/video_transcoding#explanation
--
-- crf_max					max constant quality setting (lower numbers = higher quality)
--							see https://github.com/donmelton/video_transcoding#explanation
--
-- qpmax					quantizer value
--							see https://github.com/donmelton/video_transcoding#explanation
--
-- decomb					see https://github.com/HandBrake/HandBrake/blob/master/libhb/decomb.h for decomb methods
--
-- nlmeans					noise reduction strength value
--							see handbrakecli --help for options available
--
-- nlmeans_tune				noise reduction tuning option
--							see handbrakecli --help for options available
--
-- audio_language			audio language
--
-- custom_settings			additional custom settings for this preset to pass to the encoding process
--							CURRENTLY NOT IMPLEMENTED
--
-- date_settings_updated	date the settings were updated
--
-- latest_transcode			date the title was last transcoded

CREATE TABLE presets_titles (
	plex_name				VARCHAR(256) PRIMARY KEY,
	movie_title				VARCHAR(256),
	release_year			INT,
	series_title			VARCHAR(256),
	season_number			INT,
	episode_number			INT,
	release_identifier		VARCHAR(256),
	custom_preset			VARCHAR(128),
	handbrake_preset		VARCHAR(128),
	mpeg_encoder			VARCHAR(32),
	encoder_tune			VARCHAR(32),
	quality					DECIMAL(3,1),
	crf_max					INT,
	qpmax					INT,
	decomb					INT,
	nlmeans					VARCHAR(32),
	nlmeans_tune			VARCHAR(32),
	audio_language			VARCHAR(3),
	custom_settings			VARCHAR(1024),
	date_settings_updated	DATETIME,
	latest_transcode		DATETIME,
	
	FOREIGN KEY (series_title) REFERENCES presets_series(series_title) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (custom_preset) REFERENCES presets_generic(custom_preset) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (encoder_tune) REFERENCES ref_encoder_tune_opts(encoder_tune) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans) REFERENCES ref_nlmeans_opts(nlmeans) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans_tune) REFERENCES ref_nlmeans_tune_opts(nlmeans_tune) ON DELETE RESTRICT ON UPDATE CASCADE
);


-- Trigger to update date_settings_updated only if an encoding setting option was changed

DELIMITER //
CREATE TRIGGER `trg_title_settings_updated_date`
BEFORE UPDATE ON `presets_titles`
FOR EACH ROW
BEGIN
IF (NOT(OLD.custom_preset <=> NEW.custom_preset) OR NOT(OLD.handbrake_preset <=> NEW.handbrake_preset) OR NOT(OLD.mpeg_encoder <=> NEW.mpeg_encoder) OR NOT(OLD.encoder_tune <=> NEW.encoder_tune) OR NOT(OLD.quality <=> NEW.quality) OR NOT(OLD.crf_max <=> NEW.crf_max) OR NOT(OLD.qpmax <=> NEW.qpmax) OR NOT(OLD.decomb <=> NEW.decomb) OR NOT(OLD.nlmeans <=> NEW.nlmeans) OR NOT(OLD.nlmeans_tune <=> NEW.nlmeans_tune) OR NOT(OLD.audio_language <=> NEW.audio_language) OR NOT(OLD.custom_settings <=> NEW.custom_settings)) THEN SET NEW.date_settings_updated = CURRENT_TIMESTAMP;
END IF;
END;
//

DELIMITER ;



-- File-level presets
-- handy for creating a preset for a particular file
-- items that apply to a specific file go in this table
-- e.g. a title may have different qualities as different files, while they all may require
-- crop settings, the crop settings for the DVD version will be different from the Blu-Ray)
-- 
-- changes in this table will override settings made in presets_titles, presets_series, and presets_generic
--
-- file_path					location of the original video file
--
-- dir_path						location of the directory containing the original video file
--
-- base_name					the original video file's filename
--
-- plex_name					the name we save the file as in the Plex library
--								(it's base_name, without quality info or a file extension)
--
-- quality_title				human-readable quality term, uses "scene" naming convention for convenience and standardization 
--
-- crop							colon-separated crop values for the file (top:bottom:left:right)
--								if blank, we default to the crop settings from the Handbrake preset (default is to remove black bars)
--
-- vbv_maxrate					average target bitrate for encoding
--
-- vbv_bufsize					2x vbv_maxrate
--
-- crf_max						max constant quality setting (lower numbers = higher quality)
--								see https://github.com/donmelton/video_transcoding#explanation
--
-- qpmax						quantizer value
--								see https://github.com/donmelton/video_transcoding#explanation
--
-- decomb						see https://github.com/HandBrake/HandBrake/blob/master/libhb/decomb.h for decomb methods
--
-- nlmeans						noise reduction strength value
--								see handbrakecli --help for options available
--
-- nlmeans_tune					noise reduction tuning option
--								see handbrakecli --help for options available
--
-- date_settings_updated		date the settings were updated
--
-- date_file_added				date the file was added
--
-- date_file_archived			date the file was archived to S3
--
-- date_file_deleted			date the file was deleted locally
--
-- date_restore_requested		date the archived file was requested to be restored from S3 Glacier-class storage
--
-- date_restore_available		the the archived file will be ready for re-download from S3 Glacier-class storage
--
-- date_earliest_purge			the earliest date that we can delete the file from S3 Glacier storage
--
-- purge_queue					flag to indicate if all traces of the file can be deleted from storage and the database
--
-- file_duration				length of file in seconds
--								will possibly use for evaluating which droplet type to use for encoding

CREATE TABLE files (
	file_path				VARCHAR(1024) PRIMARY KEY,
	dir_path				VARCHAR(1024) NOT NULL,
	base_name				VARCHAR(256) NOT NULL,
	plex_name				VARCHAR(256) NOT NULL,
	quality_title			VARCHAR(32) NOT NULL,
	file_duration			INT,
	crop					VARCHAR(19),
	vbv_maxrate 			INT,
	vbv_bufsize				INT,
	crf_max					INT,
	qpmax					INT,
	decomb					INT,
	nlmeans					VARCHAR(32),
	nlmeans_tune			VARCHAR(32),
	date_settings_updated	DATETIME,
	date_file_added			DATETIME NOT NULL,
	date_file_archived		DATETIME,
	date_file_deleted		DATETIME,
	date_restore_requested	DATETIME,
	date_restore_available	DATETIME,
	date_earliest_purge		DATETIME,
	purge_queue				ENUM('T', 'F') NOT NULL DEFAULT 'F',
	
	FOREIGN KEY (plex_name) REFERENCES presets_titles(plex_name) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans) REFERENCES ref_nlmeans_opts(nlmeans) ON DELETE RESTRICT ON UPDATE CASCADE,
	FOREIGN KEY (nlmeans_tune) REFERENCES ref_nlmeans_tune_opts(nlmeans_tune) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TRIGGER `trg_insert_files_set_date` BEFORE INSERT ON `files` FOR EACH ROW SET NEW.date_file_added = CURRENT_TIMESTAMP;

-- set vbv_bufsize to 2x vbv_maxrate
CREATE TRIGGER `trg_insert_files_set_bufsize` BEFORE INSERT ON `files` FOR EACH ROW SET NEW.vbv_bufsize = NEW.vbv_maxrate * 2;
CREATE TRIGGER `trg_update_files_set_bufsize` BEFORE UPDATE ON `files` FOR EACH ROW SET NEW.vbv_bufsize = NEW.vbv_maxrate * 2;

-- trigger to update the last-updated date only when encoding settings have been updated
DELIMITER //
CREATE TRIGGER `trg_update_files_set_date`
BEFORE UPDATE ON `files`
FOR EACH ROW
BEGIN
IF (NOT(OLD.crop <=> NEW.crop) OR NOT(OLD.vbv_maxrate <=> NEW.vbv_maxrate) OR NOT(OLD.vbv_bufsize <=> NEW.vbv_bufsize) OR NOT(OLD.crf_max <=> NEW.crf_max) OR NOT(OLD.qpmax <=> NEW.qpmax) OR NOT(OLD.decomb <=> NEW.decomb) OR NOT(OLD.nlmeans <=> NEW.nlmeans) OR NOT(OLD.nlmeans_tune <=> NEW.nlmeans_tune) OR NOT(OLD.purge_queue <=> NEW.purge_queue)) THEN SET NEW.date_settings_updated = CURRENT_TIMESTAMP;
END IF;
END;
//

DELIMITER ;

-- set the earliest purge date to 91 days after the file was archived
DELIMITER //
CREATE TRIGGER `trg_earliest_purge_date`
BEFORE UPDATE ON `files`
FOR EACH ROW
BEGIN
IF (NOT(OLD.date_file_archived <=> NEW.date_file_archived)) THEN SET NEW.date_earliest_purge = DATE_ADD(NEW.date_file_archived, INTERVAL 91 DAY);
END IF;
END;
//

DELIMITER ;

-- when requesting a restore, set the restore available date to 12 hours after the restore was requested
DELIMITER //
CREATE TRIGGER `trg_restore_available`
BEFORE UPDATE ON `files`
FOR EACH ROW
BEGIN
IF (NOT(OLD.date_restore_requested <=> NEW.date_restore_requested)) THEN SET NEW.date_restore_available = DATE_ADD(NEW.date_restore_requested, INTERVAL 12 HOUR);
END IF;
END;
//

DELIMITER ;


-- Task locations
-- Certain tasks can only be performed in certain locations
-- (e.g. we encode on remote machines since our NAS CPU is not very powerful,
--       we can only delete on the host since we need access to the original file)
-- Rather than coding what can be done where, this table can be adjusted for pulling appropriate tasks
-- when we create each task queue using create_queues()

CREATE TABLE task_locations (
	task					VARCHAR(32) PRIMARY KEY,
	location				ENUM('local', 'remote') NOT NULL
);

INSERT INTO task_locations (task, location) VALUES
('archive', 'remote'),
('delete', 'local'),
('restore', 'local'),
('encode', 'remote'),
('purge', 'local');



-- Encoding history
-- What was encoded when with which settings

CREATE TABLE history_queue (
	id						INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
	queue_start				DATETIME NOT NULL UNIQUE,
	droplet_type			VARCHAR(32) NOT NULL,
	num_cpus				INT,
	simultaneous_tasks		INT,
	cpus_per_task			INT,
	hourly_cost				DECIMAL(7,5) NOT NULL,
	num_droplets			INT,
	queue_end				DATETIME DEFAULT NULL,
	hours					INT,
	estimated_cost			DECIMAL(6,2)
);

CREATE TRIGGER `trg_calc_cpus_per_task` BEFORE INSERT ON `history_queue` FOR EACH ROW SET NEW.cpus_per_task = (NEW.num_cpus / NEW.simultaneous_tasks);
CREATE TRIGGER `trg_calc_queue_cost` BEFORE UPDATE ON `history_queue` FOR EACH ROW SET NEW.hours = (CEIL(TIMESTAMPDIFF(minute, OLD.queue_start, NEW.queue_end)/60)), NEW.estimated_cost = OLD.hourly_cost * (CEIL(TIMESTAMPDIFF(minute, OLD.queue_start, NEW.queue_end)/60));

CREATE TABLE history_task (
	id						INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
	queue_start				DATETIME NOT NULL,
	file_path				VARCHAR(1024),
	task					VARCHAR(32),
	dir_path				VARCHAR(1024),
	plex_name				VARCHAR(256),
	series_title			VARCHAR(256),
	release_identifier		VARCHAR(256),
	quality_title			VARCHAR(32),
	handbrake_preset		VARCHAR(128),
	mpeg_encoder			VARCHAR(32),
	encoder_tune			VARCHAR(32),
	crop					VARCHAR(19),
	quality					DECIMAL(3,1),
	vbv_maxrate				INT,
	vbv_bufsize				INT,
	crf_max					INT,
	qpmax					INT,
	decomb					INT,
	nlmeans					VARCHAR(32),
	nlmeans_tune			VARCHAR(32),
	audio_language			VARCHAR(3),
	task_duration			INT,
	
	FOREIGN KEY (queue_start) REFERENCES history_queue(queue_start) ON DELETE RESTRICT ON UPDATE CASCADE
);



-- List showing the best format for each title in the library

CREATE OR REPLACE VIEW v_best_format AS

SELECT
	file.file_path,
	file.plex_name,
	file.quality_title
	
FROM
	files file
	
	JOIN ref_source_quality q
	ON q.quality_title = file.quality_title
	
	JOIN (
		SELECT
			file.plex_name,
			MAX(q.preference) AS "preference"
			
		FROM
			files file
			
			JOIN ref_source_quality q
			ON q.quality_title = file.quality_title
		
		GROUP BY file.plex_name
	) top_quality
	ON top_quality.plex_name = file.plex_name
	
WHERE
	top_quality.preference = q.preference;
	
	

-- Processing queue
-- 
-- Show the next task to perform on each file, and the encoding settings to be applied if the next task is to encode

CREATE OR REPLACE VIEW v_queue AS

SELECT
	file.file_path,
	CASE
	
		-- Archive the file if it hasn't yet been archived
		WHEN file.date_file_archived IS NULL THEN 'archive'
		
		
		-- If it's not our best file format, and if we've already archived it to S3,
		-- then delete this lesser-quality format from our library
		WHEN file.file_path NOT IN (SELECT file_path FROM v_best_format)
			AND file.date_file_deleted IS NULL
			AND file.date_file_archived IS NOT NULL
		THEN 'delete'
		
		
		-- If the next step would be to encode the video, but the file has already been deleted,
		-- submit a request to restore the file from Glacier storage so we can later re-download it
		WHEN file.file_path = best.file_path
			AND (
				(file.date_file_added > title.latest_transcode)
				OR
				(file.date_settings_updated > title.latest_transcode)
				OR
				(title.date_settings_updated > title.latest_transcode)
				OR
				(title_generic.date_updated > title.latest_transcode)
				OR
				(series.date_series_updated > title.latest_transcode)
				OR
				(series_generic.date_updated > title.latest_transcode)
				OR
				(q.date_updated > title.latest_transcode)
				OR title.latest_transcode IS NULL
			)
			AND file.date_file_archived IS NOT NULL
			AND file.date_file_deleted IS NOT NULL
			AND (file.date_restore_requested IS NULL OR CURRENT_TIMESTAMP > DATE_ADD(file.date_restore_requested, INTERVAL 1 DAY))
		THEN 'restore'
		
		
		-- If we haven't yet transcoded the file, or if we've made changes to its encoding settings
		-- since the last time we transcoded it, then encode the file with the current encoding settings
		WHEN file.file_path = best.file_path
			AND (
				(file.date_file_added > title.latest_transcode)
				OR
				(file.date_settings_updated > title.latest_transcode)
				OR
				(title.date_settings_updated > title.latest_transcode)
				OR
				(title_generic.date_updated > title.latest_transcode)
				OR
				(series.date_series_updated > title.latest_transcode)
				OR
				(series_generic.date_updated > title.latest_transcode)
				OR
				(q.date_updated > title.latest_transcode)
				OR title.latest_transcode IS NULL
			)
			AND (		
				file.date_file_deleted IS NULL
				OR
				CURRENT_TIMESTAMP BETWEEN file.date_restore_available AND DATE_ADD(file.date_restore_requested, INTERVAL 1 DAY) 
		) THEN 'encode'
		
		
		-- If we've archived the file to S3 / Glacier, we've since passed the date the file can be deleted from Glacier storage
		-- (Glacier-class files must remain in Glacier storage for a number of days before they can be deleted without an
		--  additional charge), and the file has been flagged to be purged, then delete the file and all of its database records
		WHEN file.date_file_archived IS NOT NULL
			AND file.date_earliest_purge <= CURRENT_TIMESTAMP
			AND file.purge_queue = 'T'
		THEN 'purge'
		
	END AS "task",
	file.dir_path,
	file.plex_name,
	title.series_title,
	title.release_identifier,
	file.file_duration,
	file.quality_title,
	
	-- Use COALESCE to prefer the title-specific and title-generic encoding settings over any more broad series-specific and series-generic settings
	COALESCE(title.handbrake_preset, title_generic.handbrake_preset, series.handbrake_preset, series_generic.handbrake_preset) AS "handbrake_preset",
	COALESCE(title.mpeg_encoder, title_generic.mpeg_encoder, series.mpeg_encoder, series_generic.mpeg_encoder, 'x264') AS "mpeg_encoder",
	CASE
		WHEN COALESCE(title.mpeg_encoder, title_generic.mpeg_encoder, series.mpeg_encoder, series_generic.mpeg_encoder, 'x264') = 'x264' THEN COALESCE(title.encoder_tune, title_generic.encoder_tune, series.encoder_tune, series_generic.encoder_tune, 'film')
		ELSE NULL
	END AS "encoder_tune",
	file.crop,
	COALESCE(title.quality, title_generic.quality, series.quality, series_generic.quality, q.quality) AS "quality",
	CASE
		WHEN file.vbv_maxrate > q.vbv_maxrate THEN q.vbv_maxrate
		WHEN file.vbv_maxrate IS NULL THEN q.vbv_maxrate
		ELSE file.vbv_maxrate
	END AS "vbv_maxrate",
	CASE
		WHEN file.vbv_maxrate > q.vbv_maxrate THEN q.vbv_bufsize
		WHEN file.vbv_maxrate IS NULL THEN q.vbv_bufsize
		ELSE file.vbv_bufsize
	END AS "vbv_bufsize",
	COALESCE(file.crf_max, q.crf_max) AS "crf_max",
	COALESCE(file.qpmax, q.qpmax) AS "qpmax",
	COALESCE(title.decomb, title_generic.decomb, series.decomb, series_generic.decomb, file.decomb, '63') AS "decomb",
	COALESCE(title.nlmeans, title_generic.nlmeans, series.nlmeans, series_generic.nlmeans, file.nlmeans) AS "nlmeans",
	CASE
		WHEN title.nlmeans IS NOT NULL THEN title.nlmeans_tune
		WHEN title_generic.nlmeans IS NOT NULL THEN title_generic.nlmeans_tune
		WHEN series.nlmeans IS NOT NULL THEN series.nlmeans_tune
		WHEN series_generic.nlmeans IS NOT NULL THEN series_generic.nlmeans_tune
		WHEN file.nlmeans IS NOT NULL THEN file.nlmeans_tune
		ELSE NULL
	END AS "nlmeans_tune",
	COALESCE(title.audio_language, title_generic.audio_language, series.audio_language, series_generic.audio_language) AS "audio_language",
	file.date_settings_updated,
	file.date_file_added,
	file.date_file_archived,
	file.date_file_deleted,
	file.date_restore_requested,
	file.date_restore_available,
	file.date_earliest_purge,
	file.purge_queue

FROM
	files file
	
	JOIN presets_titles title
	ON title.plex_name = file.plex_name
	
	LEFT JOIN presets_generic title_generic
	ON title_generic.custom_preset = title.custom_preset
	
	JOIN ref_source_quality q
	ON q.quality_title = file.quality_title
	
	LEFT JOIN presets_series series
	ON title.series_title = series.series_title
	
	LEFT JOIN presets_generic series_generic
	ON series_generic.custom_preset = series.custom_preset
	
	LEFT JOIN v_best_format best
	ON best.file_path = file.file_path
	
HAVING task IS NOT NULL;



-- List of movies in the library
-- (Only show the best format for each movie)

CREATE OR REPLACE VIEW v_library_movie AS

SELECT
	movie_title,
	release_year,
	release_identifier,
	quality_title
	
FROM
	presets_titles title
	
	JOIN v_best_format file
	ON file.plex_name = title.plex_name
	
WHERE
	title.movie_title IS NOT NULL
	
ORDER BY movie_title, release_year, release_identifier;



-- List of TV shows and episodes in the library
-- (Only show the best format for each episode)

CREATE OR REPLACE VIEW v_library_tv AS

SELECT
	series_title,
	season_number,
	episode_number,
	release_identifier,
	quality_title
	
FROM
	presets_titles title
	
	JOIN v_best_format file
	ON file.plex_name = title.plex_name
	
WHERE
	title.series_title IS NOT NULL
	
ORDER BY series_title, season_number, episode_number;