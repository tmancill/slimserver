package Slim::Plugin::UPnP::MediaRenderer;

# $Id$

use strict;

use URI::Escape qw(uri_escape uri_unescape);

use Slim::Plugin::UPnP::Discovery;
use Slim::Plugin::UPnP::MediaRenderer::RenderingControl;
use Slim::Plugin::UPnP::MediaRenderer::ConnectionManager;
use Slim::Plugin::UPnP::MediaRenderer::AVTransport;
use Slim::Plugin::UPnP::MediaRenderer::ProtocolHandler;
use Slim::Plugin::UPnP::Common::Utils qw(xmlEscape);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::HTTP;

my $log = logger('plugin.upnp');

# Some meta info about each player type for the description file
my %models = (
	slimp3      => {
		modelName => 'SliMP3',
		url       => 'http://wiki.slimdevices.com/index.php/SLIMP3',
		icon      => '/html/images/Players/slimp3_250x250.png',
	},
	Squeezebox  => {
		modelName => 'Squeezebox 1',
		url       => 'http://wiki.slimdevices.com/index.php/Squeezebox',
		icon      => '/html/images/Players/squeezebox_250x250.png',
	},
	squeezebox2 => {
		modelName => 'Squeezebox 2',
		url       => 'http://wiki.slimdevices.com/index.php/Squeezebox2',
		icon      => '/html/images/Players/squeezebox_250x250.png',
	},
	squeezebox3 => {
		modelName => 'Squeezebox 3',
		url       => 'http://www.slimdevices.com/pi_squeezebox.html',
		icon      => '/html/images/Players/squeezebox3_250x250.png',
	},
	transporter => {
		modelName => 'Transporter',
		url       => 'http://www.slimdevices.com/pi_transporter.html',
		icon      => '/html/images/Players/transporter_250x250.png',
	},
	receiver    => {
		modelName => 'Squeezebox Receiver',
		url       => 'http://www.slimdevices.com/pi_receiver.html',
		icon      => '/html/images/Players/receiver_250x250.png',
	},
	boom        => {
		modelName => 'Squeezebox Boom',
		url       => 'http://www.slimdevices.com/pi_boom.html',
		icon      => '/html/images/Players/boom_250x250.png',
	},
	softsqueeze => {
		modelName => 'Softsqueeze',
		url       => 'http://wiki.slimdevices.com/index.php/SoftSqueeze',
		icon      => '/html/images/Players/softsqueeze_250x250.png',
	},
	controller  => {
		modelName => 'Squeezebox Controller',
		url       => 'http://www.slimdevices.com/pi_controller.html',
		icon      => '/html/images/Players/controller_250x250.png',
	},
	squeezeplay => {
		modelName => 'SqueezePlay',
		url       => 'http://wiki.slimdevices.com/index.php/SqueezePlay',
		icon      => '/html/images/Players/squeezeplay_250x250.png',
	},
	baby        => {
		modelName => 'Squeezebox Radio',
		url       => 'http://wiki.slimdevices.com/index.php/Squeezebox_Radio',
		icon      => '/html/images/Players/baby_250x250.png',
	},
	fab4        => {
		modelName => 'Squeezebox Touch',
		url       => 'http://wiki.slimdevices.com/index.php/Squeezebox_Touch',
		icon      => '/html/images/Players/fab4_250x250.png',
	},
	default     => {
		modelName => 'Squeezebox',
		url       => 'http://www.slimdevices.com',
		icon      => '/html/images/slimdevices_logo_250x250.png',
	},
);

sub init {
	my $class = shift;
	
	# Watch for new players.
	# Each new player will get its own MediaRenderer device
	Slim::Control::Request::subscribe(
		\&newClient,
		[['client'], ['new', 'reconnect']],
	);
	
	Slim::Control::Request::subscribe(
		\&disconnectClient,
		[['client'], ['disconnect']],
	);
	
	# Setup description and service URLs
	Slim::Web::Pages->addPageFunction( 'plugins/UPnP/MediaRenderer.xml' => \&description );
	
	# Init service modules
	Slim::Plugin::UPnP::MediaRenderer::RenderingControl->init;
	Slim::Plugin::UPnP::MediaRenderer::ConnectionManager->init;
	Slim::Plugin::UPnP::MediaRenderer::AVTransport->init;
	
	# Init protocol handler
	Slim::Player::ProtocolHandlers->registerHandler(
		upnp => 'Slim::Plugin::UPnP::MediaRenderer::ProtocolHandler'
	);
	
	$log->info('UPnP MediaRenderer initialized');
}

