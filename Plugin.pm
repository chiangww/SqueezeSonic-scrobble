package Plugins::SqueezeSonic::Plugin;

use strict;
use version;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Formats::RemoteMetadata;
use Slim::Player::ProtocolHandlers;

use Slim::Utils::Strings qw(string cstring);
use Digest::MD5 qw(md5_hex);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::SqueezeSonic::API;
use Plugins::SqueezeSonic::HTTP;
use Plugins::SqueezeSonic::HTTPS;

my $prefs = preferences('plugin.squeezesonic');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.squeezesonic',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_SQUEEZESONIC',
} );

sub initPlugin {
	my $class = shift;
	
	if (main::WEBUI){
		require Plugins::SqueezeSonic::Settings;
		Plugins::SqueezeSonic::Settings->new();
	};
	
	Slim::Player::ProtocolHandlers->registerHandler(
		sonic => 'Plugins::SqueezeSonic::HTTP'
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		sonics => 'Plugins::SqueezeSonic::HTTPS'
	);
	
	Slim::Menu::TrackInfo->registerInfoProvider( squeezesonic => (
		func  => \&songPlus,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( squeezesonic => (
		func => \&search,
	) );
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'squeezesonic',
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
	
	Slim::Utils::Log::logger('plugin.squeezesonic')->debug("Registering handler");

	Slim::Control::Request::subscribe(\&onPlayerEvent, [ ['playlist'] ]);
}

sub getDisplayName { 'PLUGIN_SQUEEZESONIC' }

sub handleFeed {
	my ($client, $cb, $args) = @_;
	
	my $params = $args->{params};

	my $items;

	if ($prefs->get('username') && $prefs->get('password') && $prefs->get('suburl') && $prefs->get('asize')) {
		Plugins::SqueezeSonic::API->submitQuery(sub {
			my $ping = shift;
			my $status = $ping->{'subsonic-response'}->{status};
			my $version = $ping->{'subsonic-response'}->{version};
			if ($status eq 'ok' && version->parse($version) >= version->parse('1.11.0')) {
				push @$items, {
						name  => cstring($client, 'SEARCH'),
						image => 'html/images/search.png',
						type => 'search',
						url => \&search,
						passthrough => [{
							search => lc($params->{search}),
						}]
				},{
						name => cstring($client, 'PLUGIN_SQUEEZESONIC_RANDOM'),
						url  => \&albumList,
						image => 'plugins/SqueezeSonic/html/images/random.png',
						passthrough => [{
                                		        mode => 'random',
                        			}]
				},{
						name => cstring($client, 'PLUGIN_SQUEEZESONIC_RECENTLY_ADDED'),
						url  => \&albumList,
						image => 'html/images/newmusic.png',
						passthrough => [{
                                			        mode => 'newest',
                        			}]
				},{
						name  => cstring($client, 'PLUGIN_SQUEEZESONIC_GENRES'),
						url  => \&genresList,
						image => 'html/images/genres.png',
				},{		
						name => cstring($client, 'PLUGIN_SQUEEZESONIC_INDEX'),
						url  => \&artistsList,
						image => 'html/images/artists.png',
				},{
						name  => cstring($client, 'PLUGIN_SQUEEZESONIC_PLAYLISTS'),
						url  => \&playlistsList,
						image => 'html/images/playlists.png',
				},{		
						name  => cstring($client, 'PLUGIN_SQUEEZESONIC_PODCASTS'),
						url  => \&podcastsList,
						image => 'plugins/SqueezeSonic/html/images/podcasts.png',
				},{		
						name  => cstring($client, 'PLUGIN_SQUEEZESONIC_REFRESH'),
						url  => \&cleanup,
						image => 'plugins/SqueezeSonic/html/images/refresh.png',
				};
			} elsif ($status eq 'ok' && version->parse($version) < version->parse('1.11.0')) {
				push @$items, {
						name => cstring($client, 'PLUGIN_SQUEEZESONIC_MINIMUM_VERSION') . " " . $version,
						type => 'textarea',
				};
			} else {
				push @$items, {
						name => cstring($client, 'PLUGIN_SQUEEZESONIC_SOMETHING_WRONG'),
						type => 'textarea',
				};
			}
			$cb->({
				items => $items
			});
		},'ping?');
	} else {
		push @$items, {
				name => cstring($client, 'PLUGIN_SQUEEZESONIC_REQUIRES_CREDENTIALS'),
				type => 'textarea',
		};
		$cb->({
			items => $items
		});

	}

}

sub songPlus {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $items;
	
	if ($remoteMeta->{artistId}){
		push @$items, {
                	name => $remoteMeta->{artist},
                        url  => \&artist,
                        passthrough => [{
                        	artistId => $remoteMeta->{artistId},
                        }]
		}
	}
	
	push @$items, {
                        name => cstring($client, 'PLUGIN_SQUEEZESONIC_SEARCH', $remoteMeta->{artist}),
                        url  => \&search,
                        passthrough => [{
                                q => $remoteMeta->{artist},
                        }]
        },{
                        name => cstring($client, 'PLUGIN_SQUEEZESONIC_SEARCH', $remoteMeta->{album}),
                        url  => \&search,
                        passthrough => [{
                                q => $remoteMeta->{album},
                        }]
        },{
                        name => cstring($client, 'PLUGIN_SQUEEZESONIC_SEARCH', $remoteMeta->{title}),
                        url  => \&search,
                        passthrough => [{
                                q => $remoteMeta->{title},
                        }]
        };
	
        my $info = [{
                        name  => cstring($client, 'PLUGIN_SQUEEZESONIC_PLUS'),
                        items => $items
        }];
	return $info;

}

sub search {
	my ($client, $cb, $params, $args) = @_;
	
	$args ||= {};
	$params->{search} ||= $args->{q};
	my $search = uri_escape_utf8(lc($params->{search}));

        my $query = "search3?query=$search&artistCount=" . $prefs->get('slists') . "&albumCount=" . $prefs->get('slists') . "&songCount=" . $prefs->get('slists');

	Plugins::SqueezeSonic::API->submitQuery(sub {
		my $results = shift;
		
		if (!$results) {
			$cb->();
		}
		
		my $albums = [];
		foreach my $album ( @{$results->{'subsonic-response'}->{searchResult3}->{album}} ) {
			$album->{image} = _getImage($album->{coverArt});
			push @$albums, _formatAlbum($album);
		}

		my $artists = [];
		for my $artist ( @{$results->{'subsonic-response'}->{searchResult3}->{artist}} ) {
			$artist->{image} = _getImage($artist->{coverArt});
                        push @$artists, _formatArtist($artist);
		}

		my $tracks = [];
                foreach my $track ( @{$results->{'subsonic-response'}->{searchResult3}->{song}}) {
                        push @$tracks, _formatTrack(_cacheTrack($track));
		}
		
		my $items = [];
		
		push @$items, {
			name  => cstring($client, 'ALBUMS'),
			items => $albums,
			image => 'html/images/albums.png',
		} if scalar @$albums;

		push @$items, {
			name  => cstring($client, 'ARTISTS'),
			items => $artists,
			image => 'html/images/artists.png',
		} if scalar @$artists;

		push @$items, {
			name  => cstring($client, 'SONGS'),
			items => $tracks,
			image => 'html/images/playlists.png',
		} if scalar @$tracks;

		if (scalar @$items == 1) {
			$items = $items->[0]->{items};
		}

		$cb->( { 
			items => $items
		} );
	}, $query);
}

sub podcastsList {
        my ($client, $cb, $params, $args) = @_;

	my $query = "getPodcasts?includeEpisodes=false";
	Plugins::SqueezeSonic::API->get(sub {
       		my $podcastList = shift;
		my $podcasts = [];
		
		foreach my $podcast ( @{$podcastList->{'subsonic-response'}->{podcasts}->{channel}} ) {
			$podcast->{image} = _getImage($podcast->{coverArt});
			push @$podcasts, _formatPodcast($podcast);
		}
		$cb->({
			items => $podcasts
		});
	},'getPodcasts','All',$prefs->get('tlists'));
}

sub _formatPodcast {
	my ($podcast) = @_;

	my $formated = {
			name  => $podcast->{title}, 
			image => $podcast->{image},
			line1 => $podcast->{description},
			type  => 'playlist',
			url   => \&podcast,
			passthrough => [{
              			podcast_id => $podcast->{id},
                		}],
			};
	return $formated;
}

sub podcast {
	my ($client, $cb, $params, $args) = @_;

        Plugins::SqueezeSonic::API->get(sub {
                        my $podcast = shift;
                        my $episodes = [];

                	foreach my $episode ( @{$podcast->{'subsonic-response'}->{podcasts}->{channel}->[0]->{episode}} ) {
        	                        push @$episodes, _formatTrack(_cacheTrack($episode)) if $episode->{status} eq 'completed';
			}
			$cb->({
				items => $episodes
			});

        }, 'getPodcasts',$args->{podcast_id},$prefs->get('tmusic'),"id=" . $args->{podcast_id} . "&includeEpisodes=true");
}

sub playlistsList {
        my ($client, $cb, $params, $args) = @_;

	Plugins::SqueezeSonic::API->get(sub {
       		my $playlistsList = shift;
		my $playlists = [];

		foreach my $playlist ( @{$playlistsList->{'subsonic-response'}->{playlists}->{playlist}} ) {
			$playlist->{image} = _getImage($playlist->{coverArt});
			push @$playlists, _formatPlaylist($playlist);
		}
		$cb->({
			items => $playlists
		});
	}, 'getPlaylists','All',$prefs->get('tlists'));
}

sub _formatPlaylist {
	my ($playlist) = @_;

	my $formated = {
			name  => $playlist->{name} . ($playlist->{comment} ? ' - ' : ''),
			image => $playlist->{image},
			type  => 'playlist',
			url   => \&playlist,
			passthrough => [{
              			playlist_id => $playlist->{id},
                		}],
			};
	return $formated;
}

sub playlist {
	my ($client, $cb, $params, $args) = @_;
        Plugins::SqueezeSonic::API->get(sub {
                        my $playlist = shift;
                        my $tracks = [];

                        foreach my $track ( @{$playlist->{'subsonic-response'}->{playlist}->{entry}} ) {
                                push @$tracks, _formatTrack(_cacheTrack($track));
                        }
                        $cb->({
                                items => $tracks
                        });
        }, 'getPlaylist',$args->{playlist_id},$prefs->get('tmusic'),"id=" . $args->{playlist_id});
}

sub albumList {
        my ($client, $cb, $params, $args) = @_;
 	my $id;
        my $pa;
	my $img = 'html/images/newmusic.png';

	if ($args->{mode} eq "byGenre") {
        	$id = $args->{genre};
               	$pa = "type=byGenre&genre=" . $args->{genre} . "&size=" . $prefs->get('slists');
		$img = 'html/images/albums.png';
        } else { 
	        $id = $args->{mode};
        	$pa = "type=" .  $args->{mode} . "&size=" . $prefs->get('slists');
		$img = 'plugins/SqueezeSonic/html/images/random.png' if ($args->{mode} eq "random");
	} 

	Plugins::SqueezeSonic::API->get(sub {
       		my $albumList = shift;
		my $albums = [];

		foreach my $album ( @{$albumList->{'subsonic-response'}->{albumList2}->{album}} ) {
			$album->{image} = _getImage($album->{coverArt});
			push @$albums, _formatAlbum($album);
		}
		$cb->({
			items => $albums
		});
	}, 'getAlbumList2',$id,$prefs->get('tlists'),$pa);
}

sub _formatAlbum {
	my ($album) = @_;

	my $formated = {
			name  => $album->{artist} . ($album->{artist} && $album->{name} ? ' - ' : '') . $album->{name},
			image => $album->{image},
			line1 => $album->{name},
			type  => 'playlist',
			url   => \&album,
			passthrough => [{
              			album_id => $album->{id},
                		}],
			};
	return $formated;
}

sub album {
	my ($client, $cb, $params, $args) = @_;
        Plugins::SqueezeSonic::API->get(sub {
                        my $album = shift;
                        my $tracks = [];

                        foreach my $track ( @{$album->{'subsonic-response'}->{album}->{song}} ) {
                                push @$tracks, _formatTrack(_cacheTrack($track));
                        }
                        $cb->({
                                items => $tracks
                        });
        }, 'getAlbum',$args->{album_id},$prefs->get('tmusic'),"id=" . $args->{album_id});
}

sub _formatTrack {
        my ($track) = @_;

	my $formated = {
        	        name  => $track->{title} . ($track->{artist} ? " - $track->{artist}" : ''),
                	line1 => $track->{title},
                	line2 => $track->{artist} . ($track->{artist} && $track->{album} ? ' - ' : '') . $track->{album},
                	image => $track->{image},
                	play  => $track->{play},
                	on_select => 'play',
                	playall   => 1,
        };
	return $formated;
}

sub _cacheTrack {
	my ($track) = @_;
	                
        $track->{image} = _getImage($track->{coverArt});
	
	my $tid;
	if ($prefs->get('transcode') ne 'raw' && $track->{transcodedSuffix}) {
			$tid = $track->{id} . "-" . $prefs->get('transcode') . "." . $track->{transcodedSuffix};
			$track->{bitrate} = $prefs->get('transcode');

        }else{
                        my $format = $track->{suffix};
                        if ($format =~ /^flac$/) {
                                $format =~ s/flac/flc/;
                        }
			$tid = $track->{id} . "-" . "raw" . "." . $format;
        }

	if ($prefs->get('suburl') =~ m/^https/){
	        $track->{play}='sonics://' . $tid;
	} else {
	        $track->{play}='sonic://' . $tid;
	}
	Plugins::SqueezeSonic::API->cacheSet("getSong" . $tid,$track,$prefs->get('tmusic'));
	return $track;
}

sub artistsList {
        my ($client, $cb, $params, $args) = @_;

	Plugins::SqueezeSonic::API->get(sub {
       		my $artistList = shift;
		my $artists = [];
		my $alphabet = [];

		foreach my $letter ( @{$artistList->{'subsonic-response'}->{artists}->{index}} ) {
			foreach my $artist ( @{$letter->{artist}} ) {
				$artist->{image} = _getImage($artist->{coverArt});
				push @$alphabet, _formatArtist($artist);
			}
			push @$artists, {
                        	name  => $letter->{name},
                        	items => $alphabet,
                	} if scalar $alphabet;
			$alphabet = [];
		}
		$cb->({
			items => $artists
		});
	}, 'getArtists','All',$prefs->get('tlists'));
}

sub genresList {
        my ($client, $cb, $params, $args) = @_;

	Plugins::SqueezeSonic::API->get(sub {
       		my $genreList = shift;
		my $genres = [];

		foreach my $genre ( @{$genreList->{'subsonic-response'}->{genres}->{genre}} ) {
			push @$genres, {
                        	name  => $genre->{value},
				url => \&genre,
				passthrough => [{
					genre => $genre->{value},
                        	}],
			}
		}
		$cb->({
			items => $genres
		});
	}, 'getGenres','All',$prefs->get('tmusic'));
}

sub genre {
        my ($client, $cb, $params, $args) = @_;

        my $items = [{
        	name  => cstring($client, 'ALBUMS'),
                url   => \&albumList,
                image => 'html/images/albums.png',
                passthrough => [{
                	mode => 'byGenre',
			genre => $args->{genre},
                }]
	},{
                name => cstring($client, 'PLUGIN_SQUEEZESONIC_STARTRADIO'),
                url => \&startRadioGenre,
               	image => 'html/images/playlists.png',
                passthrough => [{
                	genre => $args->{genre},
                }]
        }];
        $cb->( {
        	items => $items
        });
}

sub startRadioGenre {
        my ($client, $cb, $params, $args) = @_;
	
        Plugins::SqueezeSonic::API->get(sub {
                my $radio = shift;
                my $tracks =[];

                foreach my $track ( @{$radio->{'subsonic-response'}->{songsByGenre}->{song}} ) {
			$track = _cacheTrack($track);
                        push @$tracks, $track->{play};
                }
		$client->execute( ["playlist", "playtracks", "listref", $tracks] );
        },'getSongsByGenre',$args->{genre},$prefs->get('tmusic'),"genre=" . $args->{genre} . "&count=" . $prefs->get('slists'));
}

sub artist {
	my ($client, $cb, $params, $args) = @_;

	Plugins::SqueezeSonic::API->get(sub {
		my $artistInfo2 = shift;
		
		my $items = [{
			name  => cstring($client, 'ALBUMS'),
			url   => \&artistAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				artistId => $args->{artistId}, 
			}]
		},{
			name => cstring($client, 'PLUGIN_SQUEEZESONIC_STARTRADIO'),
			url => \&startRadioArtist,
			image => 'html/images/playlists.png',
			passthrough => [{
                                artistId => $args->{artistId},
                        }]
		}];

		my $imageLarge = $artistInfo2->{'subsonic-response'}->{artistInfo2}->{largeImageUrl} || '';		
		my $imageMedium = $artistInfo2->{'subsonic-response'}->{artistInfo2}->{mediumImageUrl} || '';		
		my $imageSmall = $artistInfo2->{'subsonic-response'}->{artistInfo2}->{smallImageUrl} || '';		

		my $img = $imageLarge || $imageMedium || $imageSmall || 'html/images/artists.png';
		my $bio = $artistInfo2->{'subsonic-response'}->{artistInfo2}->{biography};
		if ($bio) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_SQUEEZESONIC_BIOGRAPHY'),
				image => "$img",
				url => \&artistBio,
				passthrough => [{
                                	artistId => $args->{artistId},
                        	}]
			}
		}
		$cb->( {
			items => $items
		} );
	}, 'getArtistInfo2', $args->{artistId}, $prefs->get('tmusic'), "id=" . $args->{artistId});
}

