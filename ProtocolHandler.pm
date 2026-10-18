package Plugins::SqueezeSonic::ProtocolHandler;

use strict;
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Time::HiRes;

# last good getMetadataFor results, keyed by url; survives the API cache expiring
my %metaCache;
my %notifyPending;

use Plugins::SqueezeSonic::API;

my $log   = logger('plugin.squeezesonic');
my $prefs = preferences('plugin.squeezesonic');

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;
	
	my ($format) = $url =~ m{\.(.+?)$};

	if ($format =~ /^flac$/) {
		$format =~ s/flac/flc/;
	}
	return $format;
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;
	
	if ( blessed($url) ) {
		$url = $url->url;
	}
	my $length;
	my $duration;
	my $type;

       	foreach my $header (@headers) {

                if ($header =~ /^Content-Type:\s*([^;\n]*)/i) {
                        $type = $1;
                }

                elsif ($header =~ /^Content-Length:\s*(.*)/i) {
                        $length = $1;
                }

                elsif ($header =~ /^X-Content-Duration:\s*(.*)/i) {
                        $duration = $1;
                }
	}
	my $bitrate = int($length/$duration*8) if $duration > 0;

	if ($client) {
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
	}
	return (undef, $bitrate, 0, undef, $type, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $url =~ m{^sonics?://(.+?)$};
	my $missed;
	my $meta = Plugins::SqueezeSonic::API->get(sub {
		my $track = shift;
		my $bitrate;

		# On API cache expiry API->get first calls back with an empty {} and
		# fetches in the background. Serving the stale-but-good metadata here
		# keeps LMS artwork intact; the async call below refreshes and pokes.
		if ( !( ref($track) eq 'HASH' && ($track->{title} || $track->{id}) ) ) {
			$missed = 1;
			return $metaCache{$url} || {};
		}

		my ($format) = $url =~ m{\.(.+?)$};

		my ($bitrate) = ($url =~ m{-(.*)\.});
		if ($bitrate eq "raw") {
			$bitrate = $track->{bitRate};
		}
		my $meta = {
                	title    => $track->{title} || $track->{id},
                	album    => $track->{album} || '',
                	albumId  => $track->{albumId} || '',
                	artist   => $track->{artist} || '',
                	artistId => $track->{artistId} || '',
                	cover    => ($track->{coverArt} || $track->{image})
                        ? Plugins::SqueezeSonic::Plugin::_getImage($track->{coverArt} || $track->{image})
                        : '',
                	duration => $track->{duration} || 0,
                	year     => $track->{year} || 0,
			type	 => $format || '',
			bitrate  => $bitrate || '',
        	};

		$meta->{bitrate} = sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $meta->{bitrate});

		$metaCache{$url} = $meta;
		%metaCache = () if keys(%metaCache) > 2000;

		# If this callback is the async completion of an earlier cache miss,
		# tell LMS to re-read metadata so refreshed artwork/titles show up.
		if ($missed && $client) {
			eval {
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			};
		}

		return $meta;
	},'getSong',$id,$prefs->get('tmusic'),"id=" . $id);

	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $url = $song->currentTrack()->url;
	my ($id) = $url =~ m{^sonics?://(.+?)$};
	my ($tid) = $url =~ m{^sonics?://(.*)-};;
	Plugins::SqueezeSonic::API->get(sub {
		my $track = shift;
		my $br;
		my $stream;

		my $auth=Plugins::SqueezeSonic::API->getAuth();

		my ($format) = $url =~ m{\.(.+?)$};
		my ($bitrate) = ($url =~ m{-(.*)\.});

		$tid = $track->{streamId} if $track->{type} eq 'podcast';

		if ($format eq $track->{suffix} || $format eq "flc") {
			# Navidrome >= 0.61 no longer falls back to raw for unknown formats:
			# format=flc would silently transcode to mp3 while LMS still expects
			# FLAC. Ask for raw instead (flc is only LMS internal codec name).
			$format = "raw";
		}
		my $transcode = "format=" . $format;
		if ($bitrate ne "raw") {
			$transcode = $transcode . "&estimateContentLength=true&maxBitRate=" . $bitrate;
			$br = $bitrate*1000;
		} else {
			$br = $track->{bitRate}*1000;
		}
		$stream = $prefs->get('suburl') . "/rest/stream?id=" . $tid . "&" . $transcode . "&" . $auth;

# --------------------------
# ✅ 這裡存 Navidrome / Subsonic 的真正 song id
$song->pluginData( squeezesonic => {song_id => $track->{id} });
# --------------------------

		$song->pluginData($format);
		$song->streamUrl($stream);
		$song->duration($track->{duration});
		$song->bitrate($br);
		$successCb->();
		return;
		$errorCb->('Failed to get next track', 'SqueezeSonic');
	},'getSong',$id,$prefs->get('tmusic'),"id=" . $id);
}

sub audioScrobblerSource {
	return 'P';
}

1;
