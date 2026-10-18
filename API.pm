package Plugins::SqueezeSonic::API;
use warnings;
use Plugins::SqueezeSonic::HTTP;
use strict;

use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $cache = Slim::Utils::Cache->new('squeezesonic', 6);
my $prefs = preferences('plugin.squeezesonic');
my $log = logger('plugin.squeezesonic');

sub getAuth {
	my $user = $prefs->get('username');
	my $pass = $prefs->get('password');
	my @chars = ('A'..'Z', 'a'..'z', 0..9);
	my $salt = join '', map $chars[rand @chars], 0..8;
        my $token = md5_hex($pass . $salt);
	my $auth = "u=$user&t=$token&s=$salt&v=1.11.0&f=json&c=SqueezeSonic";
	return $auth;
}

sub submitQuery {
	my ($class, $cb, $query) = @_;

	if (!$query){
		$query = $cb;
		$cb = $class;
	}
	my $auth =  getAuth();
        my $server = $prefs->get('suburl');

	my $url = $server . "/rest/" . $query . "&$auth";
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { from_json($response->content) };
			
			$result ||= {};

			$cb->($result);
		},

		sub {
			$cb->( { error => $_[1] } );
		}

	)->get($url);
}

sub cacheGet {
	my ($item) = @_ ;
		
	return $cache->get($item);

}

sub cacheSet {
	my ($class,$name,$object,$time) = @_ ;
	if ( !$time && ref $name eq 'HASH' ) {
		$time = $object;
                $object = $name;
		$name = $class;
        }
	$cache->set($name,$object,$time);
}
sub cacheRemove {
	my ($class, $id) = @_;
	$cache->remove($id);
}

sub cacheClear {
	my ($class, $id) = @_;
	$cache->clear();
}

sub get {
    my ($class, $cb, $command, $id, $timeout, $params) = @_;

    # [v68] 核心任務：身分完全對齊。
    # 讓物件內部的 id 欄位，與 LMS 請求的 cache_key 100% 一致。
    my $raw_id_for_lms = defined $id ? $id : "";
    my $cache_key = $command . $raw_id_for_lms;
    my $cached = cacheGet($cache_key) || "nc";

    if ($cached ne "nc" && ref($cached) eq 'HASH') {
        return $cb->($cached); # 快取命中同步回傳
    }

    # 靜默去污發送給 Navidrome
    my $clean_params = defined $params ? $params : "";
    if ($command eq 'getSong') { $clean_params =~ s/-raw\.[a-zA-Z0-9]+//g; }
    my $query = $command . "?" . $clean_params;

    submitQuery(sub {
        my $result = shift;
        _sanitize_structure($result); # 除毒

        if (defined $result && ref($result) eq 'HASH') {
            if ($command eq 'getSong') {
                my $s = $result->{'subsonic-response'}->{'song'};
                if ($s && ref($s) eq 'HASH') {
                    # 提升欄位
                    foreach my $f (qw(title album albumId artist artistId duration year bitRate image)) {
                        $result->{$f} = $s->{$f} if exists $s->{$f};
                    }
                    $result->{image} ||= $s->{coverArt}; 

                    # 【v68 關鍵修正】強行將 ID 設為 LMS 想要的那個帶後綴的 ID
                    # 這能確保 LMS 認得這份資料的「身分」，從而亮起圖示
                    $result->{id} = $raw_id_for_lms; 
                    
                    # 但 Scrobble 必須用乾淨的 ID，所以保留 song_id 為乾淨版
                    $result->{song_id} = $s->{id}; 
                }
            }

            cacheSet($cache_key, $result, $timeout);
            $cb->($result); # 異步回調
        }
    }, $query);

    # 核心保險：避開 5731 報錯
    if ($command eq 'getSong') { return $cb->({}); }
}

sub _sanitize_structure {
    my $data = shift;
    return unless defined $data && ref($data);
    if (ref($data) eq 'HASH') {
        foreach my $k (keys %$data) {
            if (ref($data->{$k}) && ref($data->{$k}) !~ /^(HASH|ARRAY)$/) {
                $data->{$k} = $data->{$k} ? 1 : 0;
            } else { _sanitize_structure($data->{$k}); }
        }
    } elsif (ref($data) eq 'ARRAY') {
        foreach my $i (@$data) { _sanitize_structure($i); }
    }
}

sub scrobbleTrack {
    my ($class, $trackId) = @_;
    return unless $trackId;

    my $log = Slim::Utils::Log::logger('plugin.squeezesonic');

    # 1. 安全清洗 (保險起見，把 -raw 洗掉)
    # 雖然通常傳進來的 ID 應該已經處理過，但多洗一次無害
    my $clean_id = $trackId;
    $clean_id =~ s/-raw.*//;

    # 2. 準備參數
    # 不需要：u, t, s, v, c, f (submitQuery 會自動補)
    # 只需要：id, submission
    my $command = "scrobble.view";
    my $params  = "id=$clean_id&submission=true";

    # 3. 組合 Query (謹記教訓：一定要加問號！)
    my $query = $command . "?" . $params;

    $log->info("Scrobble sending via submitQuery: $query");

    # 4. 發送請求
    submitQuery(sub {
        my $result = shift;
        
        # 這裡的 result 已經是 submitQuery 解析過的 JSON 物件 (或 undef)
        if ($result && ref($result)) {
            $log->info("Scrobble response OK");
        } else {
            $log->info("Scrobble response failed or empty");
        }
    }, $query);
}

1;