sub _formatArtist {
        my ($artist) = @_;

        my $formated = {
                name  => $artist->{name},
		image => $artist->{image},
                	url   => \&artist,
                	passthrough => [{
                        	artistId  => $artist->{id},
                	}],
        };
	return $formated;
}

sub startRadioArtist {
        my ($client, $cb, $params, $args) = @_;

        my $id = $args->{artistId};

        Plugins::SqueezeSonic::API->get(sub {
                my $radio = shift;
                my $tracks =[];

                foreach my $track ( @{$radio->{'subsonic-response'}->{similarSongs2}->{song}} ) {
                        $track = _cacheTrack($track);
                        push @$tracks, $track->{play};
                }
		$client->execute( ["playlist", "playtracks", "listref", $tracks] );
        },'getSimilarSongs2',$args->{artistId},$prefs->get('tmusic'),"id=" . $args->{artistId} . "&count=" . $prefs->get('slists'));
}

sub artistBio {
	my ($client, $cb, $params, $args) = @_;

	my $id = $args->{artistId};

	Plugins::SqueezeSonic::API->get(sub {
                my $artistInfo2 = shift;

                my $items = [{
				name => $artistInfo2->{'subsonic-response'}->{artistInfo2}->{biography},
                                type => 'textarea',
		},{
				name => cstring($client, 'PLUGIN_SQUEEZESONIC_SIMILAR_ARTISTS'),
				image => 'html/images/artists.png',
				type => 'text',
		}];

		foreach my $similar ( @{$artistInfo2->{'subsonic-response'}->{artistInfo2}->{similarArtist}} ){
			$similar->{image} = _getImage($similar->{coverArt});
			push @$items, _formatArtist($similar);
		}
		$cb->({
                        items => $items
                });
	}, 'getArtistInfo2', $args->{artistId}, $prefs->get('tmusic'), "id=" . $args->{artistId});
}