sub shutdown {
	my $class = shift;
	
	Slim::Control::Request::unsubscribe( \&newClient );
	Slim::Control::Request::unsubscribe( \&disconnectClient );
	
	# Shutdown service modules
	Slim::Plugin::UPnP::MediaRenderer::RenderingControl->shutdown;
	Slim::Plugin::UPnP::MediaRenderer::ConnectionManager->shutdown;
	Slim::Plugin::UPnP::MediaRenderer::AVTransport->shutdown;
	
	# Discovery will take care of unregistering all devices
}

sub newClient {
	my $request = shift;
	my $client  = $request->client || return;
	
	# Ignore if we're already enabled for this client
	return if $client->pluginData('uuid');
	
	$log->info( 'Setting up MediaRenderer for ' . $client->id );
	
	my $uuid = Slim::Plugin::UPnP::Discovery->uuid($client);
	$client->pluginData( uuid => $uuid );
	
	my $hostport = Slim::Utils::Network::serverAddr() . ':' . preferences('server')->get('httpport');
	
	Slim::Plugin::UPnP::Discovery->register(
		uuid     => $uuid,
		url      => "http://$hostport/plugins/UPnP/MediaRenderer.xml?player=" . uri_escape( $client->id ),
		ttl      => 1800,
		device   => 'urn:schemas-upnp-org:device:MediaRenderer:1',
		services => [
			'urn:schemas-upnp-org:service:ConnectionManager:1',
			'urn:schemas-upnp-org:service:AVTransport:1',
			'urn:schemas-upnp-org:service:RenderingControl:1',
		],
	);
	
	# Register this client with services
	Slim::Plugin::UPnP::MediaRenderer::RenderingControl->newClient( $client );
	Slim::Plugin::UPnP::MediaRenderer::AVTransport->newClient( $client );
}

sub disconnectClient {
	my $request = shift;
	my $client  = $request->client || return;
	
	$log->info( 'Client ' . $client->id . ' disconnected, shutting down MediaRenderer' );
	
	if ( my $uuid = $client->pluginData('uuid') ) {	
		Slim::Plugin::UPnP::Discovery->unregister( $uuid );
		$client->pluginData( uuid => 0 );
	}
	
	# Disconnect this client from services
	Slim::Plugin::UPnP::MediaRenderer::RenderingControl->disconnectClient( $client );
	Slim::Plugin::UPnP::MediaRenderer::AVTransport->disconnectClient( $client );
}

sub description {
	my ( $client, $params, undef, undef, $response ) = @_;
	
	# Trigger 404 if no client or the web code gave us a random client
	# because the client requested was not connected
	if ( !$client || 'player=' . $client->id ne uri_unescape( $params->{url_query} ) ) {
		$response->code(404);
		return \'';
	}
	
	my $hostport  = Slim::Utils::Network::serverAddr() . ':' . preferences('server')->get('httpport');
	my $eventaddr = Slim::Utils::Network::serverAddr() . ':' . Slim::Plugin::UPnP::Events->port;
	
	my $info = $models{ $client->model(1) } || $models{default};
	
	$params->{device} = {
		id_esc => uri_escape( $client->id ),
		name   => xmlEscape($client->name),
		model  => $info->{modelName},
		url    => $info->{url},
		serial => $client->id,
		uuid   => $client->pluginData('uuid'),
		icon   => $info->{icon},
	};
	
	$params->{serverAddr} = $hostport;
	$params->{serverURL}  = 'http://' . $hostport;
	$params->{eventAddr}  = $eventaddr;
	
	main::DEBUGLOG && $log->is_debug && $log->debug('MediaRenderer.xml for ' . $client->id . ' requested by ' . $params->{userAgent});
	
	return Slim::Web::HTTP::filltemplatefile( "plugins/UPnP/MediaRenderer.xml", $params );
}

1;