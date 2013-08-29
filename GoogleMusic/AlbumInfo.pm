package Plugins::GoogleMusic::AlbumInfo;

use strict;

use base qw(Slim::Menu::Base);

use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

use Plugins::GoogleMusic::GoogleAPI;
use Plugins::GoogleMusic::Image;

my $log = logger('plugin.googlemusic');
my $prefs = preferences('plugin.googlemusic');

sub init {
	my $class = shift;
	$class->SUPER::init();
	
	Slim::Control::Request::addDispatch(
		[ 'googlealbuminfo', 'items', '_index', '_quantity' ],
		[ 0, 1, 1, \&cliQuery ]
	);
	
	Slim::Control::Request::addDispatch(
		[ 'googlealbuminfo', 'playlist', '_method' ],
		[ 1, 1, 1, \&cliQuery ]
	);
}

# TBD
sub name {
	return 'ALBUM_INFO';
}


##
# Register all the information providers that we provide.
# This order is defined at http://wiki.slimdevices.com/index.php/UserInterfaceHierarchy
#
sub registerDefaultInfoProviders {
	my $class = shift;
	
	$class->SUPER::registerDefaultInfoProviders();

	$class->registerInfoProvider( addalbum => (
		after    => 'top',
		func      => \&addAlbumEnd,
	) );

	$class->registerInfoProvider( addalbumnext => (
		after    => 'addalbum',
		func      => \&addAlbumNext,
	) );
	
}

sub menu {
	my ( $class, $client, $url, $album, $tags, $filter ) = @_;
	$tags ||= {};

	# If we don't have an ordering, generate one.
	# This will be triggered every time a change is made to the
	# registered information providers, but only then. After
	# that, we will have our ordering and only need to step
	# through it.
	my $infoOrdering = $class->getInfoOrdering;
	
	# $remoteMeta is an empty set right now. adding to allow for parallel construction with trackinfo
	my $remoteMeta = {};

	# Get album object if necessary
	#if ( !blessed($album) ) {
	#	$album = Slim::Schema->rs('Album')->objectForUrl( {
	#		url => $url,
	#	} );
	#	if ( !blessed($album) ) {
	#		$log->error( "No album object found for $url" );
	#		return;
	#	}
	#}

	$album = $googleapi->get_album($url);

	# Function to add menu items
	my $addItem = sub {
		my ( $ref, $items ) = @_;
		
		if ( defined $ref->{func} ) {
			
			my $item = eval { $ref->{func}->( $client, $url, $album, $remoteMeta, $tags, $filter ) };
			if ( $@ ) {
				$log->error( 'Album menu item "' . $ref->{name} . '" failed: ' . $@ );
				return;
			}
			
			return unless defined $item;
			
			# skip jive-only items for non-jive UIs
			return if $ref->{menuMode} && !$tags->{menuMode};
			
			# show artwork item to jive only if artwork exists
			return if $ref->{menuMode} && $tags->{menuMode} && $ref->{name} eq 'artwork' && !$album->coverArtExists;
			
			if ( ref $item eq 'ARRAY' ) {
				if ( scalar @{$item} ) {
					push @{$items}, @{$item};
				}
			}
			elsif ( ref $item eq 'HASH' ) {
				return if $ref->{menuMode} && !$tags->{menuMode};
				if ( scalar keys %{$item} ) {
					push @{$items}, $item;
				}
			}
			else {
				$log->error( 'AlbumInfo menu item "' . $ref->{name} . '" failed: not an arrayref or hashref' );
			}				
		}
	};
	
	# Now run the order, which generates all the items we need
	my $items = [];
	
	for my $ref ( @{ $infoOrdering } ) {
		# Skip items with a defined parent, they are handled
		# as children below
		next if $ref->{parent};
		
		# Add the item
		$addItem->( $ref, $items );
		
		# Look for children of this item
		my @children = grep {
			$_->{parent} && $_->{parent} eq $ref->{name}
		} @{ $infoOrdering };
		
		if ( @children ) {
			my $subitems = $items->[-1]->{items} = [];
			
			for my $child ( @children ) {
				$addItem->( $child, $subitems );
			}
		}
	}
	
	return {
		name  => $album->{'name'} || Slim::Music::Info::getCurrentTitle( $client, $url, 1 ),
		type  => 'opml',
		items => $items,
		cover => Plugins::GoogleMusic::Image->uri($album->{'albumArtUrl'}),
	};
}