sub artistAlbums {
        my ($client, $cb, $params, $args) = @_;

        my $id = $args->{artistId};

        Plugins::SqueezeSonic::API->get(sub {
		my $list = shift;
		my $albums =[];

                foreach my $album ( @{$list->{'subsonic-response'}->{artist}->{album}} ) {
                        $album->{image}=_getImage($album->{coverArt});
                        push @$albums, _formatAlbum($album);
                }
                $cb->({
                        items => $albums
                });
	},'getArtist',$args->{artistId},$prefs->get('tmusic'),"id=" . $args->{artistId});               
}

sub _getImage {
	my ($imageId)= @_;
	my $auth = Plugins::SqueezeSonic::API->getAuth();

	my $art = $prefs->get('suburl') . "/rest/getCoverArt?id=" . $imageId . "&size=" . $prefs->get('asize') . "&$auth";
	return $art;
}

sub cleanup {
	Plugins::SqueezeSonic::API->cacheClear;
}

use warnings;

# =========================================================================
# 全域變數 (狀態記憶)
# =========================================================================
my %client_states; 

sub onPlayerEvent {
    my $request = shift;
    
    return unless $request;
    my $client = $request->client();
    return unless $client;

    my $client_id = $client->id();
    my $command   = $request->getRequest(0); 
    my $action    = $request->getRequest(1); 

    # Debug Log: 開啟後可觀察事件流
    Slim::Utils::Log::logger('plugin.squeezesonic')->debug("Event Fired: $command $action");

    return unless ( ($command eq 'playlist' && $action eq 'newsong') || 
                    ($command eq 'playlist' && $action eq 'stop')    || 
                    ($command eq 'player'   && $action eq 'stop') );

    my $now = time();

    # =====================================================================
    # Phase 1: 結算上一首 (Scrobble Logic)
    # =====================================================================
    if ( my $last_state = $client_states{$client_id} ) {
        
        my $current_song = $client->playingSong();
        my $current_url  = ($current_song && $current_song->track()) ? $current_song->track()->url : '';

        # Resume 判斷
        my $is_resume = ($action eq 'newsong' && $current_url eq $last_state->{url});

        if ( ! $is_resume ) {
            my $played_seconds = $now - $last_state->{start_time};
            my $duration       = $last_state->{duration} || 0;
            my $title          = $last_state->{title} || 'Unknown';

            # 【Scrobble 規則修正】
            my $should_scrobble = 0;
            
            if ($duration > 0) {
                # 規則 A: 已知長度 -> 播超過 50% 或 超過 240秒
                if ( ($played_seconds >= $duration * 0.5) || ($played_seconds > 240) ) {
                    $should_scrobble = 1;
                }
            } else {
                # 規則 B: 未知長度 -> 播超過 60秒
                if ($played_seconds > 60) {
                    $should_scrobble = 1;
                }
                # 規則 C (新增): 如果未知長度，但事件是 'stop' (代表播完)，且播了超過 30秒
                # 這是為了補救那些抓不到長度的 FLAC，但 19秒真的太短，通常 Last.fm 標準是 30秒
                # 如果您堅持要 19秒也算，可以把 30 改成 15
                elsif ( ($action eq 'stop') && ($played_seconds > 15) ) {
                    $should_scrobble = 1;
                    Slim::Utils::Log::logger('plugin.squeezesonic')->info("Force scrobble short track with unknown duration: $title");
                }
            }

            if ($should_scrobble) {
                my $target_nd_id = $last_state->{nd_song_id};
                if ($target_nd_id) {
                    Slim::Utils::Log::logger('plugin.squeezesonic')->info("Scrobbling: $title (ID: $target_nd_id, Time: ${played_seconds}/${duration}s)");
                    eval { Plugins::SqueezeSonic::API->scrobbleTrack($target_nd_id); };
                    if ($@) { Slim::Utils::Log::logger('plugin.squeezesonic')->error("Scrobble failed: $@"); }
                }
            } else {
                # 顯示為什麼沒 Scrobble (方便除錯)
                Slim::Utils::Log::logger('plugin.squeezesonic')->info("Skipped: $title (Played: ${played_seconds}s, Duration: ${duration}s)");
            }

            delete $client_states{$client_id};
        }
    }

    # =====================================================================
    # Phase 2: 記錄新歌 (Start Tracking)
    # =====================================================================
    if ( $action eq 'newsong' ) {
        my $song = $client->playingSong();
        
        if ($song && $song->track()) {
            my $plugin_data = $song->pluginData('squeezesonic');
            my $nd_id       = $plugin_data ? $plugin_data->{song_id} : undef;

            if ($nd_id) {
                my $current_url = $song->track()->url;

                if ( !exists $client_states{$client_id} || $client_states{$client_id}->{url} ne $current_url ) {
                    
                    # 【三重保險抓時間】
                    # 1. 資料庫/檔案標頭
                    my $track_sec = $song->track()->secs;
                    # 2. LMS 物件屬性 (有時比 track()->secs 準)
                    my $song_dur  = $song->duration;
                    # 3. 外掛原始資料 (SqueezeSonic 通常會把 JSON 存在這)
                    my $plugin_dur = $plugin_data->{duration};

                    # 取三者中大於 0 的第一個值
                    my $final_duration = $track_sec || $song_dur || $plugin_dur || 0;

                    $client_states{$client_id} = {
                        url        => $current_url,
                        nd_song_id => $nd_id,
                        title      => $song->track()->title,
                        duration   => $final_duration,
                        start_time => $now,
                    };
                    
                    # Debug: 印出抓到的時間，確認是否有抓到 19
                    Slim::Utils::Log::logger('plugin.squeezesonic')->debug("Tracking Start: " . $song->track()->title . " (Detected Duration: $final_duration)");
                }
            }
        }
    }
}
1;
