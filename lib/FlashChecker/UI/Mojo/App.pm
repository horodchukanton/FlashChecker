package FlashChecker::UI::Mojo::App;
use strict;
use warnings FATAL => 'all';

use Mojolicious::Lite;
# plugin AutoReload => {};

use Cwd qw(abs_path);
use File::Basename qw(dirname);

use Mojo::IOLoop;
use Data::Dumper;

use FlashChecker::UI::Mojo::EventsHandler;

my $handler = FlashChecker::UI::Mojo::EventsHandler->new();
my $cwd = dirname(abs_path($0));

sub run {
    my ( %params ) = @_;

    init();
    my $config = $params{config}->{Listen};

    my $host = $config->{Address} || '*';
    my $port = $config->{Port} || '8080';

    $handler->start(%params);

    return app->start(
        'daemon', '-l' => "http://$host:$port",
        'home'                  => $cwd,
        %{$config->{Mojo} ? $config->{Mojo} : {}}
    );
}

sub init {
    push(@{app->renderer->paths}, ( dirname(abs_path($0)) . "/templates" ));
    push(@{app->static->paths}, ( dirname(abs_path($0)) . "/static" ));
    define_routes();

    return 1;
}



sub define_routes {
    websocket('/ws' => sub {
        $handler->websocket_message(shift)
    });

    post('/command/:issuer' => sub {
        my Mojolicious::Controller $c = shift;

        my $token = $c->param('issuer');

        my Mojo::Asset::File $body = $c->req->content->asset;

        print Dumper $body;

        my $bytes = $body->slurp();

        $handler->executor_response($token, $bytes);

        $c->render(text => 'No content', status => 204);
    });

    get('/' => sub {
        my $c = shift;
        $c->render(template => 'index');
    });
}


1;