sub infoContributors {
	my ( $client, $url, $album, $remoteMeta ) = @_;
	
	my $items = [];
	
	if ( $remoteMeta->{artist} ) {
		push @{$items}, {
			type =>  'text',
			name =>  $remoteMeta->{artist},
			label => 'ARTIST',
		};
	}
	else {
		my @roles = Slim::Schema::Contributor->contributorRoles;
		
		# Loop through each pref to see if the user wants to link to that contributor role.
		my %linkRoles = map {$_ => $prefs->get(lc($_) . 'InArtists')} @roles;
		$linkRoles{'ARTIST'} = 1;
		$linkRoles{'TRACKARTIST'} = 1;
		$linkRoles{'ALBUMARTIST'} = 1;
		
		# Loop through the contributor types and append
		for my $role (@roles) {
			for my $contributor ( $album->artistsForRoles($role) ) {
				if ($linkRoles{$role}) {
					my $id = $contributor->id;
					
					my %actions = (
						allAvailableActionsDefined => 1,
						items => {
							command     => ['browselibrary', 'items'],
							fixedParams => { mode => 'albums', artist_id => $id },
						},
						play => {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'load', artist_id => $id},
						},
						add => {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'add', artist_id => $id},
						},
						insert => {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'insert', artist_id => $id},
						},								
						info => {
							command     => ['artistinfo', 'items'],
							fixedParams => {artist_id => $id},
						},								
					);
					$actions{'playall'} = $actions{'play'};
					$actions{'addall'} = $actions{'add'};
					
					my $item = {
						type    => 'playlist',
						url     => 'blabla',
						name    => $contributor->name,
						label   => uc $role,
						itemActions => \%actions,
					};
					push @{$items}, $item;
				} else {
					my $item = {
						type    => 'text',
						name    => $contributor->name,
						label   => uc $role,
					};
					push @{$items}, $item;
				}
			}
		}
	}
	
	return $items;
}

sub infoYear {
	my ( $client, $url, $album ) = @_;
	
	my $item;
	
	if ( my $year = $album->year ) {
		
		my %actions = (
			allAvailableActionsDefined => 1,
			items => {
				command     => ['browselibrary', 'items'],
				fixedParams => { mode => 'albums', year => $year },
			},
			play => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'load', year => $year},
			},
			add => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'add', year => $year},
			},
			insert => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'insert', year => $year},
			},								
			info => {
				command     => ['yearinfo', 'items'],
				fixedParams => {year => $year},
			},								
		);
		$actions{'playall'} = $actions{'play'};
		$actions{'addall'} = $actions{'add'};

		$item = {
			type    => 'playlist',
			url     => 'blabla',
			name    => $year,
			label   => 'YEAR',
			itemActions => \%actions,
		};
	}
	
	return $item;
}

sub infoDisc {
	my ( $client, $url, $album ) = @_;
	
	my $item;
	my ($disc, $discc);
	
	if ( blessed($album) && ($disc = $album->disc) && ($discc = $album->discc) ) {
		$item = {
			type  => 'text',
			label => 'DISC',
			name  => "$disc/$discc",
		};
	}
	
	return $item;
}

sub infoDuration {
	my ( $client, $url, $album ) = @_;
	
	my $item;
	
	if ( my $duration = $album->duration ) {
		$item = {
			type  => 'text',
			label => 'ALBUMLENGTH',
			name  => $duration,
		};
	}
	
	return $item;
}

sub infoCompilation {
	my ( $client, $url, $album ) = @_;
	
	my $item;
	
	if ( $album->compilation ) {
		$item = {
			type  => 'text',
			label => 'COMPILATION',
			name  => cstring($client,'YES'),
		};
	}
	
	return $item;
}


sub showArtwork {
	my ( $client, $url, $album, $remoteMeta, $tags ) = @_;
	my $items = [];
	my $jive;
	my $actions = {
		do => {
			cmd => [ 'artwork', $album->id ],
		},
	};
	$jive->{actions} = $actions;
	$jive->{showBigArtwork} = 1;

	push @{$items}, {
		type => 'text',
		name => cstring($client, 'SHOW_ARTWORK_SINGLE'),
		jive => $jive, 
	};
	
	return $items;
}

sub playAlbum {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter) = @_;

	return undef if !blessed($client);
	
	my $actions = {
		items => {
			command     => [ 'playlistcontrol' ],
			fixedParams => {cmd => 'load', album_id => $album->id, %{ $filter || {} }},
		},
	};
	$actions->{'play'} = $actions->{'items'};
	
	return {
		itemActions => $actions,
		nextWindow  => 'nowPlaying',
		type        => 'text',
		playcontrol => 'play',
		name        => cstring($client, 'PLAY'),
		jive        => {style => 'itemplay'},
	};
}
	
