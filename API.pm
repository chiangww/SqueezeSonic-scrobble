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

    # [v72] 策略：只對 ID 進行精準去汙，並執行雙重快取寫入
    my $raw_id = defined $id ? $id : "";
    my $cache_key = $command . $raw_id;
    my $cached = cacheGet($cache_key) || "nc";

    # 1. 快速同步命中 (保住圖示與 5731 行)
    if ($cached ne "nc" && ref($cached) eq 'HASH') {
        return $cb->($cached); 
    }

    # 2. 精準去汙：只針對 getSong 的 ID 欄位
    my $clean_id = $raw_id;
    my $clean_params = defined $params ? $params : "";
    
    if ($command eq 'getSong') {
        # 僅移除 ID 後綴，不改動 params 其他部分
        $clean_id =~ s/-raw\.[a-zA-Z0-9]+//g;
        $clean_params =~ s/id=[^&]*/id=$clean_id/; # 精準替換參數中的 ID
    }
    
    my $query = $command . "?" . $clean_params;

    submitQuery(sub {
        my $result = shift;
        _sanitize_structure($result); # 確保 Boolean 已淨化

        if (defined $result && ref($result) eq 'HASH') {
            if ($command eq 'getSong') {
                my $s = $result->{'subsonic-response'}->{'song'};
                if ($s && ref($s) eq 'HASH') {
                    # 提升 10 個 ProtocolHandler 必讀欄位
                    foreach my $f (qw(id title album albumId artist artistId duration year bitRate image)) {
                        $result->{$f} = $s->{$f} if exists $s->{$f};
                    }
                    $result->{image} ||= $s->{coverArt};
                    # 影子屬性：確保 Scrobble 使用乾淨 ID
                    $result->{song_id} = $clean_id; 
                }
            }

            # =================================================================
            # 【v72 核心：精準雙重寫入】
            # =================================================================
            # 寫入 A：原始 Key (可能是帶 -raw 的，給播放 UI 用)
            cacheSet($cache_key, $result, $timeout);
            
            # 寫入 B：乾淨 Key (給 1 小時後不帶 -raw 的查勤用)
            my $alt_key = $command . $clean_id;
            if ($alt_key ne $cache_key) {
                cacheSet($alt_key, $result, $timeout);
            }
            # =================================================================

            $cb->($result);
        }
    }, $query);

    # 核心保修：同步階段回傳 Reference 避開 5731
    return $cb->({}); 
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