sub addAlbumEnd {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter ) = @_;
	addAlbum( $client, $url, $album, $remoteMeta, $tags, 'ADD_TO_END', 'add', $filter );
}

sub addAlbumNext {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter ) = @_;
	addAlbum( $client, $url, $album, $remoteMeta, $tags, 'PLAY_NEXT', 'insert', $filter );
}

sub addAlbum {
	my ( $client, $url, $album, $remoteMeta, $tags, $add_string, $cmd, $filter ) = @_;

	return undef if !blessed($client);

	my $actions = {
		items => {
			command     => [ 'playlistcontrol' ],
			#fixedParams => {cmd => $cmd, album_id => $album->id, %{ $filter || {} }},
		},
	};
	$actions->{'play'} = $actions->{'items'};
	$actions->{'add'}  = $actions->{'items'};
	
	return {
		itemActions => $actions,
		nextWindow  => 'parent',
		type        => 'text',
		playcontrol => $cmd,
		name        => cstring($client, $add_string),
	};
}

sub infoReplayGain {
	my ( $client, $url, $album ) = @_;
	
	if ( blessed($album) && $album->can('replay_gain') ) {
		if ( my $albumreplaygain = $album->replay_gain ) {
			my $noclip = Slim::Player::ReplayGain::preventClipping( $albumreplaygain, $album->replay_peak );
			my %item = (
				type  => 'text',
				label => 'ALBUMREPLAYGAIN',
				name  => sprintf( "%2.2f dB", $albumreplaygain),
			);
			if ( $noclip < $albumreplaygain ) {
				# Gain was reduced to avoid clipping
				$item{'name'} .= sprintf( " (%s)",
						cstring( $client, 'REDUCED_TO_PREVENT_CLIPPING', sprintf( "%2.2f dB", $noclip ) ) ); 
			}
			return \%item;
		}
	}
}

# keep a very small cache of feeds to allow browsing into a artist info feed
# we will be called again without $url or $albumId when browsing into the feed
tie my %cachedFeed, 'Tie::Cache::LRU', 2;

sub cliQuery {
	$log->debug('cliQuery');
	my $request = shift;
	
	# WebUI or newWindow param from SP side results in no
	# _index _quantity args being sent, but XML Browser actually needs them, so they need to be hacked in
	# here and the tagged params mistakenly put in _index and _quantity need to be re-added
	# to the $request params
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	if ( $index =~ /:/ ) {
		$request->addParam(split (/:/, $index));
		$index = 0;
		$request->addParam('_index', $index);
	}
	if ( $quantity =~ /:/ ) {
		$request->addParam(split(/:/, $quantity));
		$quantity = 200;
		$request->addParam('_quantity', $quantity);
	}
	
	my $client         = $request->client;
	my $url            = $request->getParam('url');
	my $albumId        = $request->getParam('album_id');
	my $menuMode       = $request->getParam('menu') || 0;
	my $menuContext    = $request->getParam('context') || 'normal';
	my $playlist_index = defined( $request->getParam('playlist_index') ) ?  $request->getParam('playlist_index') : undef;
	my $connectionId   = $request->connectionID;
	
	my %filter;
	foreach (qw(artist_id genre_id year)) {
		if (my $arg = $request->getParam($_)) {
			$filter{$_} = $arg;
		}
	}	

	my $tags = {
		menuMode      => $menuMode,
		menuContext   => $menuContext,
		playlistIndex => $playlist_index,
	};
	
	my $feed;
	
	# Default menu
	if ( $url ) {
		$feed = Plugins::GoogleMusic::AlbumInfo->menu( $client, $url, undef, $tags, \%filter );
	}
	elsif ( $albumId ) {
		my $album = Slim::Schema->find( Album => $albumId );
		$feed     = Plugins::GoogleMusic::AlbumInfo->menu( $client, $album->url, $album, $tags, \%filter );
	}
	elsif ( $cachedFeed{ $connectionId } ) {
		$feed = $cachedFeed{ $connectionId };
	}
	else {
		$request->setStatusBadParams();
		return;
	}
	
	$cachedFeed{ $connectionId } = $feed if $feed;
	
	Slim::Control::XMLBrowser::cliQuery( 'googlealbuminfo', $feed, $request );
}

1;